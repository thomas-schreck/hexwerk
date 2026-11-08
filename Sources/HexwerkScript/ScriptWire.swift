import Foundation
import HexwerkCore

/// Binary form of a script run in the sandboxed helper (#102): the result
/// and, if the script changed the document, the working copy's pieces.
public struct ScriptOutcome: Sendable {
    public var result: ScriptResult
    public var edited: EditedContent?

    public init(result: ScriptResult, edited: EditedContent?) {
        self.result = result
        self.edited = edited
    }

    public func encoded() -> Data {
        var w = WireWriter()
        w.array(result.output) { $0.string($1) }
        w.int(result.edits)
        w.optional(result.select) { $0.range($1) }
        w.optional(result.goTo) { $0.uint($1) }
        w.optional(result.error) { w, e in
            w.string(e.message)
            w.optional(e.line) { $0.int($1) }
            w.bool(e.isTimeout)
        }
        w.array(result.annotations) { w, a in
            w.range(a.range)
            switch a.kind {
            case .bookmark(let name):
                w.u8(0)
                w.string(name)
            case .highlight(let color):
                w.u8(1)
                w.u8(UInt8(ScriptAnnotation.Color.allCases.firstIndex(of: color)!))
            }
        }
        w.optional(edited) { w, e in
            w.array(e.pieces) { w, p in
                w.bool(p.added)
                w.uint(p.start)
                w.uint(p.length)
            }
            w.bytes(e.newBytes)
        }
        return w.data
    }

    /// `baseCount` is the size of the document the script ran on. The
    /// helper may be compromised: annotations are checked against the
    /// limits `ScriptRunner` keeps and against the document's size after
    /// the run, and anything else is rejected as a whole.
    public init(encoded data: Data, baseCount: UInt64) throws {
        var r = WireReader(data)
        var result = ScriptResult()
        result.output = try r.array { try $0.string() }
        result.edits = try r.int()
        result.select = try r.optional { try $0.range() }
        result.goTo = try r.optional { try $0.uint() }
        result.error = try r.optional { r in
            ScriptError(message: try r.string(), line: try r.optional { try $0.int() }, isTimeout: try r.bool())
        }
        // Checked before anything is allocated for them.
        let count = try r.count(minSize: 4)
        guard count <= ScriptAnnotation.maxCount else { throw WireError("too many annotations") }
        guard count == 0 || result.error == nil else { throw WireError("annotations after an error") }
        var annotations: [ScriptAnnotation] = []
        annotations.reserveCapacity(count)
        for _ in 0 ..< count {
            let range = try r.range()
            switch try r.u8() {
            case 0:
                let name = try r.bytes()
                guard name.count <= ScriptAnnotation.maxNameBytes else { throw WireError("annotation name too long") }
                annotations.append(ScriptAnnotation(range: range, kind: .bookmark(name: String(decoding: name, as: UTF8.self))))
            case 1:
                let i = Int(try r.u8())
                guard ScriptAnnotation.Color.allCases.indices.contains(i) else { throw WireError("bad annotation color") }
                annotations.append(ScriptAnnotation(range: range, kind: .highlight(ScriptAnnotation.Color.allCases[i])))
            default:
                throw WireError("bad annotation kind")
            }
        }
        result.annotations = annotations
        edited = try r.optional { r in
            EditedContent(
                pieces: try r.array(minSize: 3) { r in
                    SnapshotWire.Piece(added: try r.bool(), start: try r.uint(), length: try r.uint())
                }, newBytes: try r.bytes())
        }
        self.result = result
        try r.expectEnd()
        // The size after the run: the edited pieces, or the unchanged base.
        var size = baseCount
        if let edited {
            size = 0
            for p in edited.pieces {
                let (sum, overflow) = size.addingReportingOverflow(p.length)
                guard !overflow else { throw WireError("document size overflow") }
                size = sum
            }
        }
        for a in annotations where a.range.isEmpty || a.range.upperBound > size {
            throw WireError("annotation outside the document")
        }
    }
}
