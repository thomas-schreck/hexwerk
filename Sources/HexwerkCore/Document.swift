import Foundation

/// An editable view of a file. Edits never touch the mapped original: the
/// document is a list of pieces pointing either into the original file or
/// into an append-only buffer of new bytes (piece table).
///
/// Undo keeps, per step, only the pieces an edit replaced and the ones it put
/// in their place, never whole piece lists: after a Replace All with 100k
/// hits a full copy per keystroke would cost megabytes. The added buffer
/// only grows, so recorded pieces stay valid forever.
public final class Document {
    struct Piece: Equatable, Sendable {
        enum Source: Sendable { case original, added }
        var source: Source
        var start: UInt64
        var length: UInt64
    }

    public private(set) var url: URL
    public let isReadOnly: Bool
    public private(set) var count: UInt64

    private var original: ByteSource
    private var added = Data()
    private var pieces: [Piece] { didSet { offsetsCache = nil } }
    /// Start offset of each piece, built on demand for binary search.
    private var offsetsCache: [UInt64]?
    private var undoStack: [Step] = []
    private var redoStack: [Step] = []
    /// Identifies the current piece list; new for every edit, restored by
    /// undo/redo. Cheaper than comparing piece lists on every redraw.
    private var state = 0
    private var lastState = 0
    private var savedState = 0
    private var modifiedCache: (state: Int, ranges: [Range<UInt64>])?

    /// `pieces[index ..< index + removed.count]` was replaced by `inserted`.
    struct Change {
        var index: Int
        var removed: [Piece]
        var inserted: [Piece]
    }

    /// One undo step: changes in the order they were applied, and the states
    /// before and after.
    struct Step {
        var changes: [Change]
        var before: Int
        var after: Int
    }
    /// The file as mapped (or last saved).
    private var diskStamp: DiskStamp
    /// Told about every replaced range and its new length (after clipping),
    /// in the order applied, so marks such as bookmarks can follow the data.
    /// Not called for undo/redo, which swap whole piece lists.
    public var didReplace: ((_ range: Range<UInt64>, _ newLength: UInt64) -> Void)?
    /// A different file at `url` (or none) the user chose to overwrite
    /// (`keepAfterReplace`).
    private var acceptedStamp: DiskStamp?
    private var acceptedMissing = false

    public init(url: URL, readOnly: Bool = false) throws {
        self.url = url
        self.isReadOnly = readOnly
        original = try ByteSource(url: url, privateCopy: true)
        pieces = original.count > 0 ? [Piece(source: .original, start: 0, length: original.count)] : []
        count = original.count
        diskStamp = original.stamp
    }

    /// Working copy of a snapshot for edits off the main thread (scripts).
    /// Shares the read-only file mapping; never saved itself, its result is
    /// taken over with `adopt(_:base:)`.
    public init(editing snap: Snapshot, readOnly: Bool = false) {
        url = snap.original.url
        isReadOnly = readOnly
        original = snap.original
        added = snap.added
        pieces = snap.pieces
        count = snap.count
        diskStamp = (try? DiskStamp(snap.original.url)) ?? DiskStamp(size: 0, mtime: timespec(), device: 0, inode: 0)
    }

    /// Takes over the content of a working copy made from `base` as one undo
    /// step. Fails if this document changed since `base` was taken.
    public func adopt(_ copy: Document, base: Snapshot) throws {
        guard !isReadOnly else { throw DocumentError.readOnly }
        guard pieces == base.pieces, added.count == base.added.count else { throw DocumentError.changedMeanwhile }
        guard copy.pieces != pieces else { return }
        // The copy's buffer starts with ours, so old undo states stay valid.
        added = copy.added
        record([replacePieces(0, pieces.count, with: copy.pieces)])
    }

    /// Runs several edits as one undo step. If `body` throws, all its edits
    /// are rolled back.
    public func grouped<R>(_ body: () throws -> R) throws -> R {
        let mark = undoStack.count
        do {
            let r = try body()
            if undoStack.count > mark + 1 {
                let steps = undoStack[mark...]
                let merged = Step(changes: steps.flatMap(\.changes), before: steps.first!.before, after: steps.last!.after)
                undoStack.removeSubrange(mark...)
                undoStack.append(merged)
            }
            return r
        } catch {
            while undoStack.count > mark { revert(undoStack.removeLast()) }
            throw error
        }
    }

    /// Runs edits that belong to the previous undo step (the second hex
    /// digit of a byte), so one undo takes back the whole byte. Without a
    /// previous step it behaves like `grouped`.
    public func amendingLastEdit<R>(_ body: () throws -> R) throws -> R {
        guard !undoStack.isEmpty else { return try grouped(body) }
        let mark = undoStack.count
        do {
            let r = try body()
            if undoStack.count > mark {
                // Fold the new steps into the one before them.
                let steps = undoStack[(mark - 1)...]
                let merged = Step(changes: steps.flatMap(\.changes), before: steps.first!.before, after: steps.last!.after)
                undoStack.removeSubrange((mark - 1)...)
                undoStack.append(merged)
            }
            return r
        } catch {
            while undoStack.count > mark { revert(undoStack.removeLast()) }
            throw error
        }
    }

    public var isModified: Bool { state != savedState }

    /// Pieces held by undo and redo (memory use, for tests).
    var undoFootprint: Int {
        (undoStack + redoStack).reduce(0) { $0 + $1.changes.reduce(0) { $0 + $1.removed.count + $1.inserted.count } }
    }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    // MARK: Reading

    /// Bytes in `range`, clipped to the document.
    public func read(_ range: Range<UInt64>) -> Data {
        snapshot().read(range)
    }

    /// Immutable copy of the current content for background work (search,
    /// diff, hashes). Cheap: pieces and the added buffer are copy-on-write.
    public func snapshot() -> Snapshot {
        let offsets = offsetsCache ?? Snapshot.offsets(of: pieces)
        offsetsCache = offsets
        return Snapshot(original: original, added: added, pieces: pieces, offsets: offsets, count: count)
    }

    /// Ranges whose bytes differ from the file as last saved (for highlighting).
    /// Cached per state: the hex view asks on every draw.
    public var modifiedRanges: [Range<UInt64>] {
        if let c = modifiedCache, c.state == state { return c.ranges }
        var out: [Range<UInt64>] = []
        var pos: UInt64 = 0
        for p in pieces {
            if p.source == .added { out.append(pos..<pos + p.length) }
            pos += p.length
        }
        modifiedCache = (state, out)
        return out
    }

    // MARK: Editing

    /// Replaces `range` with `bytes`. Covers overwrite, insert (empty range)
    /// and delete (empty bytes). A range reaching past the end is clipped.
    public func replace(_ range: Range<UInt64>, with bytes: Data) throws {
        guard !isReadOnly else { throw DocumentError.readOnly }
        guard range.lowerBound <= count else { throw DocumentError.outOfRange }
        if range.clamped(to: 0..<count).isEmpty && bytes.isEmpty { return }
        record([apply(range, bytes)])
    }

    /// Replaces several non-overlapping ranges with the same bytes as one
    /// undo step (replace all, fill).
    public func replaceAll(_ ranges: [Range<UInt64>], with bytes: Data) throws {
        guard !isReadOnly else { throw DocumentError.readOnly }
        guard !ranges.isEmpty else { return }
        guard ranges.allSatisfy({ $0.lowerBound <= count }) else { throw DocumentError.outOfRange }
        // Back to front, so earlier offsets stay valid.
        record(ranges.sorted(by: { $0.lowerBound > $1.lowerBound }).map { apply($0, bytes) })
    }

    /// Pushes one undo step for changes already applied.
    private func record(_ changes: [Change]) {
        lastState += 1
        undoStack.append(Step(changes: changes, before: state, after: lastState))
        redoStack.removeAll()
        state = lastState
    }

    private func apply(_ range: Range<UInt64>, _ bytes: Data) -> Change {
        let r = range.clamped(to: 0..<count)
        // Pieces ending at or before the range and starting at or after it
        // stay; the ones in between are cut down to the parts outside the
        // range, with the new bytes between them.
        var lo = 0, pos: UInt64 = 0
        while lo < pieces.count, pos + pieces[lo].length <= r.lowerBound {
            pos += pieces[lo].length
            lo += 1
        }
        let loStart = pos
        var hi = lo
        while hi < pieces.count, pos < r.upperBound {
            pos += pieces[hi].length
            hi += 1
        }
        var middle: [Piece] = []
        if lo < hi, loStart < r.lowerBound {
            let p = pieces[lo]
            middle.append(Piece(source: p.source, start: p.start, length: r.lowerBound - loStart))
        }
        if !bytes.isEmpty {
            middle.append(Piece(source: .added, start: UInt64(added.count), length: UInt64(bytes.count)))
            added.append(bytes)
        }
        if lo < hi, pos > r.upperBound {
            let p = pieces[hi - 1]
            let skip = p.length - (pos - r.upperBound)
            middle.append(Piece(source: p.source, start: p.start + skip, length: p.length - skip))
        }
        let change = replacePieces(lo, hi - lo, with: middle)
        didReplace?(r, UInt64(bytes.count))
        return change
    }

    private func replacePieces(_ index: Int, _ n: Int, with new: [Piece]) -> Change {
        let old = Array(pieces[index ..< index + n])
        pieces.replaceSubrange(index ..< index + n, with: new)
        count = count - old.reduce(0) { $0 + $1.length } + new.reduce(0) { $0 + $1.length }
        return Change(index: index, removed: old, inserted: new)
    }

    private func revert(_ step: Step) {
        for c in step.changes.reversed() { _ = replacePieces(c.index, c.inserted.count, with: c.removed) }
        state = step.before
    }

    private func reapply(_ step: Step) {
        for c in step.changes { _ = replacePieces(c.index, c.removed.count, with: c.inserted) }
        state = step.after
    }

    /// Overwrites bytes starting at `offset`; bytes past the end are appended.
    public func overwrite(at offset: UInt64, with bytes: Data) throws {
        // Saturate: replace() rejects an offset past the end and clips the range.
        let (end, overflow) = offset.addingReportingOverflow(UInt64(bytes.count))
        try replace(offset ..< (overflow ? .max : end), with: bytes)
    }

    public func insert(_ bytes: Data, at offset: UInt64) throws {
        try replace(offset..<offset, with: bytes)
    }

    public func delete(_ range: Range<UInt64>) throws {
        try replace(range, with: Data())
    }

    public func undo() {
        guard let step = undoStack.popLast() else { return }
        revert(step)
        redoStack.append(step)
    }

    public func redo() {
        guard let step = redoStack.popLast() else { return }
        reapply(step)
        undoStack.append(step)
    }

    // MARK: Saving

    public enum SaveMode {
        /// Write a replacement file next to the original, then rename it over
        /// the original. The original is untouched until the rename.
        case atomic
        /// Write only the changed bytes into the file. Only allowed when the
        /// length is unchanged and no original bytes were moved (every
        /// unmodified byte is still at its offset in the file); an
        /// interruption can leave a partly saved file.
        case inPlace
        /// In place if the file is at least `inPlaceMinimumSize` and only
        /// bytes were overwritten (nothing inserted, deleted or moved),
        /// otherwise atomic. Changing one byte of a huge file then costs one
        /// write instead of a full copy (and needs no free space).
        case automatic
    }

    /// Below this size an atomic save is cheap enough to always be preferred.
    public static let inPlaceMinimumSize: UInt64 = 64 << 20

    /// True if saving in place would write the right bytes.
    public var canSaveInPlace: Bool { count == original.count && originalBytesInPlace }
    /// How the file at `url` differs from the one this document maps.
    public enum DiskChange: Sendable, Equatable {
        case none
        /// Another file now sits at the path (rewritten by an atomic save,
        /// moved or deleted). The mapping still holds the old file, intact.
        case replaced
        /// The opened file itself was written to or truncated. The document
        /// no longer shows what is on disk: it maps a clone that kept the
        /// old content or, without one (no APFS), the file itself, whose
        /// mapping is then not guaranteed to be consistent (see ByteSource).
        case modified
    }

    public func diskChange() -> DiskChange {
        guard let now = try? DiskStamp(url) else { return acceptedMissing ? .none : .replaced }
        if now.sameFile(as: diskStamp) { return now == diskStamp ? .none : .modified }
        return now == acceptedStamp ? .none : .replaced
    }

    /// True if the file on disk changed since it was opened or last saved.
    public func hasChangedOnDisk() -> Bool { diskChange() != .none }

    /// After `.replaced`: keep editing this version; a later save overwrites
    /// the other file without being reported again.
    public func keepAfterReplace() {
        acceptedStamp = try? DiskStamp(url)
        acceptedMissing = acceptedStamp == nil
    }

    /// Discards all edits and maps the file at `url` afresh.
    public func revertToDisk() throws {
        try reload(url)
    }

    /// Saves to the current file. Undo history ends here: after saving, the
    /// document is re-based on the new file content.
    ///
    /// Refuses with `changedOnDisk` if the mapped file was changed in place
    /// by another program: the bytes it would copy are no longer the ones
    /// the user saw. A replaced file does not block saving; ask first.
    public func save(mode: SaveMode = .atomic) throws {
        guard !isReadOnly else { throw DocumentError.readOnly }
        guard isModified else { return }
        guard diskChange() != .modified else { throw DocumentError.changedOnDisk }
        switch mode {
        case .automatic where original.count >= Self.inPlaceMinimumSize && canSaveInPlace:
            try writeChangedBytesInPlace()
        case .atomic, .automatic:
            try writeReplacement(at: url)
        case .inPlace:
            guard count == original.count else { throw DocumentError.lengthChanged }
            // Only new bytes are written, so any original byte that moved
            // (delete here, insert there) would never reach the disk.
            guard originalBytesInPlace else { throw DocumentError.bytesMoved }
            try writeChangedBytesInPlace()
        }
        try reload(url)
    }

    /// Writes the document to `newURL` and continues editing that file.
    public func save(as newURL: URL) throws {
        guard diskChange() != .modified else { throw DocumentError.changedOnDisk }
        try writeReplacement(at: newURL)
        try reload(newURL)
    }

    private func reload(_ newURL: URL) throws {
        url = newURL
        original = try ByteSource(url: newURL, privateCopy: true)
        added = Data()
        pieces = original.count > 0 ? [Piece(source: .original, start: 0, length: original.count)] : []
        count = original.count
        lastState += 1
        state = lastState
        savedState = state
        undoStack.removeAll()
        redoStack.removeAll()
        diskStamp = original.stamp
        acceptedStamp = nil
        acceptedMissing = false
    }

    /// Writes the document to a temp file next to `target` and renames it
    /// over `target`. A symlink is followed, so the link stays a link and its
    /// target gets the new content. Extended attributes (including the
    /// quarantine flag), ACLs, permission bits and, where allowed, owner and
    /// group of the replaced file are carried over.
    private func writeReplacement(at link: URL) throws {
        let target = Self.resolvingSymlinks(link)
        let dir = target.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(target.lastPathComponent).hexwerk-\(UUID().uuidString.prefix(8))")
        var old = stat()
        let replacing = stat(target.path, &old) == 0

        // A new file gets the usual 0666 minus umask; a replacement starts
        // private and gets the old mode below.
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, replacing ? 0o600 : 0o666)
        guard fd >= 0 else { throw DocumentError.write(tmp.path, errno) }
        var ok = false
        defer {
            close(fd)
            if !ok { unlink(tmp.path) }
        }
        let chunk: UInt64 = 1 << 20
        var pos: UInt64 = 0
        while pos < count {
            let data = read(pos ..< min(pos + chunk, count))
            try writeAll(fd, data, path: tmp.path)
            pos += UInt64(data.count)
        }
        if replacing {
            // A failure here must not silently strip e.g. com.apple.quarantine
            // from a malware sample, so it fails the save.
            guard copyfile(target.path, tmp.path, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR)) == 0 else {
                throw DocumentError.write(tmp.path, errno)
            }
            // Only root may give a file away and only to groups one is in;
            // otherwise the file ends up owned by us, as with any editor.
            if fchown(fd, old.st_uid, old.st_gid) != 0 { _ = fchown(fd, uid_t.max, old.st_gid) }
            // After chown, which clears set-id bits; not via open(), whose
            // mode is reduced by the umask.
            guard fchmod(fd, old.st_mode & 0o7777) == 0 else { throw DocumentError.write(tmp.path, errno) }
        }
        guard fsync(fd) == 0 else { throw DocumentError.write(tmp.path, errno) }
        guard rename(tmp.path, target.path) == 0 else { throw DocumentError.write(target.path, errno) }
        ok = true
        // Make the rename itself durable.
        let dfd = open(dir.path, O_RDONLY)
        if dfd >= 0 {
            fsync(dfd)
            close(dfd)
        }
    }

    /// The file a path finally refers to; the path itself if it does not
    /// exist (yet).
    static func resolvingSymlinks(_ url: URL) -> URL {
        guard let p = realpath(url.path, nil) else { return url }
        defer { free(p) }
        return URL(fileURLWithPath: String(cString: p))
    }

    /// True if every piece taken from the file sits at its own file offset.
    private var originalBytesInPlace: Bool {
        var pos: UInt64 = 0
        for p in pieces {
            if p.source == .original, p.start != pos { return false }
            pos += p.length
        }
        return true
    }

    private func writeChangedBytesInPlace() throws {
        let fd = open(url.path, O_WRONLY)
        guard fd >= 0 else { throw DocumentError.write(url.path, errno) }
        defer { close(fd) }
        for r in modifiedRanges {
            let data = read(r)
            guard lseek(fd, off_t(r.lowerBound), SEEK_SET) >= 0 else { throw DocumentError.write(url.path, errno) }
            try writeAll(fd, data, path: url.path)
        }
        guard fsync(fd) == 0 else { throw DocumentError.write(url.path, errno) }
    }

    private func writeAll(_ fd: Int32, _ data: Data, path: String) throws {
        try data.withUnsafeBytes { buf in
            var done = 0
            while done < buf.count {
                let n = Foundation.write(fd, buf.baseAddress! + done, buf.count - done)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw DocumentError.write(path, errno)
                }
                done += n
            }
        }
    }
}

/// Frozen document content, safe to read from any thread.
public struct Snapshot: Sendable {
    let original: ByteSource
    let added: Data
    let pieces: [Document.Piece]
    /// Start offset of each piece in the content.
    let offsets: [UInt64]
    public let count: UInt64

    static func offsets(of pieces: [Document.Piece]) -> [UInt64] {
        var out: [UInt64] = []
        out.reserveCapacity(pieces.count)
        var pos: UInt64 = 0
        for p in pieces {
            out.append(pos)
            pos += p.length
        }
        return out
    }

    /// Index of the piece containing `offset` (pieces.count if past the end).
    /// Binary search: after many edits a linear walk per 1 MiB chunk made
    /// saving and scanning O(pieces²).
    func pieceIndex(at offset: UInt64) -> Int {
        var lo = 0, hi = pieces.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if offsets[mid] + pieces[mid].length <= offset { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Bytes in `range`, clipped to the content.
    public func read(_ range: Range<UInt64>) -> Data {
        let r = range.clamped(to: 0..<count)
        var out = Data(capacity: Int(r.count))
        guard !r.isEmpty else { return out }
        for i in pieceIndex(at: r.lowerBound) ..< pieces.count {
            let p = pieces[i]
            let pos = offsets[i] + p.length
            let pieceRange = offsets[i]..<pos
            let hit = pieceRange.clamped(to: r)
            if hit.isEmpty { continue }
            let from = p.start + (hit.lowerBound - pieceRange.lowerBound)
            switch p.source {
            case .original: out.append(original.read(from ..< from + UInt64(hit.count)))
            case .added: out.append(added.subdata(in: Int(from)..<Int(from) + hit.count))
            }
            if pos >= r.upperBound { break }
        }
        return out
    }

    /// Contiguous bytes of `range` (clipped). If the range lies inside one
    /// unmodified piece the file mapping is passed directly, without a copy;
    /// otherwise the bytes are materialized.
    public func withContiguousBytes<R>(_ range: Range<UInt64>,
                                       _ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        let r = range.clamped(to: 0..<count)
        // An empty range at a piece end may use that piece, as before.
        let i = pieceIndex(at: r.isEmpty && r.lowerBound > 0 ? r.lowerBound - 1 : r.lowerBound)
        if i < pieces.count {
            let p = pieces[i]
            let pieceRange = offsets[i] ..< offsets[i] + p.length
            if p.source == .original, r.upperBound <= pieceRange.upperBound {
                let from = Int(p.start + (r.lowerBound - pieceRange.lowerBound))
                return try original.withUnsafeBytes { all in
                    try body(UnsafeRawBufferPointer(rebasing: all[from ..< from + r.count]))
                }
            }
        }
        return try read(r).withUnsafeBytes(body)
    }
}

/// Identity, size and modification time of a file, to notice changes made
/// by other programs.
public struct DiskStamp: Equatable, Sendable {
    let size: UInt64
    let mtime: timespec
    let device: UInt64
    let inode: UInt64

    init(_ st: stat) {
        size = UInt64(st.st_size)
        mtime = st.st_mtimespec
        device = UInt64(bitPattern: Int64(st.st_dev))
        inode = UInt64(st.st_ino)
    }

    init(size: UInt64, mtime: timespec, device: UInt64, inode: UInt64) {
        self.size = size
        self.mtime = mtime
        self.device = device
        self.inode = inode
    }

    public init(_ url: URL) throws {
        var st = stat()
        guard stat(url.path, &st) == 0 else { throw DocumentError.write(url.path, errno) }
        self.init(st)
    }

    /// Same file (not just same path), possibly with other content.
    func sameFile(as other: DiskStamp) -> Bool {
        device == other.device && inode == other.inode
    }

    public static func == (a: DiskStamp, b: DiskStamp) -> Bool {
        a.sameFile(as: b) && a.size == b.size
            && a.mtime.tv_sec == b.mtime.tv_sec && a.mtime.tv_nsec == b.mtime.tv_nsec
    }
}

public enum DocumentError: Error, CustomStringConvertible {
    case readOnly
    case outOfRange
    case lengthChanged
    case bytesMoved
    case changedMeanwhile
    case changedOnDisk
    case write(String, Int32)

    public var description: String {
        switch self {
        case .readOnly: L("Document is read-only")
        case .outOfRange: L("Offset is past the end of the file")
        case .lengthChanged: L("Length changed: cannot save in place")
        case .bytesMoved: L("Bytes were moved: cannot save in place")
        case .changedMeanwhile: L("Document was changed in the meantime")
        case .changedOnDisk: L("The file was changed by another program; reload it before saving")
        case .write(let p, let e): "\(p): \(String(cString: strerror(e)))"
        }
    }
}
