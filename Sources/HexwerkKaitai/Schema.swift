import Foundation
import HexwerkCore
import Yams

/// A Kaitai Struct type: the whole file (`meta`, `seq`, …) or a nested
/// entry under `types`. Classes because types point to their parent scope.
public final class KsyType {
    public let name: String
    weak var parent: KsyType?
    /// The file this type was defined in (for resolving imports).
    weak var file: KsyFile?

    var endian: EndianSpec?
    var bitEndian: Endian?
    var encoding: String?
    var params: [String] = []
    var seq: [AttrSpec] = []
    var instances: [AttrSpec] = []
    var types: [String: KsyType] = [:]
    var enums: [String: [Int64: String]] = [:]

    init(name: String) { self.name = name }
}

enum EndianSpec {
    case fixed(Endian)
    case switchOn(Expr, [(Expr, Endian)])
}

indirect enum TypeRef {
    case named(String, args: [Expr])
    case switchOn(Expr, cases: [(key: Expr?, type: TypeRef)])   // key nil = `_`
}

enum RepeatSpec {
    case eos, expr(Expr), until(Expr)
}

enum ProcessSpec {
    case zlib, xor(Expr), rol(Expr), ror(Expr)
}

enum ValidSpec {
    case eq(Expr), range(min: Expr?, max: Expr?), anyOf([Expr]), expr(Expr)
}

struct AttrSpec {
    var id: String
    var type: TypeRef?
    var size: Expr?
    var sizeEos = false
    var contents: [UInt8]?
    var repeatSpec: RepeatSpec?
    var cond: Expr?
    var encoding: String?
    var terminator: UInt8?
    var consume = true
    var include = false
    var eosError = true
    var padRight: UInt8?
    var process: ProcessSpec?
    var enumName: String?
    var valid: ValidSpec?
    // Instances only.
    var pos: Expr?
    var io: Expr?
    var value: Expr?
}

/// One .ksy file with its imports resolved.
public final class KsyFile {
    public let url: URL
    public let root: KsyType
    public let id: String
    public let title: String?
    public let fileExtensions: [String]
    var imports: [KsyFile] = []

    init(url: URL, root: KsyType, id: String, title: String?, fileExtensions: [String]) {
        self.url = url
        self.root = root
        self.id = id
        self.title = title
        self.fileExtensions = fileExtensions
    }
}

public struct KaitaiError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public var path: String = ""
    public var offset: UInt64?

    public init(_ message: String, path: String = "", offset: UInt64? = nil) {
        self.message = message
        self.path = path
        self.offset = offset
    }

    public var description: String {
        var s = message
        if !path.isEmpty { s = "\(path): \(s)" }
        if let offset { s += " (Offset 0x\(String(offset, radix: 16, uppercase: true)))" }
        return s
    }
}

/// Loads .ksy files and resolves imports: relative to the importing file,
/// or for "/x/y" from the library root(s).
public final class KsyLoader {
    public let libraryRoots: [URL]
    private var cache: [URL: KsyFile] = [:]
    /// Text of the file being built; YAML maps lose their order, the text keeps it.
    private var source = ""

    /// Text of a .ksy file, nil if there is none. The sandboxed helper
    /// cannot read files and asks the app instead (#102).
    public typealias Reader = (URL) throws -> String?
    private let read: Reader
    private var texts: [URL: String] = [:]

    public init(libraryRoots: [URL] = [], read: @escaping Reader = KsyLoader.readFile) {
        self.libraryRoots = libraryRoots
        self.read = read
    }

    public static func readFile(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func load(_ url: URL) throws -> KsyFile {
        let url = url.standardizedFileURL
        if let f = cache[url] { return f }
        let text: String
        do {
            guard let t = try texts[url] ?? read(url) else {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
            }
            text = t
        }
        catch { throw KaitaiError("\(url.lastPathComponent): \(error.localizedDescription)") }
        let node: Node?
        do { node = try Yams.compose(yaml: text) }
        catch { throw KaitaiError(L("%@: YAML error: %@", url.lastPathComponent, "\(error)")) }
        // Composing shares aliased subtrees, converting to Any copies them:
        // nested aliases ("billion laughs") would expand to gigabytes.
        if let node, !Self.expandsWithin(Self.maxYAMLNodes, node) {
            throw KaitaiError(L("%@: YAML has more than %@ nodes after expanding aliases",
                                url.lastPathComponent, "\(Self.maxYAMLNodes)"))
        }
        let any = node?.any
        guard let top = map(any) else { throw KaitaiError(L("%@: not a YAML object", url.lastPathComponent)) }

        let meta = map(top["meta"]) ?? [:]
        guard let id = str(meta["id"]) else { throw KaitaiError(L("%@: meta.id missing", url.lastPathComponent)) }
        let root = KsyType(name: id)
        let exts: [String] = (list(meta["file-extension"]) ?? []).compactMap(str) + [str(meta["file-extension"])].compactMap { $0 }
        let file = KsyFile(url: url, root: root, id: id, title: str(meta["title"]), fileExtensions: exts)
        cache[url] = file   // before imports: tolerate cycles
        source = text
        try fill(root, from: top, file: file)

        for imp in (list(meta["imports"]) ?? []).compactMap(str) {
            file.imports.append(try load(resolveImport(imp, from: url)))
        }
        return file
    }

    /// Far above any real format (they have thousands of nodes, not
    /// millions), far below what exhausts memory.
    static let maxYAMLNodes = 1_000_000

    /// Counts nodes as `Node.any` would materialize them, stopping at `budget`.
    static func expandsWithin(_ budget: Int, _ root: Node) -> Bool {
        var count = 0
        var stack = [root]
        while let n = stack.popLast() {
            count += 1
            if count > budget { return false }
            switch n {
            case .scalar, .alias: break
            case .sequence(let seq): stack.append(contentsOf: seq)
            case .mapping(let m):
                for (k, v) in m { stack.append(k); stack.append(v) }
            }
        }
        return true
    }

    func resolveImport(_ name: String, from: URL) throws -> URL {
        var candidates: [URL] = []
        if name.hasPrefix("/") {
            candidates = libraryRoots.map { $0.appendingPathComponent(String(name.dropFirst()) + ".ksy") }
        } else {
            candidates = [from.deletingLastPathComponent().appendingPathComponent(name + ".ksy")]
                + libraryRoots.map { $0.appendingPathComponent(name + ".ksy") }
        }
        // A candidate that exists but cannot be read is taken; load() reports why.
        guard let hit = candidates.first(where: { c in
            let c = c.standardizedFileURL
            if texts[c] != nil { return true }
            do {
                guard let t = try read(c) else { return false }
                texts[c] = t
            } catch {}
            return true
        }) else {
            throw KaitaiError(L("Import %@ not found (from %@)", "\(name)", from.lastPathComponent))
        }
        return hit
    }

    // MARK: Building types

    private func fill(_ t: KsyType, from m: [String: Any], file: KsyFile) throws {
        t.file = file
        let meta = map(m["meta"]) ?? [:]
        if let e = meta["endian"] { t.endian = try endianSpec(e) }
        if let b = str(meta["bit-endian"]) { t.bitEndian = b == "le" ? .little : .big }
        t.encoding = str(meta["encoding"])
        t.params = (list(m["params"]) ?? []).compactMap { str(map($0)?["id"]) }
        t.seq = try (list(m["seq"]) ?? []).enumerated().map { i, a in
            guard let am = map(a) else { throw KaitaiError(L("seq[%ld] in %@ is not an object", i, t.name)) }
            return try attr(am, fallbackID: "_unnamed\(i)")
        }
        if let inst = map(m["instances"]) {
            t.instances = try sortedBySource(Array(inst.keys)).map { key in
                guard let am = map(inst[key]) else { throw KaitaiError(L("Instance %@ is not an object", "\(key)")) }
                var a = try attr(am, fallbackID: key)
                a.id = key
                return a
            }
        }
        if let ty = map(m["types"]) {
            for (name, v) in ty {
                guard let tm = map(v) else { continue }
                let sub = KsyType(name: name)
                sub.parent = t
                try fill(sub, from: tm, file: file)
                t.types[name] = sub
            }
        }
        if let en = map(m["enums"]) {
            for (name, v) in en {
                var values: [Int64: String] = [:]
                for (k, label) in mapAnyKeys(v) {
                    guard let n = intValue(k) else { continue }
                    values[n] = str(label) ?? str(map(label)?["id"]) ?? "?"
                }
                t.enums[name] = values
            }
        }
    }

    /// Keys in the order they first appear as "key:" at a line start in the
    /// source (good enough for display order; unknown keys go last).
    private func sortedBySource(_ keys: [String]) -> [String] {
        func position(_ k: String) -> Int {
            let pattern = "(?m)^\\s+" + NSRegularExpression.escapedPattern(for: k) + ":"
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else { return .max }
            return m.range.location
        }
        return keys.map { ($0, position($0)) }.sorted { ($0.1, $0.0) < ($1.1, $1.0) }.map(\.0)
    }

    private func endianSpec(_ v: Any) throws -> EndianSpec {
        if let s = str(v) { return .fixed(s == "be" ? .big : .little) }
        guard let m = map(v), let on = str(m["switch-on"]) else { throw KaitaiError(L("Cannot parse endian")) }
        let cases = try mapAnyKeys(m["cases"]).map { k, v in
            (try Expr.parse(keyString(k)), (str(v) == "be" ? Endian.big : Endian.little))
        }
        return .switchOn(try Expr.parse(on), cases)
    }

    private func attr(_ m: [String: Any], fallbackID: String) throws -> AttrSpec {
        var a = AttrSpec(id: str(m["id"]) ?? fallbackID)
        do {
            if let t = m["type"] { a.type = try typeRef(t) }
            if let s = m["size"] { a.size = try Expr.parse(keyString(s)) }
            a.sizeEos = (m["size-eos"] as? Bool) ?? false
            if let c = m["contents"] { a.contents = try contents(c) }
            switch str(m["repeat"]) {
            case "eos": a.repeatSpec = .eos
            case "expr": a.repeatSpec = .expr(try Expr.parse(keyString(m["repeat-expr"] ?? "0")))
            case "until": a.repeatSpec = .until(try Expr.parse(keyString(m["repeat-until"] ?? "true")))
            default: break
            }
            if let c = m["if"] { a.cond = try Expr.parse(keyString(c)) }
            a.encoding = str(m["encoding"])
            if let t = m["terminator"] { a.terminator = UInt8(truncatingIfNeeded: intValue(t) ?? 0) }
            if let c = m["consume"] as? Bool { a.consume = c }
            if let i = m["include"] as? Bool { a.include = i }
            if let e = m["eos-error"] as? Bool { a.eosError = e }
            if let p = m["pad-right"] { a.padRight = UInt8(truncatingIfNeeded: intValue(p) ?? 0) }
            if let p = str(m["process"]) { a.process = try process(p) }
            a.enumName = str(m["enum"])
            if let v = m["valid"] { a.valid = try valid(v) }
            if let p = m["pos"] { a.pos = try Expr.parse(keyString(p)) }
            if let i = m["io"] { a.io = try Expr.parse(keyString(i)) }
            if let v = m["value"] { a.value = try Expr.parse(keyString(v)) }
        } catch var e as KaitaiError {
            e.path = a.id
            throw e
        }
        return a
    }

    private func typeRef(_ v: Any) throws -> TypeRef {
        if let s = str(v) {
            // "name(arg1, arg2)" passes parameters.
            if let open = s.firstIndex(of: "("), s.hasSuffix(")") {
                let name = String(s[..<open]).trimmingCharacters(in: .whitespaces)
                let argText = String(s[s.index(after: open)..<s.index(before: s.endIndex)])
                return .named(name, args: try Expr.parseList(argText))
            }
            return .named(s, args: [])
        }
        guard let m = map(v), let on = m["switch-on"] else { throw KaitaiError(L("Cannot parse type")) }
        let cases: [(key: Expr?, type: TypeRef)] = try mapAnyKeys(m["cases"]).map { k, t in
            let ks = keyString(k)
            return (ks == "_" ? nil : try Expr.parse(ks), try typeRef(t))
        }
        return .switchOn(try Expr.parse(keyString(on)), cases: cases)
    }

    private func contents(_ v: Any) throws -> [UInt8] {
        if let s = v as? String { return Array(s.utf8) }
        guard let l = v as? [Any] else { throw KaitaiError(L("Cannot parse contents")) }
        var out: [UInt8] = []
        for e in l {
            if let s = e as? String { out += Array(s.utf8) }
            else if let n = intValue(e) { out.append(UInt8(truncatingIfNeeded: n)) }
        }
        return out
    }

    private func process(_ s: String) throws -> ProcessSpec {
        if s == "zlib" { return .zlib }
        guard let open = s.firstIndex(of: "("), s.hasSuffix(")") else { throw KaitaiError(L("process %@ not supported", "\(s)")) }
        let name = String(s[..<open])
        let arg = try Expr.parse(String(s[s.index(after: open)..<s.index(before: s.endIndex)]))
        switch name {
        case "xor": return .xor(arg)
        case "rol": return .rol(arg)
        case "ror": return .ror(arg)
        default: throw KaitaiError(L("process %@ not supported", "\(name)"))
        }
    }

    private func valid(_ v: Any) throws -> ValidSpec {
        guard let m = map(v) else { return .eq(try Expr.parse(keyString(v))) }
        if let e = m["eq"] { return .eq(try Expr.parse(keyString(e))) }
        if let l = m["any-of"] as? [Any] { return .anyOf(try l.map { try Expr.parse(keyString($0)) }) }
        if let e = m["expr"] { return .expr(try Expr.parse(keyString(e))) }
        return .range(min: try m["min"].map { try Expr.parse(keyString($0)) },
                      max: try m["max"].map { try Expr.parse(keyString($0)) })
    }
}

// MARK: YAML helpers (Yams gives [String: Any] or [AnyHashable: Any])

func map(_ v: Any?) -> [String: Any]? {
    if let m = v as? [String: Any] { return m }
    if let m = v as? [AnyHashable: Any] {
        return Dictionary(m.map { (keyString($0.key.base), $0.value) }, uniquingKeysWith: { a, _ in a })
    }
    return nil
}

/// Mapping entries with their keys kept as parsed (ints stay ints).
func mapAnyKeys(_ v: Any?) -> [(Any, Any)] {
    if let m = v as? [AnyHashable: Any] { return m.map { ($0.key.base, $0.value) } }
    if let m = v as? [String: Any] { return m.map { ($0.key, $0.value) } }
    return []
}

func list(_ v: Any?) -> [Any]? { v as? [Any] }

func str(_ v: Any?) -> String? {
    switch v {
    case let s as String: s
    case let i as Int: String(i)
    default: nil
    }
}

func intValue(_ v: Any?) -> Int64? {
    switch v {
    case let i as Int: Int64(i)
    case let i as Int64: i
    case let u as UInt64: Int64(bitPattern: u)
    case let s as String: Expr.parseIntLiteral(s)
    default: nil
    }
}

/// YAML scalars back to expression source ("0x10" parsed as 16 → "16").
func keyString(_ v: Any) -> String {
    switch v {
    case let s as String: s
    case let b as Bool: b ? "true" : "false"
    case let i as Int: String(i)
    case let d as Double: String(d)
    default: String(describing: v)
    }
}
