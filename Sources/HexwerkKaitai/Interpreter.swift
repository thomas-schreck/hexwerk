import Foundation
import Synchronization
import HexwerkCore

// MARK: - Public result

/// One node of the parse tree as shown in the app or printed by the CLI.
public struct ParseNode: Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let typeName: String
    public let value: String?
    /// Absolute file range; nil for values computed or read from processed data.
    public let range: Range<UInt64>?
    public let children: [ParseNode]
    public let error: String?
    /// Raw number for JSON output (ints and enums), if any.
    public let number: Int64?
    /// Large arrays of plain numbers: elements are made on demand (FR-6.13).
    public var lazy: LazyArray? = nil

    public init(id: Int, name: String, typeName: String, value: String?, range: Range<UInt64>?,
                children: [ParseNode], error: String?, number: Int64?, lazy: LazyArray? = nil) {
        self.id = id; self.name = name; self.typeName = typeName; self.value = value; self.range = range
        self.children = children; self.error = error; self.number = number; self.lazy = lazy
    }

    public var childCount: Int { lazy?.count ?? children.count }
    public func child(_ i: Int) -> ParseNode { lazy?.child(i) ?? children[i] }
    /// All children, made if lazy (CLI output).
    public var allChildren: [ParseNode] { lazy.map { l in (0 ..< l.count).map(l.child) } ?? children }
}

/// Elements of a big array of integers/floats, kept as values only; a
/// ParseNode per element is created when the tree shows it.
public final class LazyArray: @unchecked Sendable {
    // Immutable after creation.
    let values: [KValue]
    public let base: UInt64            // file offset of element 0
    public let elementSize: UInt64
    public let typeName: String
    let firstID: Int

    init(values: [KValue], base: UInt64, elementSize: UInt64, typeName: String, firstID: Int) {
        self.values = values
        self.base = base
        self.elementSize = elementSize
        self.typeName = typeName
        self.firstID = firstID
    }

    public var count: Int { values.count }

    /// Index of the element containing `offset`, if any.
    public func index(of offset: UInt64) -> Int? {
        guard offset >= base, elementSize > 0 else { return nil }
        let i = Int((offset - base) / elementSize)
        return i < values.count ? i : nil
    }

    public func child(_ i: Int) -> ParseNode {
        let v = values[i]
        var n: Int64? = nil
        if case .int(let x) = v { n = x }
        let s = base + UInt64(i) * elementSize
        return ParseNode(id: firstID + i, name: "[\(i)]", typeName: typeName, value: display(v),
                         range: s ..< s + elementSize, children: [], error: nil, number: n)
    }
}

public struct ParseResult: Sendable {
    public let root: ParseNode
    /// First error that stopped parsing (the tree up to there is kept).
    public let error: KaitaiError?
    public let nodeCount: Int
    /// Elements of lazy arrays (FR-6.13). Not in `nodeCount`: they only
    /// become nodes when shown, so the node count alone looks tiny.
    public let lazyElementCount: Int

    init(root: ParseNode, error: KaitaiError?, nodeCount: Int) {
        self.root = root
        self.error = error
        self.nodeCount = nodeCount
        lazyElementCount = Self.lazyElements(in: root)
    }

    // Recursion is bounded by ParseLimits.maxDepth.
    private static func lazyElements(in n: ParseNode) -> Int {
        n.children.reduce(n.lazy?.count ?? 0) { $0 + lazyElements(in: $1) }
    }
}

public struct ParseLimits: Sendable {
    public var maxDepth = 256
    public var maxNodes = 1_000_000
    public var maxSeconds = 30.0
    public init() {}
}

// MARK: - Runtime values

final class KEnum {
    let name: String
    let values: [Int64: String]
    init(name: String, values: [Int64: String]) { self.name = name; self.values = values }
}

enum KValue {
    case int(Int64)
    case float(Double)
    case bool(Bool)
    case str(String)
    case bytes([UInt8])
    case array([KValue])
    case obj(KObj)
    case io(KStream)
    case enumv(KEnum, Int64)
}

struct FieldInfo {
    let stream: KStream
    let start: UInt64
    let end: UInt64
    var elements: [(UInt64, UInt64)] = []
    let typeName: String
    /// Set by the fast path for plain number arrays: element i is at
    /// start + i * elementSize (no per-element list).
    var elementSize: UInt64? = nil
}

final class KObj {
    let type: KsyType
    let io: KStream
    weak var parent: KObj?
    unowned(unsafe) var root: KObj! = nil
    var endian: Endian?
    var bitEndian: Endian = .big
    var params: [String: KValue] = [:]
    var fields: [String: KValue] = [:]
    var info: [String: FieldInfo] = [:]
    var instanceValues: [String: KValue] = [:]
    var instanceErrors: [String: KaitaiError] = [:]
    var evaluating: Set<String> = []
    var start: UInt64 = 0
    var end: UInt64 = 0
    var failed: KaitaiError?
    /// Nesting depth at which this object was parsed; instances continue from
    /// here so self-referencing instances still hit the depth limit.
    var depth = 0

    init(type: KsyType, io: KStream, parent: KObj?) {
        self.type = type
        self.io = io
        self.parent = parent
    }
}

struct Ctx {
    let obj: KObj
    var locals: [String: KValue] = [:]
}

/// Thrown to unwind parents after a child object recorded its own error.
/// @unchecked: never crosses threads, it only unwinds one synchronous parse.
private struct ChildFailed: Error, @unchecked Sendable {
    let error: KaitaiError
    var partial: KValue? = nil
}

// MARK: - Interpreter

public final class KaitaiInterpreter {
    private let file: KsyFile
    private let limits: ParseLimits
    private let shouldContinue: () -> Bool
    private var nodes = 0
    private var nextStreamID = 1
    private var deadline = Date()
    private var allObjects: [KObj] = []      // keeps weakly linked objects alive

    private init(file: KsyFile, limits: ParseLimits, shouldContinue: @escaping () -> Bool) {
        self.file = file
        self.limits = limits
        self.shouldContinue = shouldContinue
    }

    /// Parses `snapshot` with the root type of `file`. Never throws: errors
    /// end up in the result, together with everything parsed before them.
    public static func parse(_ snapshot: Snapshot, file: KsyFile, limits: ParseLimits = ParseLimits(),
                             shouldContinue: @escaping () -> Bool = { true }) -> ParseResult {
        // The interpreter recurses per nesting level. Background threads and
        // Swift tasks have 512 KiB stacks, which a deeply nested (or hostile)
        // .ksy overflows long before the depth limit. So always run on an own
        // thread with a large stack and wait for it.
        final class Box: @unchecked Sendable {
            var result: ParseResult?
            let work: () -> ParseResult
            init(_ work: @escaping () -> ParseResult) { self.work = work }
        }
        let box = Box { run(snapshot, file: file, limits: limits, shouldContinue: shouldContinue) }
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.result = box.work()
            done.signal()
        }
        thread.stackSize = 64 << 20
        thread.start()
        done.wait()
        return box.result!
    }

    /// Async variant for Swift concurrency callers: suspends instead of
    /// blocking a pool thread, and cancelling the calling task stops the
    /// parse (it ends with a "Cancelled" error). A `shouldContinue` closure
    /// cannot do that: it runs on the parser's own thread, outside any task,
    /// where `Task.isCancelled` is always false.
    public static func parse(_ snapshot: Snapshot, file: KsyFile,
                             limits: ParseLimits = ParseLimits()) async -> ParseResult {
        final class Job: @unchecked Sendable {      // file is only used on the parser thread
            let snapshot: Snapshot
            let file: KsyFile
            let cancelled = Atomic(false)
            init(_ snapshot: Snapshot, _ file: KsyFile) { self.snapshot = snapshot; self.file = file }
        }
        let job = Job(snapshot, file)
        return await withTaskCancellationHandler {
            await onLargeStackAsync {
                run(job.snapshot, file: job.file, limits: limits,
                    shouldContinue: { !job.cancelled.load(ordering: .relaxed) })
            }
        } onCancel: {
            job.cancelled.store(true, ordering: .relaxed)
        }
    }

    private static func run(_ snapshot: Snapshot, file: KsyFile, limits: ParseLimits,
                            shouldContinue: @escaping () -> Bool) -> ParseResult {
        let interp = KaitaiInterpreter(file: file, limits: limits, shouldContinue: shouldContinue)
        interp.deadline = Date().addingTimeInterval(limits.maxSeconds)
        let io = KStream(snapshot: snapshot, id: 0)
        let root = interp.parseObject(file.root, io: io, parent: nil, root: nil, args: [], depth: 0)
        // Instances are lazy in Kaitai; for the tree we evaluate all of them.
        interp.forceInstances(root, depth: 0)
        var idCounter = 0
        let tree = interp.node(name: file.id, value: .obj(root), info: nil, typeName: file.id, id: &idCounter)
        return ParseResult(root: tree, error: root.failed, nodeCount: interp.nodes)
    }

    // MARK: Objects

    private func parseObject(_ type: KsyType, io: KStream, parent: KObj?, root: KObj?,
                             args: [KValue], depth: Int) -> KObj {
        let obj = KObj(type: type, io: io, parent: parent)
        obj.depth = depth
        allObjects.append(obj)
        obj.root = root ?? obj
        obj.start = io.pos
        do {
            guard depth <= limits.maxDepth else { throw KaitaiError(L("Nesting deeper than %@", "\(limits.maxDepth)")) }
            for (name, value) in zip(type.params, args) { obj.params[name] = value }
            obj.bitEndian = type.bitEndian ?? parent?.bitEndian ?? .big
            obj.endian = try resolveEndian(type, obj) ?? parent?.endian
            for attr in type.seq {
                do {
                    try parseSeqAttr(attr, obj, depth: depth)
                } catch let e as ChildFailed {
                    throw KaitaiError(e.error.message, path: join(attr.id, e.error.path), offset: e.error.offset)
                } catch var e as KaitaiError {
                    e.path = join(attr.id, e.path)
                    if e.offset == nil { e.offset = io.fileBase.map { $0 + io.pos } }
                    throw e
                }
            }
        } catch let e as KaitaiError {
            obj.failed = e
        } catch {
            obj.failed = KaitaiError(String(describing: error))
        }
        obj.end = io.pos
        return obj
    }

    private func join(_ a: String, _ b: String) -> String { b.isEmpty ? a : b.hasPrefix("[") ? a + b : a + "." + b }

    private func resolveEndian(_ type: KsyType, _ obj: KObj) throws -> Endian? {
        switch type.endian {
        case nil: return nil
        case .fixed(let e): return e
        case .switchOn(let on, let cases):
            let v = try eval(on, Ctx(obj: obj))
            for (k, e) in cases where try equal(v, eval(k, Ctx(obj: obj))) { return e }
            throw KaitaiError(L("Cannot determine endianness"))
        }
    }

    private func tick() throws {
        nodes += 1
        if nodes > limits.maxNodes { throw KaitaiError(L("More than %@ nodes, aborted", "\(limits.maxNodes)")) }
        if nodes % 1024 == 0 { try checkTime() }
    }

    /// Deadline and cancel, for long loops that create no nodes.
    private func checkTime() throws {
        if Date() > deadline { throw KaitaiError(L("Time limit of %ld s exceeded", Int(limits.maxSeconds))) }
        if !shouldContinue() { throw KaitaiError(L("Cancelled")) }
    }

    // MARK: Attributes

    private func parseSeqAttr(_ attr: AttrSpec, _ obj: KObj, depth: Int) throws {
        if let c = attr.cond, try !bool(eval(c, Ctx(obj: obj))) { return }
        guard let (value, info) = try parseAttrValue(attr, obj, io: obj.io, depth: depth, onPartial: { partial, info in
            obj.fields[attr.id] = partial
            obj.info[attr.id] = info
        }) else { return }
        obj.fields[attr.id] = value
        obj.info[attr.id] = info
    }

    /// Reads one attribute (with repetition) from `io`. `onPartial` stores
    /// what was read before an error, so the tree shows it.
    private func parseAttrValue(_ attr: AttrSpec, _ obj: KObj, io: KStream, depth: Int,
                                onPartial: (KValue, FieldInfo) -> Void) throws -> (KValue, FieldInfo)? {
        let start = io.pos
        let typeName = describe(attr.type)
        guard let rep = attr.repeatSpec else {
            do {
                guard let v = try parseSingle(attr, obj, io: io, index: nil, depth: depth) else { return nil }
                try checkValid(attr, v, obj)
                return (v, fieldInfo(io, start, typeName))
            } catch let e as ChildFailed {
                if let v = e.partial { onPartial(v, FieldInfo(stream: io, start: start, end: io.pos, typeName: typeName)) }
                throw e
            }
        }
        if let fast = try fastNumberArray(attr, rep, obj, io: io, start: start, typeName: typeName) { return fast }
        var items: [KValue] = []
        var elements: [(UInt64, UInt64)] = []
        func current() -> FieldInfo {
            var i = FieldInfo(stream: io, start: start, end: io.pos, typeName: typeName + "[]")
            i.elements = elements
            return i
        }
        func one() throws -> KValue {
            let s = io.pos
            do {
                let v = try parseSingle(attr, obj, io: io, index: items.count, depth: depth) ?? .bytes([])
                try checkValid(attr, v, obj)
                items.append(v)
                elements.append((s, io.pos))
                return v
            } catch let e as ChildFailed {
                if let v = e.partial { items.append(v); elements.append((s, io.pos)) }
                onPartial(.array(items), current())
                throw ChildFailed(error: KaitaiError(e.error.message, path: join("[\(items.count - 1)]", e.error.path), offset: e.error.offset))
            } catch var e as KaitaiError {
                onPartial(.array(items), current())
                e.path = join("[\(items.count)]", e.path)
                throw e
            }
        }
        switch rep {
        case .eos:
            while !io.isEof { _ = try one() }
        case .expr(let n):
            let count = try int(eval(n, Ctx(obj: obj)))
            guard count >= 0 else { throw KaitaiError(L("repeat-expr negative: %@", "\(count)")) }
            for _ in 0..<count { _ = try one() }
        case .until(let cond):
            while true {
                let v = try one()
                var ctx = Ctx(obj: obj)
                ctx.locals["_"] = v
                ctx.locals["_index"] = .int(Int64(items.count - 1))
                if try bool(eval(cond, ctx)) { break }
            }
        }
        return (.array(items), current())
    }

    /// Arrays of plain integers/floats are read in one loop without a node
    /// or checks per element (FR-6.13): 10⁶ entries take milliseconds.
    /// Anything special (enum, valid, process, switch, …) takes the normal path.
    private func fastNumberArray(_ attr: AttrSpec, _ rep: RepeatSpec, _ obj: KObj, io: KStream,
                                 start: UInt64, typeName tn: String) throws -> (KValue, FieldInfo)? {
        guard case .named(_, let args)? = attr.type, args.isEmpty, attr.contents == nil, attr.size == nil,
              !attr.sizeEos, attr.process == nil, attr.enumName == nil, attr.valid == nil, attr.terminator == nil,
              let bits = Self.primitiveBits(tn), !tn.hasPrefix("b"), bits % 8 == 0 else { return nil }
        let size = UInt64(bits / 8)
        let count: Int64
        switch rep {
        case .expr(let n):
            count = try int(eval(n, Ctx(obj: obj)))
            guard count >= 0 else { throw KaitaiError(L("repeat-expr negative: %@", "\(count)")) }
        case .eos:
            let rest = io.size - io.pos
            guard rest % size == 0 else { return nil }      // partial last element: let the normal path report it
            count = Int64(rest / size)
        case .until:
            return nil
        }
        // Small arrays keep the normal per-element tree; also check the space first.
        // Division instead of count * size, which overflows for hostile counts.
        guard count >= 1024, size > 0, UInt64(count) <= (io.size - io.pos) / size else { return nil }
        try tick()
        var items: [KValue] = []
        items.reserveCapacity(Int(count))
        for i in 0 ..< Int(count) {
            guard let v = try readPrimitive(tn, io, obj) else { return nil }
            items.append(v)
            if i % 65536 == 0, Date() > deadline { throw KaitaiError(L("Time limit of %ld s exceeded", Int(limits.maxSeconds))) }
        }
        var info = FieldInfo(stream: io, start: start, end: io.pos, typeName: tn + "[]")
        info.elementSize = size
        return (.array(items), info)
    }

    /// Range of a just-read value. Bit fields after the first one in a byte
    /// do not move the byte position; they get the byte they came from.
    private func fieldInfo(_ io: KStream, _ start: UInt64, _ typeName: String) -> FieldInfo {
        if io.pos == start, start > 0, typeName.hasPrefix("b"), Self.primitiveBits(typeName) != nil {
            return FieldInfo(stream: io, start: start - 1, end: start, typeName: typeName)
        }
        return FieldInfo(stream: io, start: start, end: io.pos, typeName: typeName)
    }

    private func describe(_ t: TypeRef?) -> String {
        switch t {
        case nil: "bytes"
        case .named(let n, _): n
        case .switchOn: "switch"
        }
    }

    private func parseSingle(_ attr: AttrSpec, _ obj: KObj, io: KStream, index: Int?, depth: Int) throws -> KValue? {
        try tick()
        var ctx = Ctx(obj: obj)
        if let index { ctx.locals["_index"] = .int(Int64(index)) }

        if let expected = attr.contents {
            let got = try io.readBytes(UInt64(expected.count))
            guard got == expected else {
                throw KaitaiError(L("contents: expected %@, found %@", hexString(expected), hexString(got)), offset: io.fileBase.map { $0 + io.pos - UInt64(got.count) })
            }
            return .bytes(got)
        }

        // Which type? Switches pick one by value.
        var typeName: String? = nil
        var args: [Expr] = []
        switch attr.type {
        case nil: break
        case .named(let n, let a): typeName = n; args = a
        case .switchOn(let on, let cases):
            let v = try eval(on, ctx)
            var chosen: TypeRef? = nil
            for c in cases where c.key != nil {
                if try equal(v, eval(c.key!, ctx)) { chosen = c.type; break }
            }
            if chosen == nil { chosen = cases.first { $0.key == nil }?.type }
            if case .named(let n, let a)? = chosen { typeName = n; args = a }
            // No matching case and no size: Kaitai reads nothing at all.
            if chosen == nil && attr.size == nil && !attr.sizeEos && attr.terminator == nil { return nil }
        }

        guard let tn = typeName else {
            return .bytes(try process(attr, try readRaw(attr, io, ctx, strz: false), ctx))
        }
        if tn == "str" || tn == "strz" {
            let b = try process(attr, try readRaw(attr, io, ctx, strz: tn == "strz"), ctx)
            return .str(decode(b, encoding: attr.encoding ?? inheritedEncoding(obj.type)))
        }
        if let prim = try readPrimitive(tn, io, obj) {
            if let en = attr.enumName, case .int(let n) = prim { return .enumv(try resolveEnum(en, from: obj.type), n) }
            return prim
        }

        // User type.
        guard let type = resolveType(tn, from: obj.type) else { throw KaitaiError(L("Unknown type %@", "\(tn)")) }
        let argValues = try args.map { try eval($0, ctx) }
        let sub: KStream
        if attr.size != nil || attr.sizeEos || attr.terminator != nil {
            if attr.process != nil {
                let raw = try readRaw(attr, io, ctx, strz: false)
                sub = KStream(data: try process(attr, raw, ctx), id: newStreamID())
            } else if let s = attr.size {
                sub = try io.substream(UInt64(try nonNegative(int(eval(s, ctx)))), id: newStreamID())
            } else if attr.sizeEos {
                sub = try io.substreamToEnd(id: newStreamID())
            } else {
                sub = KStream(data: try readRaw(attr, io, ctx, strz: false), id: newStreamID())
            }
        } else {
            sub = io
        }
        // A top-level type (e.g. from an imported .ksy) is its own _root.
        let childRoot: KObj? = type.parent == nil ? nil : obj.root
        let child = parseObject(type, io: sub, parent: obj, root: childRoot, args: argValues, depth: depth + 1)
        if let e = child.failed { throw ChildFailed(error: e, partial: .obj(child)) }
        return .obj(child)
    }

    private func newStreamID() -> Int {
        nextStreamID += 1
        return nextStreamID
    }

    private func nonNegative(_ n: Int64) throws -> Int64 {
        guard n >= 0 else { throw KaitaiError(L("Negative size %@", "\(n)")) }
        return n
    }

    /// Bytes for size / size-eos / terminator attributes, with pad-right.
    private func readRaw(_ attr: AttrSpec, _ io: KStream, _ ctx: Ctx, strz: Bool) throws -> [UInt8] {
        var b: [UInt8]
        let term: UInt8? = attr.terminator ?? (strz ? 0 : nil)
        if let s = attr.size {
            b = try io.readBytes(UInt64(try nonNegative(int(eval(s, ctx)))))
        } else if attr.sizeEos {
            b = try io.readBytesFull()
        } else if let term {
            return try io.readBytesTerm(term, include: attr.include, consume: attr.consume, eosError: attr.eosError,
                                        check: checkTime)
        } else {
            throw KaitaiError(L("Neither size nor size-eos nor terminator given"))
        }
        if let pad = attr.padRight {
            while b.last == pad { b.removeLast() }
        }
        // With a size, the terminator cuts inside the read bytes.
        if let term, let i = b.firstIndex(of: term) {
            b = Array(b[..<(attr.include ? i + 1 : i)])
        }
        return b
    }

    private func process(_ attr: AttrSpec, _ b: [UInt8], _ ctx: Ctx) throws -> [UInt8] {
        switch attr.process {
        case nil: return b
        case .zlib: return try Process.zlibInflate(b)
        case .xor(let k):
            switch try eval(k, ctx) {
            case .int(let n): return Process.xor(b, key: [UInt8(truncatingIfNeeded: n)])
            case .bytes(let key): return Process.xor(b, key: key)
            case .array(let a): return Process.xor(b, key: try a.map { UInt8(truncatingIfNeeded: try int($0)) })
            default: throw KaitaiError(L("Cannot parse xor key"))
            }
        case .rol(let n): return Process.rotate(b, left: Int(try int(eval(n, ctx))))
        case .ror(let n): return Process.rotate(b, left: -Int(try int(eval(n, ctx)) % 8))   // % 8 first: -Int64.min traps
        }
    }

    private func readPrimitive(_ tn: String, _ io: KStream, _ obj: KObj) throws -> KValue? {
        var name = tn
        var endian: Endian? = nil
        if name.hasSuffix("le") && name.count > 2 { endian = .little; name.removeLast(2) }
        else if name.hasSuffix("be") && name.count > 2 { endian = .big; name.removeLast(2) }
        guard let kind = name.first, let n = Int(name.dropFirst()) else { return nil }
        switch kind {
        case "u", "s":
            guard [1, 2, 4, 8].contains(n) else { return nil }
            let e = endian ?? obj.endian ?? (n == 1 ? .little : nil)
            guard let e else { throw KaitaiError(L("Endianness for %@ not specified", "\(tn)")) }
            let raw = try io.readUInt(n, e)
            if kind == "u" { return .int(Int64(bitPattern: raw)) }
            let shift = UInt64(64 - n * 8)
            return .int(Int64(bitPattern: raw << shift) >> Int64(shift))
        case "f":
            guard n == 4 || n == 8 else { return nil }
            guard let e = endian ?? obj.endian else { throw KaitaiError(L("Endianness for %@ not specified", "\(tn)")) }
            let raw = try io.readUInt(n, e)
            return .float(n == 4 ? Double(Float(bitPattern: UInt32(raw))) : Double(bitPattern: raw))
        case "b":
            guard (1...64).contains(n) else { return nil }
            let be = (endian ?? obj.bitEndian) == .big
            let v = be ? try io.readBitsBE(n) : try io.readBitsLE(n)
            return n == 1 ? .bool(v == 1) : .int(Int64(bitPattern: v))
        default:
            return nil
        }
    }

    private func checkValid(_ attr: AttrSpec, _ v: KValue, _ obj: KObj) throws {
        guard let spec = attr.valid else { return }
        var ctx = Ctx(obj: obj)
        ctx.locals["_"] = v
        ctx.locals[attr.id] = v     // the expression may name the field itself
        let ok: Bool
        var expected = ""
        switch spec {
        case .eq(let e):
            let want = try eval(e, ctx)
            ok = try equal(v, want)
            expected = display(want)
        case .range(let lo, let hi):
            let l = try lo.map { try eval($0, ctx) }, h = try hi.map { try eval($0, ctx) }
            ok = try (l == nil || compare(v, l!) >= 0) && (h == nil || compare(v, h!) <= 0)
            expected = L("%@ to %@", l.map(display) ?? "…", h.map(display) ?? "…")
        case .anyOf(let list):
            let vals = try list.map { try eval($0, ctx) }
            ok = try vals.contains { try equal(v, $0) }
            expected = L("one of %@", vals.map(display).joined(separator: ", "))
        case .expr(let e):
            ok = try bool(eval(e, ctx))
            expected = L("condition met")
        }
        guard ok else { throw KaitaiError(L("Validation: expected %@, found %@", expected, display(v))) }
    }

    // MARK: Instances

    private func instance(_ name: String, of obj: KObj) throws -> KValue? {
        if let v = obj.instanceValues[name] { return v }
        if let e = obj.instanceErrors[name] { throw e }
        guard let spec = obj.type.instances.first(where: { $0.id == name }) else { return nil }
        guard !obj.evaluating.contains(name) else { throw KaitaiError(L("Instance %@ depends on itself", "\(name)")) }
        obj.evaluating.insert(name)
        defer { obj.evaluating.remove(name) }
        do {
            let ctx = Ctx(obj: obj)
            if let c = spec.cond, try !bool(eval(c, ctx)) { return nil }
            let v: KValue
            if let value = spec.value {
                let raw = try eval(value, ctx)
                if let en = spec.enumName, case .int(let n) = raw { v = .enumv(try resolveEnum(en, from: obj.type), n) } else { v = raw }
            } else {
                var io = obj.io
                if let ioExpr = spec.io {
                    guard case .io(let s) = try eval(ioExpr, ctx) else { throw KaitaiError(L("io is not a stream")) }
                    io = s
                }
                let saved = io.pos
                defer { try? io.seek(saved) }
                if let p = spec.pos { try io.seek(UInt64(try nonNegative(int(eval(p, ctx))))) }
                guard let (val, info) = try parseAttrValue(spec, obj, io: io, depth: obj.depth, onPartial: { partial, info in
                    obj.instanceValues[name] = partial
                    obj.info[name] = info
                }) else { return nil }
                obj.info[name] = info
                v = val
            }
            obj.instanceValues[name] = v
            return v
        } catch let e as ChildFailed {
            obj.instanceErrors[name] = e.error
            throw e.error
        } catch let e as KaitaiError {
            obj.instanceErrors[name] = e
            throw e
        }
    }

    private func forceInstances(_ obj: KObj, depth: Int) {
        guard depth < limits.maxDepth else { return }
        for spec in obj.type.instances { _ = try? instance(spec.id, of: obj) }
        let values = obj.type.seq.compactMap { obj.fields[$0.id] } + obj.type.instances.compactMap { obj.instanceValues[$0.id] }
        for v in values { forceChildren(v, depth: depth) }
    }

    private func forceChildren(_ v: KValue, depth: Int) {
        switch v {
        case .obj(let o): forceInstances(o, depth: depth + 1)
        case .array(let items): for i in items { forceChildren(i, depth: depth) }
        default: break
        }
    }

    // MARK: Lookup

    private func rootType(_ t: KsyType) -> KsyType {
        var r = t
        while let p = r.parent { r = p }
        return r
    }

    func resolveType(_ name: String, from t: KsyType) -> KsyType? {
        let parts = name.components(separatedBy: "::")
        func descend(_ start: KsyType, _ rest: ArraySlice<String>) -> KsyType? {
            var cur = start
            for p in rest { guard let n = cur.types[p] else { return nil }; cur = n }
            return cur
        }
        var scope: KsyType? = t
        while let s = scope {
            if let hit = s.types[parts[0]] { return descend(hit, parts.dropFirst()) }
            scope = s.parent
        }
        let root = rootType(t)
        if root.name == parts[0] { return descend(root, parts.dropFirst()) }
        for f in root.file?.imports ?? [] where f.id == parts[0] { return descend(f.root, parts.dropFirst()) }
        return nil
    }

    func resolveEnum(_ name: String, from t: KsyType) throws -> KEnum {
        var parts = name.components(separatedBy: "::")
        let enumName = parts.removeLast()
        var scope: KsyType? = parts.isEmpty ? t : resolveType(parts.joined(separator: "::"), from: t)
        while let s = scope {
            if let values = s.enums[enumName] { return KEnum(name: enumName, values: values) }
            scope = parts.isEmpty ? s.parent : nil
        }
        throw KaitaiError(L("Unknown enum %@", "\(name)"))
    }

    private func inheritedEncoding(_ t: KsyType) -> String? {
        var s: KsyType? = t
        while let c = s { if let e = c.encoding { return e }; s = c.parent }
        return nil
    }

    // MARK: Expressions

    func eval(_ e: Expr, _ c: Ctx) throws -> KValue {
        switch e {
        case .int(let n): return .int(n)
        case .float(let d): return .float(d)
        case .str(let s): return .str(s)
        case .bool(let b): return .bool(b)
        case .array(let items): return .array(try items.map { try eval($0, c) })
        case .name(let n): return try lookup(n, c)
        case .enumLit(let path, let value):
            let en = try resolveEnum(path.joined(separator: "::"), from: c.obj.type)
            guard let n = en.values.first(where: { $0.value == value })?.key else {
                throw KaitaiError(L("Unknown enum value %@::%@", path.joined(separator: "::"), "\(value)"))
            }
            return .enumv(en, n)
        case .cast(let inner, _): return try eval(inner, c)
        case .sizeofType(let name):
            guard let t = resolveType(name, from: c.obj.type) else { throw KaitaiError(L("sizeof: unknown type %@", "\(name)")) }
            return .int(try staticSize(t, c))
        case .ternary(let cond, let a, let b): return try bool(eval(cond, c)) ? eval(a, c) : eval(b, c)
        case .unary(let op, let x):
            let v = try eval(x, c)
            switch (op, v) {
            case ("-", .int(let n)): return .int(0 &- n)
            case ("-", .float(let d)): return .float(-d)
            case ("~", .int(let n)): return .int(~n)
            case ("not", _): return .bool(!(try bool(v)))
            default: throw KaitaiError(L("Operator %@ does not apply to %@", "\(op)", display(v)))
            }
        case .binary(let op, let l, let r):
            if op == "and" { return .bool(try bool(eval(l, c)) && bool(eval(r, c))) }
            if op == "or" { return .bool(try bool(eval(l, c)) || bool(eval(r, c))) }
            return try binary(op, eval(l, c), eval(r, c))
        case .index(let base, let i):
            let v = try eval(base, c), idx = Int(try int(eval(i, c)))
            switch v {
            case .array(let a) where a.indices.contains(idx): return a[idx]
            case .bytes(let b) where b.indices.contains(idx): return .int(Int64(b[idx]))
            default: throw KaitaiError(L("Index %@ out of range", "\(idx)"))
            }
        case .member(let base, let name):
            // _sizeof of a plain field: its byte count.
            if name == "_sizeof", case .name(let f) = base, let info = c.obj.info[f] { return .int(Int64(info.end - info.start)) }
            return try member(eval(base, c), name, [], c)
        case .call(let base, let name, let args):
            return try member(eval(base, c), name, try args.map { try eval($0, c) }, c)
        }
    }

    private func lookup(_ n: String, _ c: Ctx) throws -> KValue {
        if let v = c.locals[n] { return v }
        switch n {
        case "_root": return .obj(c.obj.root)
        case "_parent":
            guard let p = c.obj.parent else { throw KaitaiError(L("_parent missing")) }
            return .obj(p)
        case "_io": return .io(c.obj.io)
        default: return try field(n, of: c.obj)
        }
    }

    private func field(_ n: String, of o: KObj) throws -> KValue {
        if let v = o.fields[n] { return v }
        if let v = o.params[n] { return v }
        if let v = try instance(n, of: o) { return v }
        throw KaitaiError(L("%@ unknown or not read yet", "\(n)"))
    }

    private func member(_ v: KValue, _ name: String, _ args: [KValue], _ c: Ctx) throws -> KValue {
        switch (v, name) {
        case (.obj(let o), "_io"): return .io(o.io)
        case (.obj(let o), "_root"): return .obj(o.root)
        case (.obj(let o), "_parent"):
            guard let p = o.parent else { throw KaitaiError(L("_parent missing")) }
            return .obj(p)
        case (.obj(let o), "_sizeof"): return .int(Int64(o.end - o.start))
        case (.obj(let o), _): return try field(name, of: o)
        case (.io(let s), "size"): return .int(Int64(s.size))
        case (.io(let s), "pos"): return .int(Int64(s.pos))
        case (.io(let s), "eof"): return .bool(s.isEof)
        case (.enumv(_, let n), "to_i"): return .int(n)
        case (.bool(let b), "to_i"): return .int(b ? 1 : 0)
        case (.int(let n), "to_s"): return .str(String(n))
        case (.float(let d), "to_i"): return .int(try Self.toInt(d))
        case (.str(let s), "length"): return .int(Int64(s.count))
        case (.str(let s), "reverse"): return .str(String(s.reversed()))
        case (.str(let s), "to_i"):
            let radix = try args.first.map { try int($0) } ?? 10
            guard (2 ... 36).contains(radix) else { throw KaitaiError(L("to_i: invalid radix %@", "\(radix)")) }
            guard let n = Int64(s, radix: Int(radix)) else { throw KaitaiError(L("\"%@\" is not a number", s)) }
            return .int(n)
        case (.str(let s), "substring"):
            guard args.count == 2 else { throw KaitaiError(L("substring expects 2 arguments")) }
            let chars = Array(s)
            let a = max(0, Int(try int(args[0]))), b = min(chars.count, Int(try int(args[1])))
            return .str(a < b ? String(chars[a..<b]) : "")
        case (.bytes(let b), "to_s"):
            let enc = args.first.flatMap { if case .str(let s) = $0 { s } else { nil } }
            return .str(decode(b, encoding: enc))
        case (.bytes(let b), "length"), (.bytes(let b), "size"): return .int(Int64(b.count))
        case (.array(let a), "size"), (.array(let a), "length"): return .int(Int64(a.count))
        default: break
        }
        // first/last/min/max on arrays and bytes.
        let items: [KValue]? = switch v {
        case .array(let a): a
        case .bytes(let b): b.map { .int(Int64($0)) }
        default: nil
        }
        if let items {
            switch name {
            case "first": if let f = items.first { return f }
            case "last": if let l = items.last { return l }
            case "min": if let m = try items.min(by: { try compare($0, $1) < 0 }) { return m }
            case "max": if let m = try items.max(by: { try compare($0, $1) < 0 }) { return m }
            default: break
            }
            throw KaitaiError(L(".%@ on empty list or unknown", "\(name)"))
        }
        throw KaitaiError(L(".%@ does not apply to %@", "\(name)", display(v)))
    }

    private func binary(_ op: String, _ a: KValue, _ b: KValue) throws -> KValue {
        switch op {
        case "==": return .bool(try equal(a, b))
        case "!=": return .bool(!(try equal(a, b)))
        case "<": return .bool(try compare(a, b) < 0)
        case "<=": return .bool(try compare(a, b) <= 0)
        case ">": return .bool(try compare(a, b) > 0)
        case ">=": return .bool(try compare(a, b) >= 0)
        default: break
        }
        if op == "+", case .str(let x) = a, case .str(let y) = b { return .str(x + y) }
        if case .float = a, let x = number(a), let y = number(b) { return try floatOp(op, x, y) }
        if case .float = b, let x = number(a), let y = number(b) { return try floatOp(op, x, y) }
        let x = try int(a), y = try int(b)
        switch op {
        case "+": return .int(x &+ y)
        case "-": return .int(x &- y)
        case "*": return .int(x &* y)
        case "/":
            guard y != 0 else { throw KaitaiError(L("Division by 0")) }
            // The only quotient that does not fit into Int64.
            guard !(x == .min && y == -1) else { throw KaitaiError(L("Overflow in %@ / %@", "\(x)", "\(y)")) }
            // Kaitai divides like Python: rounding towards minus infinity.
            let q = x / y
            return .int((x % y != 0) && ((x < 0) != (y < 0)) ? q - 1 : q)
        case "%":
            guard y != 0 else { throw KaitaiError(L("Division by 0")) }
            if y == -1 { return .int(0) }       // Int64.min % -1 traps in Swift
            let m = x % y
            return .int(m != 0 && (m < 0) != (y < 0) ? m + y : m)
        case "<<", ">>":
            guard y >= 0 else { throw KaitaiError(L("Negative shift %@", "\(y)")) }
            if y >= 64 { return .int(0) }
            return .int(op == "<<" ? x << y : Int64(bitPattern: UInt64(bitPattern: x) >> UInt64(y)))
        case "&": return .int(x & y)
        case "|": return .int(x | y)
        case "^": return .int(x ^ y)
        default: throw KaitaiError(L("Unknown operator %@", "\(op)"))
        }
    }

    private func floatOp(_ op: String, _ x: Double, _ y: Double) throws -> KValue {
        switch op {
        case "+": return .float(x + y)
        case "-": return .float(x - y)
        case "*": return .float(x * y)
        case "/": return .float(x / y)
        default: throw KaitaiError(L("Operator %@ not supported for floating point", "\(op)"))
        }
    }

    private func number(_ v: KValue) -> Double? {
        switch v {
        case .int(let n): Double(n)
        case .float(let d): d
        case .enumv(_, let n): Double(n)
        default: nil
        }
    }

    func int(_ v: KValue) throws -> Int64 {
        switch v {
        case .int(let n): return n
        case .enumv(_, let n): return n
        case .bool(let b): return b ? 1 : 0
        case .float(let d): return try Self.toInt(d)
        default: throw KaitaiError(L("Number expected, found %@", display(v)))
        }
    }

    /// Float → Int64 like Kaitai's truncation, but an error instead of a
    /// trap for NaN, infinity and values outside Int64.
    static func toInt(_ d: Double) throws -> Int64 {
        guard let n = Int64(exactly: d.rounded(.towardZero)) else {
            throw KaitaiError(L("%@ does not fit in an integer", "\(d)"))
        }
        return n
    }

    func bool(_ v: KValue) throws -> Bool {
        switch v {
        case .bool(let b): return b
        case .int(let n): return n != 0
        default: throw KaitaiError(L("Boolean expected, found %@", display(v)))
        }
    }

    private func asBytes(_ v: KValue) -> [UInt8]? {
        switch v {
        case .bytes(let b): return b
        case .array(let a):
            var out: [UInt8] = []
            for x in a { guard case .int(let n) = x, (0...255).contains(n) else { return nil }; out.append(UInt8(n)) }
            return out
        default: return nil
        }
    }

    func equal(_ a: KValue, _ b: KValue) throws -> Bool {
        switch (a, b) {
        case (.str(let x), .str(let y)): return x == y
        case (.bool(let x), .bool(let y)): return x == y
        case (.bytes, _), (_, .bytes):
            guard let x = asBytes(a), let y = asBytes(b) else { return false }
            return x == y
        default:
            if let x = number(a), let y = number(b) { return x == y }
            if case .obj(let x) = a, case .obj(let y) = b { return x === y }
            return false
        }
    }

    private func compare(_ a: KValue, _ b: KValue) throws -> Int {
        if case .str(let x) = a, case .str(let y) = b { return x < y ? -1 : x == y ? 0 : 1 }
        if let x = asBytes(a), let y = asBytes(b), case .bytes = a {
            return x.lexicographicallyPrecedes(y) ? -1 : x == y ? 0 : 1
        }
        if case .int(let x) = a, case .int(let y) = b { return x < y ? -1 : x == y ? 0 : 1 }
        guard let x = number(a), let y = number(b) else { throw KaitaiError(L("Not comparable: %@ and %@", display(a), display(b))) }
        return x < y ? -1 : x == y ? 0 : 1
    }

    /// Size of a type with fixed layout (sizeof<T>).
    private func staticSize(_ t: KsyType, _ c: Ctx, depth: Int = 0) throws -> Int64 {
        // A type that contains itself has no fixed size; stop before the stack does.
        guard depth < limits.maxDepth else { throw KaitaiError(L("sizeof: %@ is recursive", t.name)) }
        var bits: Int64 = 0
        for a in t.seq {
            guard a.cond == nil else { throw KaitaiError(L("sizeof: %@ has conditional fields", t.name)) }
            var one: Int64
            if let contents = a.contents { one = Int64(contents.count) * 8 }
            else if let s = a.size, case .int(let n) = s { one = try checked(n.multipliedReportingOverflow(by: 8)) }
            else if case .named(let tn, _)? = a.type {
                if let prim = Self.primitiveBits(tn) { one = prim }
                else if let sub = resolveType(tn, from: t) { one = try checked(staticSize(sub, c, depth: depth + 1).multipliedReportingOverflow(by: 8)) }
                else { throw KaitaiError(L("sizeof: unknown type %@", "\(tn)")) }
            } else { throw KaitaiError(L("sizeof: %@.%@ has no fixed size", t.name, a.id)) }
            switch a.repeatSpec {
            case nil: break
            case .expr(.int(let n)): one = try checked(one.multipliedReportingOverflow(by: n))
            default: throw KaitaiError(L("sizeof: %@.%@ repeats a variable number of times", t.name, a.id))
            }
            bits = try checked(bits.addingReportingOverflow(one))
        }
        return bits / 8 + (bits % 8 == 0 ? 0 : 1)
    }

    private func checked(_ r: (partialValue: Int64, overflow: Bool)) throws -> Int64 {
        guard !r.overflow else { throw KaitaiError(L("sizeof: size does not fit in an integer")) }
        return r.partialValue
    }

    static func primitiveBits(_ tn: String) -> Int64? {
        var name = tn
        if name.count > 2 && (name.hasSuffix("le") || name.hasSuffix("be")) { name.removeLast(2) }
        guard let k = name.first, let n = Int64(name.dropFirst()) else { return nil }
        switch k {
        case "u", "s", "f": return [1, 2, 4, 8].contains(n) ? n * 8 : nil
        case "b": return n
        default: return nil
        }
    }

    // MARK: Tree for display

    private func node(name: String, value: KValue, info: FieldInfo?, typeName: String, id: inout Int) -> ParseNode {
        id += 1
        let myID = id
        let range: Range<UInt64>? = info.flatMap { i in i.stream.fileBase.map { ($0 + i.start) ..< ($0 + i.end) } }
        switch value {
        case .obj(let o):
            var children: [ParseNode] = []
            for p in o.type.params { if let v = o.params[p] { children.append(node(name: p, value: v, info: nil, typeName: "param", id: &id)) } }
            for a in o.type.seq {
                guard let v = o.fields[a.id] else { continue }
                children.append(node(name: a.id, value: v, info: o.info[a.id], typeName: o.info[a.id]?.typeName ?? "", id: &id))
            }
            for a in o.type.instances {
                if let v = o.instanceValues[a.id] {
                    children.append(node(name: a.id, value: v, info: a.value == nil ? o.info[a.id] : nil,
                                         typeName: a.value == nil ? (o.info[a.id]?.typeName ?? "") : L("value"), id: &id))
                } else if let e = o.instanceErrors[a.id] {
                    id += 1
                    children.append(ParseNode(id: id, name: a.id, typeName: "", value: nil, range: nil, children: [], error: e.description, number: nil))
                }
            }
            let objRange = o.io.fileBase.map { ($0 + o.start) ..< ($0 + o.end) }
            return ParseNode(id: myID, name: name, typeName: o.type.name, value: nil, range: range ?? objRange,
                             children: children, error: o.failed?.message, number: nil)
        case .array(let items):
            if let info, let size = info.elementSize, let base = info.stream.fileBase {
                // Fast-path array: elements on demand; reserve their ids.
                let lazy = LazyArray(values: items, base: base + info.start, elementSize: size,
                                     typeName: String(info.typeName.dropLast(2)), firstID: id + 1)
                id += items.count
                var n = ParseNode(id: myID, name: name, typeName: typeName, value: L("%ld entries", items.count), range: range,
                                  children: [], error: nil, number: nil)
                n.lazy = lazy
                return n
            }
            var children: [ParseNode] = []
            for (i, v) in items.enumerated() {
                var elInfo: FieldInfo? = nil
                if let info, i < info.elements.count {
                    elInfo = FieldInfo(stream: info.stream, start: info.elements[i].0, end: info.elements[i].1,
                                       typeName: String(info.typeName.dropLast(2)))
                }
                children.append(node(name: "[\(i)]", value: v, info: elInfo, typeName: elInfo?.typeName ?? "", id: &id))
            }
            return ParseNode(id: myID, name: name, typeName: typeName, value: L("%ld entries", items.count), range: range,
                             children: children, error: nil, number: nil)
        default:
            var number: Int64? = nil
            if case .int(let n) = value { number = n }
            if case .enumv(_, let n) = value { number = n }
            return ParseNode(id: myID, name: name, typeName: typeName, value: display(value), range: range,
                             children: [], error: nil, number: number)
        }
    }
}

// MARK: - Helpers

func hexString(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }

func display(_ v: KValue) -> String {
    switch v {
    case .int(let n): return n >= 10 ? "\(n) (0x\(String(n, radix: 16, uppercase: true)))" : "\(n)"
    case .float(let d): return "\(d)"
    case .bool(let b): return b ? "true" : "false"
    case .str(let s): return "\"" + TerminalText.escape(s.count > 200 ? String(s.prefix(200)) + "…" : s) + "\""
    case .bytes(let b): return b.count <= 24 ? hexString(b) : hexString(Array(b.prefix(24))) + " … (" + L("%ld bytes", b.count) + ")"
    case .array(let a): return L("%ld entries", a.count)
    case .obj(let o): return o.type.name
    case .io: return "Stream"
    case .enumv(let e, let n):
        let hexN = "0x" + String(UInt64(bitPattern: n), radix: 16, uppercase: true)
        return e.values[n].map { "\($0) (\(hexN))" } ?? L("%@ (unknown in %@)", hexN, e.name)
    }
}

func decode(_ b: [UInt8], encoding: String?) -> String {
    let name = (encoding ?? "UTF-8").uppercased()
    let enc: String.Encoding
    switch name {
    case "UTF-8", "UTF8": enc = .utf8
    case "ASCII", "US-ASCII": enc = .ascii
    case "UTF-16LE": enc = .utf16LittleEndian
    case "UTF-16BE": enc = .utf16BigEndian
    case "UTF-32LE": enc = .utf32LittleEndian
    case "UTF-32BE": enc = .utf32BigEndian
    case "ISO-8859-1", "LATIN1": enc = .isoLatin1
    default:
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        enc = cf == kCFStringEncodingInvalidId ? .isoLatin1 : String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }
    // Invalid bytes: fall back to Latin-1, which never fails.
    return String(bytes: b, encoding: enc) ?? String(bytes: b, encoding: .isoLatin1) ?? ""
}
