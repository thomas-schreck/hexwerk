import CryptoKit
import Foundation

// Auto-recovery of unsaved changes (#139).
//
// A record holds the piece table and undo history of a modified document
// plus the bytes of its added buffer, and identifies the file it was made
// against. Pieces taken from the file only point into it, so a record is
// worthless, and dangerous, for any other content: restoring refuses unless
// the file's bytes are provably the same (see `RecoveryFingerprint`).
//
// Per document there is a small metadata file `<key>.recovery`, written
// atomically, and a data file `<key>-<id>.added` holding the added buffer.
// Between saves the added buffer only grows (edits append, undo keeps the
// bytes), so every write appends just the new bytes; the metadata names
// how many of them belong to the record and their SHA-256. A crash while
// writing leaves the previous metadata, whose bytes are already on disk.
// Every change to a record happens under an flock on `<key>.lock`, so two
// hexwerk instances editing the same file never mix their records.

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
///
/// Up to `fullHashLimit` the whole file is hashed: equal bytes are all that
/// matters, whatever happened to dates or inode. Above it, hashing on every
/// open would stall, so the file must be the very same one (device, inode),
/// with unchanged size, mtime and ctime (which no program can set back) and
/// unchanged first and last MiB.
struct RecoveryFingerprint: Equatable, Sendable {
    var size: UInt64
    var mtimeSeconds: Int64
    var mtimeNanoseconds: Int64
    var ctimeSeconds: Int64
    var ctimeNanoseconds: Int64
    var device: UInt64
    var inode: UInt64
    /// SHA-256 of the first and the last MiB (the whole file if smaller).
    var sample: Data
    /// SHA-256 of the whole file; empty above the limit.
    var full: Data

    static let sampleSize: UInt64 = 1 << 20
    static let defaultFullHashLimit: UInt64 = 256 << 20

    init(
        size: UInt64, mtimeSeconds: Int64, mtimeNanoseconds: Int64, ctimeSeconds: Int64, ctimeNanoseconds: Int64,
        device: UInt64, inode: UInt64, sample: Data, full: Data
    ) {
        self.size = size
        self.mtimeSeconds = mtimeSeconds
        self.mtimeNanoseconds = mtimeNanoseconds
        self.ctimeSeconds = ctimeSeconds
        self.ctimeNanoseconds = ctimeNanoseconds
        self.device = device
        self.inode = inode
        self.sample = sample
        self.full = full
    }

    /// From the mapped bytes, so it describes exactly what the pieces point
    /// into, and the stat taken when the file was opened.
    init(of source: ByteSource, fullHashLimit: UInt64) {
        let st = source.stamp
        size = source.count
        mtimeSeconds = Int64(st.mtime.tv_sec)
        mtimeNanoseconds = Int64(st.mtime.tv_nsec)
        ctimeSeconds = Int64(st.ctime.tv_sec)
        ctimeNanoseconds = Int64(st.ctime.tv_nsec)
        device = st.device
        inode = st.inode
        let head = min(size, Self.sampleSize)
        let tail = max(head, size - min(size, Self.sampleSize))
        var h = SHA256()
        h.update(data: source.read(0 ..< head))
        h.update(data: source.read(tail ..< size))
        sample = Data(h.finalize())
        if size <= fullHashLimit {
            var f = SHA256()
            source.withUnsafeBytes { f.update(bufferPointer: $0) }
            full = Data(f.finalize())
        } else {
            full = Data()
        }
    }

    /// Why a record made against `then` must not be applied to `now`.
    static func mismatch(then: Self, now: Self) -> RecoveryMismatch? {
        if now.size != then.size { return .size(then: then.size, now: now.size) }
        if !then.full.isEmpty { return now.full == then.full ? nil : .content }
        if now.device != then.device || now.inode != then.inode { return .replaced }
        if now.mtimeSeconds != then.mtimeSeconds || now.mtimeNanoseconds != then.mtimeNanoseconds
            || now.ctimeSeconds != then.ctimeSeconds || now.ctimeNanoseconds != then.ctimeNanoseconds
        {
            return .modificationDate
        }
        if now.sample != then.sample { return .content }
        return nil
    }
}

/// Why a record cannot be applied to the file as it is now.
public enum RecoveryMismatch: Sendable, Equatable, CustomStringConvertible {
    case otherFile
    case size(then: UInt64, now: UInt64)
    case replaced
    case modificationDate
    case content

    public var description: String {
        switch self {
        case .otherFile: L("The recovery data belongs to a different file.")
        case .size(let then, let now): L("The file's size changed from %1$llu to %2$llu bytes.", then, now)
        case .replaced: L("The file was replaced by another one after the changes were recorded.")
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
    /// Files up to this size are identified by a hash of all their bytes.
    let fullHashLimit: UInt64

    public static let defaultMaxAddedBytes = 512 << 20
    public static let defaultMaxMetaBytes = 64 << 20
    /// The header (path, fingerprint, ...) is read from this many bytes.
    static let headerReadSize = 64 << 10

    public init(directory: URL, maxAddedBytes: Int = defaultMaxAddedBytes, maxMetaBytes: Int = defaultMaxMetaBytes) {
        self.init(directory: directory, maxAddedBytes: maxAddedBytes, maxMetaBytes: maxMetaBytes, fullHashLimit: RecoveryFingerprint.defaultFullHashLimit)
    }

    init(directory: URL, maxAddedBytes: Int = defaultMaxAddedBytes, maxMetaBytes: Int = defaultMaxMetaBytes, fullHashLimit: UInt64) {
        self.directory = directory
        self.maxAddedBytes = maxAddedBytes
        self.maxMetaBytes = maxMetaBytes
        self.fullHashLimit = fullHashLimit
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
        guard isTrusted() else { throw DocumentError.write(directory.path, EPERM) }
        var st = stat()
        guard lstat(directory.path, &st) == 0 else { throw DocumentError.write(directory.path, errno) }
        if st.st_mode & 0o077 != 0, chmod(directory.path, 0o700) != 0 { throw DocumentError.write(directory.path, errno) }
    }

    /// The folder exists, is a real folder (no symlink) and is ours.
    func isTrusted() -> Bool {
        var st = stat()
        return lstat(directory.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR && st.st_uid == getuid()
    }

    /// Runs `body` holding the record's lock (shared for reading).
    func withLock<R>(_ key: String, exclusive: Bool, _ body: () throws -> R) throws -> R {
        let path = directory.appendingPathComponent(key + ".lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw DocumentError.write(path, errno) }
        defer { close(fd) }
        while flock(fd, exclusive ? LOCK_EX : LOCK_SH) != 0 {
            guard errno == EINTR else { throw DocumentError.write(path, errno) }
        }
        return try body()
    }

    // MARK: Reading

    /// The record for `url`, nil if there is none. Throws `damaged` if one
    /// exists but cannot be read completely and verified.
    public func record(for url: URL) throws -> RecoveryRecord? {
        var st = stat()
        guard lstat(directory.path, &st) == 0 else { return nil }
        guard isTrusted() else { throw RecoveryError.damaged("folder") }
        let path = Self.path(for: url)
        let key = Self.key(forPath: path)
        // No lock file for every file merely opened.
        guard lstat(metaURL(key).path, &st) == 0 else { return nil }
        return try withLock(key, exclusive: false) {
            guard let meta = try readMeta(metaURL(key)) else { return nil }
            let (header, payload) = try RecoveryFormat.decode(meta)
            guard header.path == path else { throw RecoveryError.fileChanged(.otherFile) }
            guard header.dataName.hasPrefix(key + "-"), !header.dataName.contains("/"),
                header.addedCount <= UInt64(maxAddedBytes)
            else { throw RecoveryError.damaged("data file") }
            let added = try readData(dataURL(header.dataName), count: Int(header.addedCount))
            guard Data(SHA256.hash(data: added)) == header.addedHash else {
                throw RecoveryError.damaged("checksum of the changed bytes")
            }
            var p = payload
            p.added = added
            return RecoveryRecord(
                path: header.path, recordedAt: header.recordedAt, hasHistory: header.hasHistory,
                fingerprint: header.fingerprint, payload: p)
        }
    }

    /// All records whose header reads (for the offer at launch), oldest
    /// first. Reads only the start of each file.
    public func pending() -> [RecoveryInfo] {
        guard isTrusted() else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".recovery") }.compactMap { name in
            guard let h = header(directory.appendingPathComponent(name)) else { return nil }
            return RecoveryInfo(path: h.path, recordedAt: h.recordedAt)
        }.sorted { $0.recordedAt < $1.recordedAt }
    }

    func header(_ url: URL) -> RecoveryFormat.Header? {
        guard let start = try? readFile(url, upTo: Self.headerReadSize) else { return nil }
        return try? RecoveryFormat.decodeHeader(start)
    }

    /// Removes the record for `url`, if any (the user said so).
    public func discard(for url: URL) {
        let key = Self.key(forPath: Self.path(for: url))
        guard isTrusted() else { return }
        _ = try? withLock(key, exclusive: true) { remove(key: key) }
    }

    /// Removes every record, including unreadable ones. Lock files stay:
    /// another instance may hold one.
    public func discardAll() {
        guard isTrusted() else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let keys = Set(names.filter { $0.hasSuffix(".recovery") || $0.hasSuffix(".added") }.map { String($0.prefix { $0 != "." && $0 != "-" }) }.filter { !$0.isEmpty })
        for key in keys { _ = try? withLock(key, exclusive: true) { remove(key: key) } }
        for name in names where name.hasPrefix(".") { unlink(directory.appendingPathComponent(name).path) }
    }

    /// Metadata first: without it the data file means nothing. Call with
    /// the lock held.
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

    /// Opens a regular file without following links and without blocking
    /// (a FIFO planted in the folder must not hang the main thread).
    private func openRegular(_ url: URL) throws -> (Int32, Int)? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw RecoveryError.damaged(String(cString: strerror(errno)))
        }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw RecoveryError.damaged("not a file")
        }
        return (fd, Int(st.st_size))
    }

    private func readMeta(_ url: URL) throws -> Data? {
        guard let (fd, size) = try openRegular(url) else { return nil }
        defer { close(fd) }
        // Slack for the header and checksums on top of the limit.
        guard size <= maxMetaBytes + Self.headerReadSize else { throw RecoveryError.damaged("too large") }
        return try readExactly(fd, size)
    }

    private func readFile(_ url: URL, upTo limit: Int) throws -> Data? {
        guard let (fd, size) = try openRegular(url) else { return nil }
        defer { close(fd) }
        return try readExactly(fd, min(size, limit))
    }

    private func readData(_ url: URL, count: Int) throws -> Data {
        guard let (fd, size) = try openRegular(url) else { throw RecoveryError.damaged("data file missing") }
        defer { close(fd) }
        guard size >= count else { throw RecoveryError.damaged("truncated") }
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

    /// Makes the written bytes durable before anything written later (the
    /// rename of the metadata); plain fsync where the barrier is missing.
    static func barrier(_ fd: Int32) -> Bool {
        fcntl(fd, F_BARRIERFSYNC) == 0 || fsync(fd) == 0
    }

    /// Temp file, barrier, rename, fsync of the folder; never world-readable.
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
        guard Self.barrier(fd) else { throw DocumentError.write(tmp.path, errno) }
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
    /// Written into every record; a discard removes only records of this
    /// writer (or the one it took over), never a newer one written by
    /// another hexwerk instance editing the same file.
    let owner = UUID().uuidString
    /// Owner of the record present when the window opened: the user has
    /// restored or discarded it, so it belongs to this window now.
    private let adopted: String?
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
        adopted = store.isTrusted() ? store.header(store.metaURL(key))?.owner : nil
    }

    func write(_ c: RecoveryContent) throws -> RecoveryStatus {
        let path = RecoveryStore.path(for: c.url)
        let newKey = RecoveryStore.key(forPath: path)
        let oldKey = key
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
        let fp = fingerprint ?? RecoveryFingerprint(of: c.original, fullHashLimit: store.fullHashLimit)
        fingerprint = fp
        let status: RecoveryStatus = try store.withLock(newKey, exclusive: true) {
            try append(p.added)
            // A copy: the running hash goes on with the next appended bytes.
            let digest = hasher
            let header = RecoveryFormat.Header(
                owner: owner, path: path, recordedAt: Date(), fingerprint: fp, dataName: dataName,
                addedCount: UInt64(p.added.count), addedHash: Data(digest.finalize()), hasHistory: true)
            var meta = RecoveryFormat.encode(header, p)
            if meta.count > store.maxMetaBytes {
                var h = header
                h.hasHistory = false
                meta = RecoveryFormat.encode(h, p)
            }
            guard meta.count <= store.maxMetaBytes else { return .tooLarge }
            try store.writeAtomically(meta, to: store.metaURL(newKey))
            // Data files of older states, or of another instance whose record
            // this one just replaced.
            store.removeData(of: newKey, except: dataName)
            return .saved
        }
        key = newKey
        if status == .tooLarge {
            discard()
            return .tooLarge
        }
        // Save As: the record moved; separate lock, never two held at once.
        if oldKey != newKey { removeOwned(oldKey) }
        return status
    }

    /// Writes the bytes not yet in the data file and syncs them. Starts the
    /// file over if it is not exactly what this writer wrote (removed by
    /// another instance's write or Discard All).
    private func append(_ added: Data) throws {
        let url = store.dataURL(dataName)
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw DocumentError.write(url.path, errno) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw DocumentError.write(url.path, EINVAL) }
        if st.st_size != off_t(written) {
            guard ftruncate(fd, 0) == 0 else { throw DocumentError.write(url.path, errno) }
            written = 0
            hasher = SHA256()
        }
        let chunk = 1 << 20
        while written < added.count {
            let piece = added.subdata(in: written ..< min(written + chunk, added.count))
            guard lseek(fd, off_t(written), SEEK_SET) >= 0 else { throw DocumentError.write(url.path, errno) }
            try Document.writeAll(fd, piece, path: url.path)
            hasher.update(data: piece)
            written += piece.count
        }
        guard RecoveryStore.barrier(fd) else { throw DocumentError.write(url.path, errno) }
    }

    func discard() {
        removeOwned(key)
        base = nil
        dataName = ""
        written = 0
        fingerprint = nil
    }

    /// Removes the record at `key` unless another instance wrote it last;
    /// leftovers of this writer go either way.
    private func removeOwned(_ key: String) {
        guard store.isTrusted() else { return }
        _ = try? store.withLock(key, exclusive: true) {
            if let h = store.header(store.metaURL(key)), h.owner != owner, h.owner != adopted {
                if !dataName.isEmpty, dataName != h.dataName { unlink(store.dataURL(dataName).path) }
                return
            }
            store.remove(key: key)
        }
    }
}

/// Writes recovery records in the background, a moment after the last
/// edit, so typing never waits for the disk. Every operation runs on one
/// serial queue, so a discard can never be overtaken by an older write.
///
/// While a write runs it holds the content; an edit in that moment makes
/// the document copy its added buffer once (copy-on-write), as for a
/// search or a save running in the background.
public final class RecoveryAutosave: @unchecked Sendable {
    // @unchecked: `writer` is only touched on `queue`, the rest under `lock`.
    let queue = DispatchQueue(label: "hexwerk.recovery", qos: .utility)
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
                    // Superseded, discarded or stopped while queued.
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

/// `magic, version, header, SHA-256(header), body, SHA-256(all before)`.
/// The header alone (path, date, owner) can be read and verified from the
/// first bytes of the file, without the possibly large body.
enum RecoveryFormat {
    static let magic = "hexwerk recovery"
    static let version: UInt64 = 2

    struct Header {
        var owner: String
        var path: String
        var recordedAt: Date
        var fingerprint: RecoveryFingerprint
        var dataName: String
        var addedCount: UInt64
        var addedHash: Data
        var hasHistory: Bool
    }

    static func encode(_ h: Header, _ p: RecoveryPayload) -> Data {
        var hw = WireWriter()
        hw.string(h.owner)
        hw.string(h.path)
        hw.double(h.recordedAt.timeIntervalSince1970)
        let f = h.fingerprint
        hw.uint(f.size)
        hw.int(f.mtimeSeconds)
        hw.int(f.mtimeNanoseconds)
        hw.int(f.ctimeSeconds)
        hw.int(f.ctimeNanoseconds)
        hw.uint(f.device)
        hw.uint(f.inode)
        hw.bytes(f.sample)
        hw.bytes(f.full)
        hw.string(h.dataName)
        hw.uint(h.addedCount)
        hw.bytes(h.addedHash)
        hw.bool(h.hasHistory)

        var w = WireWriter()
        w.string(magic)
        w.uint(version)
        w.bytes(hw.data)
        w.bytes(Data(SHA256.hash(data: hw.data)))
        w.uint(p.count)
        w.array(p.pieces, piece)
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

    /// The header from the start of a record (or the whole of it).
    static func decodeHeader(_ data: Data) throws -> Header {
        var r = WireReader(data)
        return try readHeader(&r)
    }

    private static func readHeader(_ r: inout WireReader) throws -> Header {
        do {
            guard try r.string() == magic, try r.uint() == version else { throw RecoveryError.damaged("unknown format") }
            let blob = try r.bytes()
            guard try r.bytes() == Data(SHA256.hash(data: blob)) else { throw RecoveryError.damaged("checksum") }
            var h = WireReader(blob)
            let owner = try h.string()
            let path = try h.string()
            let recordedAt = Date(timeIntervalSince1970: try h.double())
            let fp = RecoveryFingerprint(
                size: try h.uint(), mtimeSeconds: try h.int64(), mtimeNanoseconds: try h.int64(),
                ctimeSeconds: try h.int64(), ctimeNanoseconds: try h.int64(), device: try h.uint(), inode: try h.uint(),
                sample: try h.bytes(), full: try h.bytes())
            let header = Header(
                owner: owner, path: path, recordedAt: recordedAt, fingerprint: fp, dataName: try h.string(),
                addedCount: try h.uint(), addedHash: try h.bytes(), hasHistory: try h.bool())
            try h.expectEnd()
            return header
        } catch let e as WireError {
            throw RecoveryError.damaged(e.message)
        }
    }

    /// The payload comes back with an empty `added` (it is in the data file).
    static func decode(_ data: Data) throws -> (Header, RecoveryPayload) {
        let digestSize = SHA256.byteCount
        guard data.count > digestSize else { throw RecoveryError.damaged("truncated") }
        let body = data.prefix(data.count - digestSize)
        guard Data(SHA256.hash(data: body)) == data.suffix(digestSize) else { throw RecoveryError.damaged("checksum") }
        var r = WireReader(body)
        let header = try readHeader(&r)
        do {
            let count = try r.uint()
            var p = RecoveryPayload(
                added: Data(), pieces: try list(&r, readPiece), count: count, undo: [], redo: [],
                state: 1, lastState: 1, savedState: 0)
            if header.hasHistory {
                p.state = try r.int()
                p.lastState = try r.int()
                p.savedState = try r.int()
                p.undo = try list(&r, readStep)
                p.redo = try list(&r, readStep)
            }
            try r.expectEnd()
            return (header, p)
        } catch let e as WireError {
            throw RecoveryError.damaged(e.message)
        }
    }

    /// Like `WireReader.array`, but reserves little up front: an element
    /// takes at least 3 bytes on disk and far more in memory, so a count that
    /// fits the input could still ask for gigabytes before any is read.
    private static func list<T>(_ r: inout WireReader, _ read: (inout WireReader) throws -> T) throws -> [T] {
        let n = try r.count(minSize: 3)
        var out: [T] = []
        out.reserveCapacity(min(n, 4096))
        for _ in 0 ..< n { out.append(try read(&r)) }
        return out
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
        let changes = try list(&r) { r -> Document.Change in
            guard let index = Int(exactly: try r.uint()) else { throw WireError("index") }
            return Document.Change(index: index, removed: try list(&r, readPiece), inserted: try list(&r, readPiece))
        }
        return Document.Step(changes: changes, before: before, after: after)
    }
}
