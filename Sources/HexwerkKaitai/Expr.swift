import Foundation
import HexwerkCore

/// Kaitai expression AST.
indirect enum Expr {
    case int(Int64)
    case float(Double)
    case str(String)
    case bool(Bool)
    case name(String)
    case enumLit(path: [String], value: String)  // a::b::c → enum path [a, b], value c
    case array([Expr])
    case unary(String, Expr)
    case binary(String, Expr, Expr)
    case ternary(Expr, Expr, Expr)
    case member(Expr, String)
    case call(Expr, String, [Expr])
    case index(Expr, Expr)
    case sizeofType(String)
    case cast(Expr, String)

    static func parse(_ text: String) throws -> Expr {
        var p = ExprParser(tokens: try ExprLexer.tokens(text), source: text)
        let e = try p.ternary()
        guard p.atEnd else { throw KaitaiError(L("Expression \"%@\": unexpected %@", text, p.peekDescription)) }
        return e
    }

    /// Comma separated list (type arguments).
    static func parseList(_ text: String) throws -> [Expr] {
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        var p = ExprParser(tokens: try ExprLexer.tokens(text), source: text)
        var out = [try p.ternary()]
        while p.accept(.punct(",")) { out.append(try p.ternary()) }
        guard p.atEnd else { throw KaitaiError(L("Cannot parse arguments \"%@\"", text)) }
        return out
    }

    static func parseIntLiteral(_ s: String) -> Int64? {
        var t = s.replacingOccurrences(of: "_", with: "").lowercased()
        var neg = false
        if t.hasPrefix("-") { neg = true; t.removeFirst() }
        let v: UInt64?
        if t.hasPrefix("0x") {
            v = UInt64(t.dropFirst(2), radix: 16)
        } else if t.hasPrefix("0b") {
            v = UInt64(t.dropFirst(2), radix: 2)
        } else if t.hasPrefix("0o") {
            v = UInt64(t.dropFirst(2), radix: 8)
        } else {
            v = UInt64(t)
        }
        guard let v else { return nil }
        // Positive literals up to UInt64.max are kept as bit patterns (u8
        // masks); negative ones must fit into Int64.
        if neg { return v <= UInt64(Int64.max) + 1 ? 0 &- Int64(bitPattern: v) : nil }
        return Int64(bitPattern: v)
    }
}

enum Token: Equatable {
    case int(Int64), float(Double), str(String), ident(String), punct(String)
}

enum ExprLexer {
    static let puncts = [
        "<<", ">>", "<=", ">=", "==", "!=", "::", "+", "-", "*", "/", "%", "<", ">",
        "&", "|", "^", "~", "?", ":", "(", ")", "[", "]", ".", ",",
    ]
    private static let punctScalars = puncts.map { ($0, Array($0.unicodeScalars)) }

    /// Generous: lookup tables in real formats are array literals with a few
    /// thousand tokens. Only keeps lexing and memory in proportion.
    static let maxTokens = 100_000

    static func tokens(_ s: String) throws -> [Token] {
        let c = Array(s.unicodeScalars)
        var i = 0
        var out: [Token] = []
        func isIdent(_ u: UnicodeScalar) -> Bool { CharacterSet.alphanumerics.contains(u) || u == "_" }
        while i < c.count {
            guard out.count < maxTokens else {
                throw KaitaiError(L("Expression longer than %@ tokens", "\(maxTokens)"))
            }
            let ch = c[i]
            if CharacterSet.whitespacesAndNewlines.contains(ch) { i += 1; continue }
            if CharacterSet.decimalDigits.contains(ch) {
                var j = i
                while j < c.count,
                    isIdent(c[j]) || (c[j] == "." && j + 1 < c.count && CharacterSet.decimalDigits.contains(c[j + 1]))
                        || ((c[j] == "+" || c[j] == "-") && j > i && (c[j - 1] == "e" || c[j - 1] == "E")
                            && !String(String.UnicodeScalarView(c[i ..< j])).lowercased().hasPrefix("0x"))
                {
                    j += 1
                }
                let lit = String(String.UnicodeScalarView(c[i ..< j]))
                if let n = Expr.parseIntLiteral(lit) {
                    out.append(.int(n))
                } else if let d = Double(lit.replacingOccurrences(of: "_", with: "")) {
                    out.append(.float(d))
                } else {
                    throw KaitaiError(L("Cannot parse number %@ in \"%@\"", "\(lit)", "\(s)"))
                }
                i = j
                continue
            }
            if ch == "'" || ch == "\"" {
                var j = i + 1
                var lit = ""
                while j < c.count, c[j] != ch {
                    if ch == "\"" && c[j] == "\\" && j + 1 < c.count {
                        j += 1
                        switch c[j] {
                        case "n": lit += "\n"
                        case "t": lit += "\t"
                        case "r": lit += "\r"
                        case "0": lit += "\0"
                        default: lit.unicodeScalars.append(c[j])
                        }
                    } else {
                        lit.unicodeScalars.append(c[j])
                    }
                    j += 1
                }
                guard j < c.count else { throw KaitaiError(L("Unterminated string in \"%@\"", "\(s)")) }
                out.append(.str(lit))
                i = j + 1
                continue
            }
            if isIdent(ch) {
                var j = i
                while j < c.count, isIdent(c[j]) { j += 1 }
                out.append(.ident(String(String.UnicodeScalarView(c[i ..< j]))))
                i = j
                continue
            }
            // Compared in place: building the rest as a String per token was O(n²).
            guard
                let (p, u) = punctScalars.first(where: { _, u in
                    i + u.count <= c.count && c[i ..< i + u.count].elementsEqual(u)
                })
            else {
                throw KaitaiError(L("Unexpected character \"%@\" in \"%@\"", "\(ch)", "\(s)"))
            }
            out.append(.punct(p))
            i += u.count
        }
        return out
    }
}

/// Precedence climbing, lowest first:
/// ?: · or · and · not · comparisons · | · ^ · & · << >> · + - · * / % · unary - ~ · postfix
struct ExprParser {
    let tokens: [Token]
    let source: String
    var i = 0
    /// Recursion depth of the descent; each level costs a dozen stack frames.
    private var depth = 0
    static let maxDepth = 32
    /// Operator nodes built so far. A chain like 1+1+… nests the AST once per
    /// operator, and evaluation and deallocation recurse per level, so this
    /// bounds the AST depth (flat array literals do not count).
    private var operators = 0
    static let maxOperators = 2000

    private mutating func op(_ e: Expr) throws -> Expr {
        operators += 1
        guard operators <= Self.maxOperators else {
            throw KaitaiError(L("Expression has more than %@ operators", "\(Self.maxOperators)"))
        }
        return e
    }

    init(tokens: [Token], source: String) {
        self.tokens = tokens
        self.source = source
    }

    var atEnd: Bool { i >= tokens.count }
    var peekDescription: String { atEnd ? L("end of input") : "\(tokens[i])" }

    mutating func accept(_ t: Token) -> Bool {
        if !atEnd && tokens[i] == t { i += 1; return true }
        return false
    }

    mutating func expect(_ t: Token) throws {
        guard accept(t) else { throw KaitaiError(L("Expression \"%@\": expected %@, found %@", source, "\(t)", peekDescription)) }
    }

    private func isIdent(_ name: String) -> Bool { !atEnd && tokens[i] == .ident(name) }

    /// Runs `body` one level deeper; parentheses, brackets, arguments and
    /// prefix operators all pass through here.
    private mutating func nested<R>(_ body: (inout ExprParser) throws -> R) throws -> R {
        guard depth < Self.maxDepth else {
            throw KaitaiError(L("Expression \"%@\": nested deeper than %@", source, "\(Self.maxDepth)"))
        }
        depth += 1
        defer { depth -= 1 }
        return try body(&self)
    }

    mutating func ternary() throws -> Expr {
        try nested { try $0.ternaryLevel() }
    }

    private mutating func ternaryLevel() throws -> Expr {
        let c = try or()
        if accept(.punct("?")) {
            let a = try ternary()
            try expect(.punct(":"))
            let b = try ternary()
            return try op(.ternary(c, a, b))
        }
        return c
    }

    mutating func or() throws -> Expr {
        var l = try and()
        while isIdent("or") { i += 1; l = try op(.binary("or", l, try and())) }
        return l
    }

    mutating func and() throws -> Expr {
        var l = try not()
        while isIdent("and") { i += 1; l = try op(.binary("and", l, try not())) }
        return l
    }

    mutating func not() throws -> Expr {
        if isIdent("not") { i += 1; return try op(.unary("not", try nested { try $0.not() })) }
        return try comparison()
    }

    mutating func comparison() throws -> Expr {
        let l = try binaryLevel(0)
        for op in ["==", "!=", "<=", ">=", "<", ">"] where accept(.punct(op)) {
            return try self.op(.binary(op, l, try binaryLevel(0)))
        }
        return l
    }

    static let levels: [[String]] = [["|"], ["^"], ["&"], ["<<", ">>"], ["+", "-"], ["*", "/", "%"]]

    mutating func binaryLevel(_ n: Int) throws -> Expr {
        if n == Self.levels.count { return try unary() }
        var l = try binaryLevel(n + 1)
        loop: while true {
            for op in Self.levels[n] where accept(.punct(op)) {
                l = try self.op(.binary(op, l, try binaryLevel(n + 1)))
                continue loop
            }
            return l
        }
    }

    mutating func unary() throws -> Expr {
        if accept(.punct("-")) { return try op(.unary("-", try nested { try $0.unary() })) }
        if accept(.punct("~")) { return try op(.unary("~", try nested { try $0.unary() })) }
        if accept(.punct("+")) { return try nested { try $0.unary() } }
        return try postfix()
    }

    mutating func postfix() throws -> Expr {
        var e = try primary()
        while true {
            if accept(.punct(".")) {
                guard !atEnd, case .ident(let name) = tokens[i] else {
                    throw KaitaiError(L("Expression \"%@\": name expected after .", source))
                }
                i += 1
                if name == "as", accept(.punct("<")) {
                    e = try op(.cast(e, try typeName(until: ">")))
                } else if accept(.punct("(")) {
                    var args: [Expr] = []
                    if !accept(.punct(")")) {
                        args.append(try ternary())
                        while accept(.punct(",")) { args.append(try ternary()) }
                        try expect(.punct(")"))
                    }
                    e = try op(.call(e, name, args))
                } else {
                    e = try op(.member(e, name))
                }
            } else if accept(.punct("[")) {
                let idx = try ternary()
                try expect(.punct("]"))
                e = try op(.index(e, idx))
            } else {
                return e
            }
        }
    }

    /// Type name inside <…>, may contain :: and [] (e.g. `as<u4>`, `sizeof<foo::bar>`).
    mutating func typeName(until close: String) throws -> String {
        var s = ""
        while !atEnd, tokens[i] != .punct(close) {
            switch tokens[i] {
            case .ident(let n): s += n
            case .punct(let p): s += p
            case .int(let n): s += String(n)
            default: break
            }
            i += 1
        }
        try expect(.punct(close))
        return s
    }

    mutating func primary() throws -> Expr {
        guard !atEnd else { throw KaitaiError(L("Expression \"%@\": incomplete", source)) }
        let t = tokens[i]
        i += 1
        switch t {
        case .int(let n): return .int(n)
        case .float(let d): return .float(d)
        case .str(let s): return .str(s)
        case .punct("("):
            let e = try ternary()
            try expect(.punct(")"))
            return e
        case .punct("["):
            var items: [Expr] = []
            if !accept(.punct("]")) {
                items.append(try ternary())
                while accept(.punct(",")) { items.append(try ternary()) }
                try expect(.punct("]"))
            }
            return .array(items)
        case .ident("true"): return .bool(true)
        case .ident("false"): return .bool(false)
        case .ident("sizeof") where !atEnd && tokens[i] == .punct("<"):
            i += 1
            return .sizeofType(try typeName(until: ">"))
        case .ident(let name):
            // a::b::c is an enum literal; the last part is the value.
            if !atEnd, tokens[i] == .punct("::") {
                var parts = [name]
                while accept(.punct("::")) {
                    guard !atEnd, case .ident(let n) = tokens[i] else {
                        throw KaitaiError(L("Expression \"%@\": name expected after ::", source))
                    }
                    i += 1
                    parts.append(n)
                }
                return .enumLit(path: Array(parts.dropLast()), value: parts.last!)
            }
            return .name(name)
        default:
            throw KaitaiError(L("Expression \"%@\": unexpected %@", source, "\(t)"))
        }
    }
}
