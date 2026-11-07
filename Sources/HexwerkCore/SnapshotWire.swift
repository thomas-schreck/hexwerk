import Foundation

/// Document content as sent to the sandboxed helper (#102): the piece table
/// plus only the edited bytes it references. The file bytes travel as a
/// descriptor of the mapping (`ByteSource.fileHandle()`), so a multi-GB
/// file is never copied, and an unsaved edit costs only its own bytes.
public struct SnapshotWire: Codable, Sendable, Equatable {
    public struct Piece: Codable, Sendable, Equatable {
        /// true: bytes from `added`; false: bytes from the file.
        public var added: Bool
        public var start: UInt64
        public var length: UInt64

        public init(added: Bool, start: UInt64, length: UInt64) {
            self.added = added
            self.start = start
            self.length = length
        }
    }

    public var pieces: [Piece]
    /// Bytes of the added pieces, back to back (the document's own buffer
    /// also holds undone and overwritten edits, which are left out).
    public var added: Data
    public var count: UInt64

    public init(pieces: [Piece], added: Data, count: UInt64) {
        self.pieces = pieces
        self.added = added
        self.count = count
    }
}

/// Where each compacted run of `SnapshotWire.added` came from in the
/// document's added buffer; kept by the app to map a script's result back.
public struct AddedMap: Sendable {
    struct Segment: Sendable {
        let wireStart: UInt64
        let bufferStart: UInt64
        let length: UInt64
    }
    let segments: [Segment]
    /// Size of the compacted buffer.
    let wireCount: UInt64
    /// Size of the document's added buffer at the snapshot.
    let bufferCount: UInt64
}

/// A script's result: the edited working copy's pieces, with added pieces
/// pointing into the sent `added` bytes followed by `newBytes`.
public struct EditedContent: Sendable, Equatable {
    public var pieces: [SnapshotWire.Piece]
    public var newBytes: Data

    public init(pieces: [SnapshotWire.Piece], newBytes: Data) {
        self.pieces = pieces
        self.newBytes = newBytes
    }
}

public enum SnapshotWireError: Error, CustomStringConvertible, Sendable {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let m): L("Invalid document data: %@", m)
        }
    }
}

extension Snapshot {
    /// Descriptor of the file bytes, for the helper.
    public func fileHandle() -> FileHandle? { original.fileHandle() }

    /// The file this snapshot reads from (for names in messages).
    public var fileURL: URL { original.url }

    public func wire() -> (SnapshotWire, AddedMap) {
        var out: [SnapshotWire.Piece] = []
        out.reserveCapacity(pieces.count)
        var compact = Data()
        var segments: [AddedMap.Segment] = []
        for p in pieces {
            switch p.source {
            case .original:
                out.append(.init(added: false, start: p.start, length: p.length))
            case .added:
                let at = UInt64(compact.count)
                compact.append(added.subdata(in: Int(p.start) ..< Int(p.start + p.length)))
                segments.append(.init(wireStart: at, bufferStart: p.start, length: p.length))
                out.append(.init(added: true, start: at, length: p.length))
            }
        }
        return (
            SnapshotWire(pieces: out, added: compact, count: count),
            AddedMap(segments: segments, wireCount: UInt64(compact.count), bufferCount: UInt64(added.count))
        )
    }

    /// Rebuilds a snapshot in the helper over the received file mapping.
    /// Checks every piece: the bytes come from another process.
    public init(wire: SnapshotWire, original: ByteSource) throws {
        let pieces = try Self.validated(wire.pieces, fileCount: original.count, addedCount: UInt64(wire.added.count))
        let offsets = Snapshot.offsets(of: pieces)
        let total = pieces.reduce(UInt64(0)) { $0 + $1.length }
        guard total == wire.count else {
            throw SnapshotWireError.invalid("size \(total) ≠ \(wire.count)")
        }
        self.init(original: original, added: wire.added, pieces: pieces, offsets: offsets, count: total)
    }

    static func validated(
        _ wire: [SnapshotWire.Piece], fileCount: UInt64,
        addedCount: UInt64
    ) throws -> [Document.Piece] {
        var total: UInt64 = 0
        return try wire.map { p in
            let limit = p.added ? addedCount : fileCount
            let (end, o1) = p.start.addingReportingOverflow(p.length)
            let (sum, o2) = total.addingReportingOverflow(p.length)
            // The file part fails if the file on disk shrank since it was opened
            // (and was not cloned): better an error than wrong offsets.
            guard !o1, !o2, end <= limit else {
                throw SnapshotWireError.invalid(p.added ? "edited bytes out of range" : "file changed on disk")
            }
            total = sum
            return Document.Piece(source: p.added ? .added : .original, start: p.start, length: p.length)
        }
    }
}

extension Document {
    /// The working copy's content for the app, relative to the wire it was
    /// made from (`init(editing:)` over `Snapshot(wire:original:)`).
    public func editedContent(sentAddedCount: Int) -> EditedContent {
        EditedContent(
            pieces: pieceList.map { .init(added: $0.source == .added, start: $0.start, length: $0.length) },
            newBytes: addedBuffer.count > sentAddedCount ? addedBuffer.subdata(in: sentAddedCount ..< addedBuffer.count) : Data())
    }

    /// Takes over a script's result computed in the helper as one undo step,
    /// like `adopt(_:base:)`. `map` and `base` belong to the wire that was
    /// sent; the helper's pieces are checked, never trusted.
    public func adopt(_ edited: EditedContent, map: AddedMap, base: Snapshot) throws {
        let sent = map.wireCount
        let (limit, o) = sent.addingReportingOverflow(UInt64(edited.newBytes.count))
        guard !o else { throw SnapshotWireError.invalid("edited bytes out of range") }
        _ = try Snapshot.validated(edited.pieces, fileCount: base.original.count, addedCount: limit)
        var pieces: [Piece] = []
        pieces.reserveCapacity(edited.pieces.count)
        for p in edited.pieces {
            guard p.added else {
                pieces.append(Piece(source: .original, start: p.start, length: p.length))
                continue
            }
            // Split at segment boundaries and at the start of the new bytes.
            var start = p.start, left = p.length
            while left > 0 {
                if start >= sent {
                    pieces.append(Piece(source: .added, start: map.bufferCount + (start - sent), length: left))
                    break
                }
                guard let seg = map.segment(containing: start) else {
                    throw SnapshotWireError.invalid("edited bytes out of range")
                }
                let n = min(left, seg.wireStart + seg.length - start)
                pieces.append(Piece(source: .added, start: seg.bufferStart + (start - seg.wireStart), length: n))
                start += n
                left -= n
            }
        }
        var added = base.added
        guard added.count == Int(map.bufferCount) else { throw DocumentError.changedMeanwhile }
        added.append(edited.newBytes)
        try adopt(pieces: pieces, added: added, base: base)
    }
}

extension AddedMap {
    func segment(containing offset: UInt64) -> Segment? {
        var lo = 0, hi = segments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if segments[mid].wireStart + segments[mid].length <= offset { lo = mid + 1 } else { hi = mid }
        }
        return lo < segments.count && segments[lo].wireStart <= offset ? segments[lo] : nil
    }
}
