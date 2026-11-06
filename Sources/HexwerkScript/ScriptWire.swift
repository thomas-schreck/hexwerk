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

    public init(encoded data: Data) throws {
        var r = WireReader(data)
        var result = ScriptResult()
        result.output = try r.array { try $0.string() }
        result.edits = try r.int()
        result.select = try r.optional { try $0.range() }
        result.goTo = try r.optional { try $0.uint() }
        result.error = try r.optional { r in
            ScriptError(message: try r.string(), line: try r.optional { try $0.int() }, isTimeout: try r.bool())
        }
        edited = try r.optional { r in
            EditedContent(pieces: try r.array(minSize: 3) { r in
                SnapshotWire.Piece(added: try r.bool(), start: try r.uint(), length: try r.uint())
            }, newBytes: try r.bytes())
        }
        self.result = result
        try r.expectEnd()
    }
}
