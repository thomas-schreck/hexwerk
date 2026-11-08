import CryptoKit
import Foundation

// Auto-recovery of unsaved changes (#139).
//
// A record holds the piece table and undo history of a modified document
// plus the bytes of its added buffer, and identifies the file it was made
// against. Pieces taken from the file only point into it, so a record is
// worthless, and dangerous, for any other file: restoring refuses unless
// size, modification time and the first and last MiB still match.
//
// Per document there is a small metadata file `<key>.recovery`, written
// atomically, and a data file `<key>-<id>.added` holding the added buffer.
// Between saves the added buffer only grows (edits append, undo keeps the
// bytes), so every write appends just the new bytes; the metadata names
// how many of them belong to the record and their SHA-256. A crash while
// writing leaves the previous metadata, whose bytes are already synced.

/// Content and undo history of a document, without the file bytes.
struct RecoveryPayload: Sendable {
    var added: Data
    var pieces: [Document.Piece]
    var count: UInt64
    var undo: [Document.Step]
    var redo: [Document.Step]
    var state: Int
    var lastState: Int
    var savedState: Int
}

/// What a recovery record needs from a document, taken on the main thread
/// (`Document.recoveryContent()`, cheap: copy-on-write) and written on a
/// background queue.
public struct RecoveryContent: Sendable {
    let url: URL
    let original: ByteSource
    let payload: RecoveryPayload
}

/// Identity of the file a record was made against.
struct RecoveryFingerprint: Equatable, Sendable {
    var size: UInt64
    var mtimeSeconds: Int64
    var mtimeNanoseconds: Int64
    /// SHA-256 of the first and the last MiB (the whole file if smaller).
    var sample: Data

    static let sampleSize: UInt64 = 1 << 20

    init(size: UInt64, mtimeSeconds: Int64, mtimeNanoseconds: Int64, sample: Data) {
        self.size = size
        self.mtimeSeconds = mtimeSeconds
        self.mtimeNanoseconds = mtimeNanoseconds
        self.sample = sample
    }

    /// From the mapped bytes, so it describes exactly what the pieces point into.
    init(of source: ByteSource) {
        size = source.count
        mtimeSeconds = Int64(source.stamp.mtime.tv_sec)
        mtimeNanoseconds = Int64(source.stamp.mtime.tv_nsec)
        let head = min(size, Self.sampleSize)
        let tail = max(head, size - min(size, Self.sampleSize))
        var h = SHA256()
        h.update(data: source.read(0 ..< head))
        h.update(data: source.read(tail ..< size))
        sample = Data(h.finalize())
    }
}

/// Why a record cannot be applied to the file as it is now.
public enum RecoveryMismatch: Sendable, Equatable, CustomStringConvertible {
    case otherFile
    case size(then: UInt64, now: UInt64)
    case modificationDate
    case content

    public var description: String {
        switch self {
        case .otherFile: L("The recovery data belongs to a different file.")
        case .size(let then, let now): L("The file's size changed from %1$llu to %2$llu bytes.", then, now)
        case .modificationDate: L("The file was modified after the changes were recorded.")
        case .content: L("The file's content changed after the changes were recorded.")
        }
    }
}

public enum RecoveryError: Error, CustomStringConvertible {
    case damaged(String)
    case fileChanged(RecoveryMismatch)

    public var description: String {
        switch self {
        case .damaged(let why): L("The recovery data is damaged: %@", why)
        case .fileChanged(let m): m.description
        }
    }
}

/// Unsaved changes found on disk, ready to be checked and applied with
/// `Document.restore(_:)`.
public struct RecoveryRecord: Sendable {
    /// The file the changes belong to (symlinks resolved).
    public let path: String
    public let recordedAt: Date
    /// False if the undo history was left out (too large); restoring then
    /// gives one undo step back to the file.
    public let hasHistory: Bool
    let fingerprint: RecoveryFingerprint
    let payload: RecoveryPayload
}

/// A record found by `RecoveryStore.pending()`.
public struct RecoveryInfo: Sendable, Equatable {
    public let path: String
    public let recordedAt: Date
}

/// The folder holding recovery records.
public struct RecoveryStore: Sendable {
    public let directory: URL
    /// Larger added buffers are not recorded (`RecoveryStatus.tooLarge`).
    public let maxAddedBytes: Int
    /// Metadata above this is written without undo history, and not at all
    /// if it is still too large.
    public let maxMetaBytes: Int

    public static let defaultMaxAddedBytes = 512 << 20
    public static let defaultMaxMetaBytes = 64 << 20

    public init(directory: URL, maxAddedBytes: Int = defaultMaxAddedBytes, maxMetaBytes: Int = defaultMaxMetaBytes) {
        self.directory = directory
        self.maxAddedBytes = maxAddedBytes
        self.maxMetaBytes = maxMetaBytes
    }

    /// `~/Library/Application Support/hexwerk/Recovery` (inside the
    /// container when sandboxed).
    public static var user: RecoveryStore {
        RecoveryStore(
            directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("hexwerk/Recovery"))
    }

    /// The same file under another spelling or via a symlink gets the same record.
    public static func path(for url: URL) -> String {
        Document.resolvingSymlinks(url.standardizedFileURL).standardizedFileURL.path
    }

    static func key(forPath path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    func metaURL(_ key: String) -> URL { directory.appendingPathComponent(key + ".recovery") }
    func dataURL(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// Creates the folder, readable by the user only.
    func prepareDirectory() throws {
        let parent = directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        guard mkdir(directory.path, 0o700) == 0 || errno == EEXIST else { throw DocumentError.write(directory.path, errno) }
        var st = stat()
        guard lstat(directory.path, &st) == 0 else { throw DocumentError.write(directory.path, errno) }
        guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else { throw DocumentError.write(directory.path, EPERM) }
        if st.st_mode & 0o077 != 0, chmod(directory.path, 0o700) != 0 { throw DocumentError.write(directory.path, errno) }
    }

    // MARK: Reading

    /// The record for `url`, nil if there is none. Throws `damaged` if one
    /// exists but cannot be read completely and verified.
    public func record(for url: URL) throws -> RecoveryRecord? {
        let path = Self.path(for: url)
        let key = Self.key(forPath: path)
        guard let meta = try readMeta(metaURL(key)) else { return nil }
        let (header, payload) = try RecoveryFormat.decode(meta)
        guard header.path == path else { throw RecoveryError.fileChanged(.otherFile) }
        guard header.dataName.hasPrefix(key + "-"), !header.dataName.contains("/"), header.addedCount <= UInt64(maxAddedBytes)
        else { throw RecoveryError.damaged("data file") }
        let added = try readData(dataURL(header.dataName), count: Int(header.addedCount))
        guard Data(SHA256.hash(data: added)) == header.addedHash else { throw RecoveryError.damaged("checksum of the changed bytes") }
        var p = payload
        p.added = added
        return RecoveryRecord(
            path: header.path, recordedAt: header.recordedAt, hasHistory: header.hasHistory,
            fingerprint: header.fingerprint, payload: p)
    }

    /// All readable records (for the offer at launch), oldest first.
    public func pending() -> [RecoveryInfo] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".recovery") }.compactMap { name in
            guard let meta = try? readMeta(directory.appendingPathComponent(name)),
                let decoded = try? RecoveryFormat.decode(meta)
            else { return nil }
            return RecoveryInfo(path: decoded.0.path, recordedAt: decoded.0.recordedAt)
        }.sorted { $0.recordedAt < $1.recordedAt }
    }

    /// Removes the record for `url`, if any.
    public func discard(for url: URL) {
        remove(key: Self.key(forPath: Self.path(for: url)))
    }

    /// Removes every record, including unreadable ones.
    public func discardAll() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(".recovery") || name.hasSuffix(".added") || name.hasPrefix(".") {
            unlink(directory.appendingPathComponent(name).path)
        }
    }

    /// Metadata first: without it the data file means nothing.
    func remove(key: String) {
        unlink(metaURL(key).path)
        removeData(of: key, except: nil)
    }

    func removeData(of key: String, except keep: String?) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(key + "-") && name.hasSuffix(".added") && name != keep {
            unlink(dataURL(name).path)
        }
    }

    private func readMeta(_ url: URL) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw RecoveryError.damaged(String(cString: strerror(errno)))
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw RecoveryError.damaged("not a file") }
        // Slack for the header and checksum on top of the limit.
        guard st.st_size <= off_t(maxMetaBytes) + 65536 else { throw RecoveryError.damaged("too large") }
        return try readExactly(fd, Int(st.st_size))
    }

    private func readData(_ url: URL, count: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw RecoveryError.damaged(String(cString: strerror(errno))) }
        defer { close(fd) }
        return try readExactly(fd, count)
    }

    private func readExactly(_ fd: Int32, _ count: Int) throws -> Data {
        var out = Data(count: count)
        var done = 0
        while done < count {
            let n = out.withUnsafeMutableBytes { read(fd, $0.baseAddress! + done, count - done) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw RecoveryError.damaged(n < 0 ? String(cString: strerror(errno)) : "truncated") }
            done += n
        }
        return out
    }

    // MARK: Writing

    /// Temp file, fsync, rename, fsync of the folder; never world-readable.
    func writeAtomically(_ data: Data, to url: URL) throws {
        let tmp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8))")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DocumentError.write(tmp.path, errno) }
        var renamed = false
        defer {
            close(fd)
            if !renamed { unlink(tmp.path) }
        }
        try Document.writeAll(fd, data, path: tmp.path)
        guard fsync(fd) == 0 else { throw DocumentError.write(tmp.path, errno) }
        guard rename(tmp.path, url.path) == 0 else { throw DocumentError.write(url.path, errno) }
        renamed = true
        let dfd = open(directory.path, O_RDONLY)
        if dfd >= 0 {
            fsync(dfd)
            close(dfd)
        }
    }
}

/// Result of writing a record.
public enum RecoveryStatus: Sendable, Equatable {
    case saved
    /// Nothing is recorded: the changes exceed the store's limits. An older
    /// record of this document was removed, it no longer matches.
    case tooLarge
    case discarded
    case failed(String)
}

/// Writes the record of one document. Not thread-safe: `RecoveryAutosave`
/// uses it from one serial queue.
final class RecoveryWriter {
    let store: RecoveryStore
    /// The record this writer owns (the document's path).
    private(set) var key: String
    /// `savedState` of the document the data file belongs to; a save or
    /// reload starts a new added buffer and so a new data file.
    private var base: Int?
    private var dataName = ""
    private var written = 0
    private var hasher = SHA256()
    private var fingerprint: RecoveryFingerprint?

    init(store: RecoveryStore, url: URL) {
        self.store = store
        key = RecoveryStore.key(forPath: RecoveryStore.path(for: url))
    }

    func write(_ c: RecoveryContent) throws -> RecoveryStatus {
        let path = RecoveryStore.path(for: c.url)
        let newKey = RecoveryStore.key(forPath: path)
        let p = c.payload
        guard p.added.count <= store.maxAddedBytes else {
            discard()
            key = newKey
            return .tooLarge
        }
        try store.prepareDirectory()
        if newKey != key || base != p.savedState || p.added.count < written || dataName.isEmpty {
            base = p.savedState
            dataName = "\(newKey)-\(UUID().uuidString).added"
            written = 0
            hasher = SHA256()
            fingerprint = nil
        }
        let fp = fingerprint ?? RecoveryFingerprint(of: c.original)
        fingerprint = fp
        try append(p.added)
        // A copy: the running hash goes on with the next appended bytes.
        let digest = hasher
        let header = RecoveryFormat.Header(
            path: path, recordedAt: Date(), fingerprint: fp, dataName: dataName,
            addedCount: UInt64(p.added.count), addedHash: Data(digest.finalize()), hasHistory: true)
        var meta = RecoveryFormat.encode(header, p)
        if meta.count > store.maxMetaBytes {
            var h = header
            h.hasHistory = false
            meta = RecoveryFormat.encode(h, p)
        }
        guard meta.count <= store.maxMetaBytes else {
            discard()
            key = newKey
            return .tooLarge
        }
        try store.writeAtomically(meta, to: store.metaURL(newKey))
        if newKey != key { store.remove(key: key) }
        key = newKey
        store.removeData(of: key, except: dataName)
        return .saved
    }

    /// Writes the bytes not yet in the data file and syncs it.
    private func append(_ added: Data) throws {
        let url = store.dataURL(dataName)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DocumentError.write(url.path, errno) }
        defer { close(fd) }
        let chunk = 1 << 20
        while written < added.count {
            let piece = added.subdata(in: written ..< min(written + chunk, added.count))
            guard lseek(fd, off_t(written), SEEK_SET) >= 0 else { throw DocumentError.write(url.path, errno) }
            try Document.writeAll(fd, piece, path: url.path)
            hasher.update(data: piece)
            written += piece.count
        }
        guard fsync(fd) == 0 else { throw DocumentError.write(url.path, errno) }
    }

    func discard() {
        store.remove(key: key)
        base = nil
        dataName = ""
        written = 0
        fingerprint = nil
    }
}

/// Writes recovery records in the background, a moment after the last
/// edit, so typing never waits for the disk. Every operation runs on one
/// serial queue, so a discard can never be overtaken by an older write.
public final class RecoveryAutosave: @unchecked Sendable {
    // @unchecked: `writer` is only touched on `queue`, the rest under `lock`.
    private let queue = DispatchQueue(label: "hexwerk.recovery", qos: .utility)
    private let delay: DispatchTimeInterval
    private let writer: RecoveryWriter
    private let onStatus: @Sendable (RecoveryStatus) -> Void
    private let lock = NSLock()
    /// Bumped by every schedule, write, discard and stop: older scheduled
    /// writes then do nothing.
    private var generation = 0
    private var stopped = false

    /// `url` is the document's file: a record there belongs to this writer
    /// (the user has restored or discarded it before the window opened).
    /// `onStatus` is called on a background queue.
    public init(
        store: RecoveryStore, url: URL, delay: DispatchTimeInterval = .seconds(3),
        onStatus: @escaping @Sendable (RecoveryStatus) -> Void = { _ in }
    ) {
        writer = RecoveryWriter(store: store, url: url)
        self.delay = delay
        self.onStatus = onStatus
    }

    /// Records the document once nothing else was scheduled for the delay.
    /// `content` is called only then, on the main thread: taking the content
    /// on every keystroke would keep a second reference to the added buffer
    /// alive, and the next edit would copy all of it.
    public func schedule(_ content: @escaping @MainActor @Sendable () -> RecoveryContent?) {
        let gen: Int? = lock.withLock {
            guard !stopped else { return nil }
            generation += 1
            return generation
        }
        guard let gen else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            MainActor.assumeIsolated {
                guard isCurrent(gen), let c = content() else { return }
                queue.async { [self] in
                    guard isCurrent(gen) else { return }
                    onStatus(write(c))
                }
            }
        }
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.withLock { gen == generation && !stopped }
    }

    /// Records `content` right away and waits (Keep for Later).
    public func writeNow(_ content: RecoveryContent) -> RecoveryStatus {
        let go: Bool = lock.withLock {
            generation += 1
            return !stopped
        }
        guard go else { return .failed("stopped") }
        let status = queue.sync { write(content) }
        onStatus(status)
        return status
    }

    /// Drops a pending write and removes the record (saved or reverted).
    public func discard() {
        lock.withLock { generation += 1 }
        queue.async { [self] in
            writer.discard()
            onStatus(.discarded)
        }
    }

    /// Like `discard`, but waits until the record is gone (Don't Save).
    public func discardNow() {
        discard()
        waitUntilIdle()
    }

    /// No further writes (the window closes); a discard still runs.
    public func stop() {
        lock.withLock {
            stopped = true
            generation += 1
        }
    }

    /// Waits for queued work (before quitting).
    public func waitUntilIdle() { queue.sync {} }

    private func write(_ c: RecoveryContent) -> RecoveryStatus {
        do { return try writer.write(c) } catch { return .failed(String(describing: error)) }
    }
}

// MARK: File format

enum RecoveryFormat {
    static let magic = "hexwerk recovery"
    static let version: UInt64 = 1

    struct Header {
        var path: String
        var recordedAt: Date
        var fingerprint: RecoveryFingerprint
        var dataName: String
        var addedCount: UInt64
        var addedHash: Data
        var hasHistory: Bool
    }

    /// Metadata followed by its SHA-256. The added bytes live in the data file.
    static func encode(_ h: Header, _ p: RecoveryPayload) -> Data {
        var w = WireWriter()
        w.string(magic)
        w.uint(version)
        w.string(h.path)
        w.double(h.recordedAt.timeIntervalSince1970)
        w.uint(h.fingerprint.size)
        w.int(h.fingerprint.mtimeSeconds)
        w.int(h.fingerprint.mtimeNanoseconds)
        w.bytes(h.fingerprint.sample)
        w.string(h.dataName)
        w.uint(h.addedCount)
        w.bytes(h.addedHash)
        w.uint(p.count)
        w.array(p.pieces, piece)
        w.bool(h.hasHistory)
        if h.hasHistory {
            w.int(p.state)
            w.int(p.lastState)
            w.int(p.savedState)
            w.array(p.undo, step)
            w.array(p.redo, step)
        }
        var out = w.data
        out.append(Data(SHA256.hash(data: out)))
        return out
    }

    private static func piece(_ w: inout WireWriter, _ p: Document.Piece) {
        w.u8(p.source == .added ? 1 : 0)
        w.uint(p.start)
        w.uint(p.length)
    }

    private static func step(_ w: inout WireWriter, _ s: Document.Step) {
        w.int(s.before)
        w.int(s.after)
        w.array(s.changes) { w, c in
            w.uint(UInt64(c.index))
            w.array(c.removed, piece)
            w.array(c.inserted, piece)
        }
    }

    /// The payload comes back with an empty `added` (it is in the data file).
    static func decode(_ data: Data) throws -> (Header, RecoveryPayload) {
        let digestSize = SHA256.byteCount
        guard data.count > digestSize else { throw RecoveryError.damaged("truncated") }
        let body = data.prefix(data.count - digestSize)
        guard Data(SHA256.hash(data: body)) == data.suffix(digestSize) else { throw RecoveryError.damaged("checksum") }
        do {
            var r = WireReader(body)
            guard try r.string() == magic, try r.uint() == version else { throw RecoveryError.damaged("unknown format") }
            let path = try r.string()
            let recordedAt = Date(timeIntervalSince1970: try r.double())
            let fp = RecoveryFingerprint(
                size: try r.uint(), mtimeSeconds: try r.int64(), mtimeNanoseconds: try r.int64(), sample: try r.bytes())
            let dataName = try r.string()
            let addedCount = try r.uint()
            let addedHash = try r.bytes()
            let count = try r.uint()
            let pieces = try r.array(minSize: 3, readPiece)
            let hasHistory = try r.bool()
            var p = RecoveryPayload(
                added: Data(), pieces: pieces, count: count, undo: [], redo: [], state: 1, lastState: 1, savedState: 0)
            if hasHistory {
                p.state = try r.int()
                p.lastState = try r.int()
                p.savedState = try r.int()
                p.undo = try r.array(minSize: 3, readStep)
                p.redo = try r.array(minSize: 3, readStep)
            }
            try r.expectEnd()
            let h = Header(
                path: path, recordedAt: recordedAt, fingerprint: fp, dataName: dataName, addedCount: addedCount,
                addedHash: addedHash, hasHistory: hasHistory)
            return (h, p)
        } catch let e as WireError {
            throw RecoveryError.damaged(e.message)
        }
    }

    private static func readPiece(_ r: inout WireReader) throws -> Document.Piece {
        let source: Document.Piece.Source
        switch try r.u8() {
        case 0: source = .original
        case 1: source = .added
        default: throw WireError("bad piece")
        }
        return Document.Piece(source: source, start: try r.uint(), length: try r.uint())
    }

    private static func readStep(_ r: inout WireReader) throws -> Document.Step {
        let before = try r.int(), after = try r.int()
        let changes = try r.array(minSize: 3) { r -> Document.Change in
            guard let index = Int(exactly: try r.uint()) else { throw WireError("index") }
            return Document.Change(index: index, removed: try r.array(minSize: 3, readPiece), inserted: try r.array(minSize: 3, readPiece))
        }
        return Document.Step(changes: changes, before: before, after: after)
    }
}
