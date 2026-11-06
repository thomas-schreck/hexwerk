import Foundation

/// An editable view of a file. Edits never touch the mapped original: the
/// document is a list of pieces pointing either into the original file or
/// into an append-only buffer of new bytes (piece table).
///
/// Undo keeps whole piece lists. That is cheap because pieces are small and
/// the added buffer only grows, so an old piece list stays valid forever.
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
    private var pieces: [Piece]
    private var savedPieces: [Piece]
    private var undoStack: [[Piece]] = []
    private var redoStack: [[Piece]] = []
    private var diskStamp: DiskStamp

    public init(url: URL, readOnly: Bool = false) throws {
        self.url = url
        self.isReadOnly = readOnly
        original = try ByteSource(url: url)
        pieces = original.count > 0 ? [Piece(source: .original, start: 0, length: original.count)] : []
        savedPieces = pieces
        count = original.count
        diskStamp = try DiskStamp(url)
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
        savedPieces = snap.pieces
        count = snap.count
        diskStamp = (try? DiskStamp(snap.original.url)) ?? DiskStamp(size: 0, mtime: timespec())
    }

    /// Takes over the content of a working copy made from `base` as one undo
    /// step. Fails if this document changed since `base` was taken.
    public func adopt(_ copy: Document, base: Snapshot) throws {
        guard !isReadOnly else { throw DocumentError.readOnly }
        guard pieces == base.pieces, added.count == base.added.count else { throw DocumentError.changedMeanwhile }
        guard copy.pieces != pieces else { return }
        undoStack.append(pieces)
        redoStack.removeAll()
        // The copy's buffer starts with ours, so old undo states stay valid.
        added = copy.added
        setPieces(copy.pieces)
    }

    /// Runs several edits as one undo step. If `body` throws, all its edits
    /// are rolled back.
    public func grouped<R>(_ body: () throws -> R) throws -> R {
        let mark = undoStack.count
        let before = pieces
        do {
            let r = try body()
            if undoStack.count > mark + 1 { undoStack.removeSubrange(mark + 1 ..< undoStack.count) }
            return r
        } catch {
            undoStack.removeSubrange(mark ..< undoStack.count)
            setPieces(before)
            throw error
        }
    }

    public var isModified: Bool { pieces != savedPieces }
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
        Snapshot(original: original, added: added, pieces: pieces, count: count)
    }

    /// Ranges whose bytes differ from the file as last saved (for highlighting).
    public var modifiedRanges: [Range<UInt64>] {
        var out: [Range<UInt64>] = []
        var pos: UInt64 = 0
        for p in pieces {
            if p.source == .added { out.append(pos..<pos + p.length) }
            pos += p.length
        }
        return out
    }

    // MARK: Editing

    /// Replaces `range` with `bytes`. Covers overwrite, insert (empty range)
    /// and delete (empty bytes). A range reaching past the end is clipped.
    public func replace(_ range: Range<UInt64>, with bytes: Data) throws {
        guard !isReadOnly else { throw DocumentError.readOnly }
        guard range.lowerBound <= count else { throw DocumentError.outOfRange }
        if range.clamped(to: 0..<count).isEmpty && bytes.isEmpty { return }
        undoStack.append(pieces)
        redoStack.removeAll()
        apply(range, bytes)
    }

    /// Replaces several non-overlapping ranges with the same bytes as one
    /// undo step (replace all, fill).
    public func replaceAll(_ ranges: [Range<UInt64>], with bytes: Data) throws {
        guard !isReadOnly else { throw DocumentError.readOnly }
        guard !ranges.isEmpty else { return }
        guard ranges.allSatisfy({ $0.lowerBound <= count }) else { throw DocumentError.outOfRange }
        undoStack.append(pieces)
        redoStack.removeAll()
        // Back to front, so earlier offsets stay valid.
        for r in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) { apply(r, bytes) }
    }

    private func apply(_ range: Range<UInt64>, _ bytes: Data) {
        let r = range.clamped(to: 0..<count)
        // Keep what lies before and after the range, put the new bytes between.
        var before: [Piece] = [], after: [Piece] = []
        var pos: UInt64 = 0
        for p in pieces {
            let s = pos, e = pos + p.length
            pos = e
            if s < r.lowerBound {
                before.append(Piece(source: p.source, start: p.start, length: min(e, r.lowerBound) - s))
            }
            if e > r.upperBound {
                let skip = max(s, r.upperBound) - s
                after.append(Piece(source: p.source, start: p.start + skip, length: p.length - skip))
            }
        }
        var middle: [Piece] = []
        if !bytes.isEmpty {
            middle.append(Piece(source: .added, start: UInt64(added.count), length: UInt64(bytes.count)))
            added.append(bytes)
        }
        pieces = before + middle + after
        count = count - UInt64(r.count) + UInt64(bytes.count)
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
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(pieces)
        setPieces(prev)
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(pieces)
        setPieces(next)
    }

    private func setPieces(_ p: [Piece]) {
        pieces = p
        count = p.reduce(0) { $0 + $1.length }
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
    }

    /// True if the file on disk changed since it was opened or last saved.
    public func hasChangedOnDisk() -> Bool {
        (try? DiskStamp(url)) != diskStamp
    }

    /// Saves to the current file. Undo history ends here: after saving, the
    /// document is re-based on the new file content.
    public func save(mode: SaveMode = .atomic) throws {
        guard !isReadOnly else { throw DocumentError.readOnly }
        guard isModified else { return }
        switch mode {
        case .atomic:
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
        try writeReplacement(at: newURL)
        try reload(newURL)
    }

    private func reload(_ newURL: URL) throws {
        url = newURL
        original = try ByteSource(url: newURL)
        added = Data()
        pieces = original.count > 0 ? [Piece(source: .original, start: 0, length: original.count)] : []
        savedPieces = pieces
        count = original.count
        undoStack.removeAll()
        redoStack.removeAll()
        diskStamp = try DiskStamp(newURL)
    }

    private func writeReplacement(at target: URL) throws {
        let dir = target.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(target.lastPathComponent).hexwerk-\(UUID().uuidString.prefix(8))")
        // Keep the permission bits of the file being replaced.
        var mode: mode_t = 0o644
        var st = stat()
        if stat(target.path, &st) == 0 { mode = st.st_mode & 0o7777 }

        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, mode)
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
        guard fsync(fd) == 0 else { throw DocumentError.write(tmp.path, errno) }
        guard rename(tmp.path, target.path) == 0 else { throw DocumentError.write(target.path, errno) }
        ok = true
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
    public let count: UInt64

    /// Bytes in `range`, clipped to the content.
    public func read(_ range: Range<UInt64>) -> Data {
        let r = range.clamped(to: 0..<count)
        var out = Data(capacity: Int(r.count))
        var pos: UInt64 = 0
        for p in pieces {
            let pieceRange = pos..<pos + p.length
            pos += p.length
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
    /// otherwise the bytes are materialized (SPEC R-4).
    public func withContiguousBytes<R>(_ range: Range<UInt64>,
                                       _ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        let r = range.clamped(to: 0..<count)
        var pos: UInt64 = 0
        for p in pieces {
            let pieceRange = pos..<pos + p.length
            pos += p.length
            guard pieceRange.contains(r.lowerBound) || (r.isEmpty && pieceRange.upperBound == r.lowerBound) else { continue }
            if p.source == .original, r.upperBound <= pieceRange.upperBound {
                let from = Int(p.start + (r.lowerBound - pieceRange.lowerBound))
                return try original.withUnsafeBytes { all in
                    try body(UnsafeRawBufferPointer(rebasing: all[from ..< from + r.count]))
                }
            }
            break
        }
        return try read(r).withUnsafeBytes(body)
    }
}

/// Size + modification time, to notice changes made by other programs.
struct DiskStamp: Equatable {
    let size: UInt64
    let mtime: timespec

    init(size: UInt64, mtime: timespec) {
        self.size = size
        self.mtime = mtime
    }

    init(_ url: URL) throws {
        var st = stat()
        guard stat(url.path, &st) == 0 else { throw DocumentError.write(url.path, errno) }
        size = UInt64(st.st_size)
        mtime = st.st_mtimespec
    }

    static func == (a: DiskStamp, b: DiskStamp) -> Bool {
        a.size == b.size && a.mtime.tv_sec == b.mtime.tv_sec && a.mtime.tv_nsec == b.mtime.tv_nsec
    }
}

public enum DocumentError: Error, CustomStringConvertible {
    case readOnly
    case outOfRange
    case lengthChanged
    case bytesMoved
    case changedMeanwhile
    case write(String, Int32)

    public var description: String {
        switch self {
        case .readOnly: L("Document is read-only")
        case .outOfRange: L("Offset is past the end of the file")
        case .lengthChanged: L("Length changed: cannot save in place")
        case .bytesMoved: L("Bytes were moved: cannot save in place")
        case .changedMeanwhile: L("Document was changed in the meantime")
        case .write(let p, let e): "\(p): \(String(cString: strerror(e)))"
        }
    }
}
