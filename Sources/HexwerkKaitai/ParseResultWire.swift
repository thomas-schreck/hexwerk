import Foundation
import HexwerkCore

/// Binary form of a parse result, sent from the sandboxed helper to the app
/// (#102). Lazy arrays travel as their values, so their elements are still
/// made on demand in the app, exactly as after an in-process parse.
extension ParseResult {
    /// Deeper than any tree the interpreter builds (`ParseLimits.maxDepth`).
    static let maxWireDepth = 2048

    public func encoded() -> Data {
        var w = WireWriter()
        w.int(nodeCount)
        w.optional(error) { w, e in Self.write(e, &w) }
        Self.write(root, &w)
        return w.data
    }

    /// Recurses per tree level: call on a large stack (`onLargeStack`).
    public init(encoded data: Data) throws {
        var r = WireReader(data)
        let count = try r.int()
        let error = try r.optional { r in try Self.readError(&r) }
        let root = try Self.readNode(&r, depth: 0)
        try r.expectEnd()
        self.init(root: root, error: error, nodeCount: count)
    }

    static func write(_ e: KaitaiError, _ w: inout WireWriter) {
        w.string(e.message)
        w.string(e.path)
        w.optional(e.offset) { $0.uint($1) }
    }

    static func readError(_ r: inout WireReader) throws -> KaitaiError {
        KaitaiError(try r.string(), path: try r.string(), offset: try r.optional { try $0.uint() })
    }

    private static func write(_ n: ParseNode, _ w: inout WireWriter) {
        w.int(n.id)
        w.string(n.name)
        w.string(n.typeName)
        w.optional(n.value) { $0.string($1) }
        w.optional(n.range) { $0.range($1) }
        w.optional(n.error) { $0.string($1) }
        w.optional(n.number) { $0.int($1) }
        w.optional(n.lazy) { w, l in
            w.uint(l.base)
            w.uint(l.elementSize)
            w.string(l.typeName)
            w.int(l.firstID)
            // Lazy arrays hold up to millions of numbers of one kind: those
            // go as one packed block instead of a tag per value.
            if let p = l.values.packed {  // as read from the file: no decoding, width bytes per value
                w.u8(4)
                w.u8(UInt8(p.width))
                w.u8(p.kind.rawValue)
                w.bool(p.littleEndian)
                w.uint(UInt64(p.count))
                p.bytes.withUnsafeBytes { w.raw($0) }
                return
            }
            func bits(_ v: KValue) -> UInt64? {
                switch v {
                case .int(let i): UInt64(bitPattern: i)
                case .float(let d): d.bitPattern
                default: nil
                }
            }
            let kind: UInt8 =
                switch l.values.first {
                case .int?: 1
                case .float?: 2
                default: 3
                }
            let packed: [UInt64] =
                kind == 3
                ? []
                : l.values.compactMap { v in
                    switch (kind, v) {
                    case (1, .int), (2, .float): bits(v)
                    default: nil
                    }
                }
            if kind != 3, packed.count == l.values.count {
                w.u8(kind)
                w.uint(UInt64(packed.count))
                packed.withUnsafeBytes { w.raw($0) }  // little endian on arm64 and x86
            } else {
                w.u8(3)
                w.array(Array(l.values)) { w, v in
                    switch v {
                    case .int(let i): w.u8(0); w.int(i)
                    case .float(let d): w.u8(1); w.double(d)
                    case .bool(let b): w.u8(2); w.bool(b)
                    default: w.u8(3); w.string(display(v))  // not made by fastNumberArray
                    }
                }
            }
        }
        w.array(n.children) { w, c in write(c, &w) }
    }

    private static func readNode(_ r: inout WireReader, depth: Int) throws -> ParseNode {
        guard depth < maxWireDepth else { throw WireError("tree too deep") }
        let id = try r.int()
        let name = try r.string()
        let typeName = try r.string()
        let value = try r.optional { try $0.string() }
        let range = try r.optional { try $0.range() }
        let error = try r.optional { try $0.string() }
        let number = try r.optional { try $0.int64() }
        let lazy = try r.optional { r -> LazyArray in
            let base = try r.uint(), size = try r.uint()
            let typeName = try r.string()
            let firstID = try r.int()
            let values: KArray
            switch try r.u8() {
            case 4:
                let width = Int(try r.u8())
                guard let kind = PackedNumbers.Kind(rawValue: try r.u8()), [1, 2, 4, 8].contains(width),
                    kind != .float || width >= 4
                else { throw WireError("bad packed array") }
                let little = try r.bool()
                let n = try r.count(minSize: width)
                let raw = try r.raw(n * width)
                values = KArray(packed: PackedNumbers(bytes: [UInt8](raw), width: width, kind: kind, littleEndian: little))
            case let kind where kind == 1 || kind == 2:
                let n = try r.count(minSize: 8)
                let raw = try r.raw(n * 8)
                values = KArray(
                    raw.withUnsafeBytes { buf in
                        (0 ..< n).map { i in
                            let bits = UInt64(littleEndian: buf.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self))
                            return kind == 1 ? .int(Int64(bitPattern: bits)) : .float(Double(bitPattern: bits))
                        }
                    })
            case 3:
                values = KArray(
                    try r.array(minSize: 2) { r -> KValue in
                        switch try r.u8() {
                        case 0: return .int(try r.int64())
                        case 1: return .float(try r.double())
                        case 2: return .bool(try r.bool())
                        case 3: return .str(try r.string())
                        default: throw WireError("bad value tag")
                        }
                    })
            default: throw WireError("bad lazy array")
            }
            // Element ranges are base + i * size: reject what would overflow.
            let (span, o1) = size.multipliedReportingOverflow(by: UInt64(values.count))
            let (_, o2) = base.addingReportingOverflow(span)
            let (_, o3) = firstID.addingReportingOverflow(values.count)
            guard !o1, !o2, !o3 else { throw WireError("lazy array out of range") }
            return LazyArray(values: values, base: base, elementSize: size, typeName: typeName, firstID: firstID)
        }
        let children = try r.array { r in try readNode(&r, depth: depth + 1) }
        return ParseNode(
            id: id, name: name, typeName: typeName, value: value, range: range,
            children: children, error: error, number: number, lazy: lazy)
    }
}
