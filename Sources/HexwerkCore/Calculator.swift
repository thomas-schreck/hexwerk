import Foundation

/// Programmer's calculator (SPEC FR-10.8): 64-bit integer expressions with
/// C operators and variables such as the value under the cursor.
public enum Calculator {
    public struct CalcError: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// Wrapping 64-bit arithmetic; division is unsigned unless an operand
    /// was written negative (then signed), which matches what one expects
    /// for addresses and for small negative numbers alike.
    public static func evaluate(_ text: String, variables: [String: UInt64] = [:]) throws -> UInt64 {
        var p = Parser(tokens: try tokenize(text), vars: variables)
        let v = try p.expression(0)
        guard p.i == p.tokens.count else { throw CalcError(message: L("unexpected: %@", "\(p.tokens[p.i])")) }
        return v.value
    }

    enum Tok: Equatable, CustomStringConvertible {
        case num(UInt64), ident(String), op(String)
        var description: String {
            switch self { case .num(let n): "\(n)"; case .ident(let s): s; case .op(let s): s }
        }
    }

    static func tokenize(_ s: String) throws -> [Tok] {
        let c = Array(s)
        var out: [Tok] = []
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch.isWhitespace || ch == "_" && (i == 0 || !c[i - 1].isLetter) { i += 1; continue }
            if ch.isNumber {
                var j = i
                while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == "_" { j += 1 }
                let raw = String(c[i ..< j]).lowercased().replacingOccurrences(of: "_", with: "")
                let v: UInt64?
                if raw.hasPrefix("0x") { v = UInt64(raw.dropFirst(2), radix: 16) }
                else if raw.hasPrefix("0b") { v = UInt64(raw.dropFirst(2), radix: 2) }
                else if raw.hasPrefix("0o") { v = UInt64(raw.dropFirst(2), radix: 8) }
                else if raw.hasSuffix("h"), let h = UInt64(raw.dropLast(), radix: 16) { v = h }   // 1Fh
                else { v = UInt64(raw) }
                guard let v else { throw CalcError(message: L("invalid number %@", raw)) }
                out.append(.num(v))
                i = j
                continue
            }
            if ch.isLetter || ch == "_" {
                var j = i
                while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == "_" { j += 1 }
                out.append(.ident(String(c[i ..< j]).lowercased()))
                i = j
                continue
            }
            if ch == "'" {
                // 'A' or 'ABCD' (multi-char, big-endian like a FourCC).
                guard let end = c[(i + 1)...].firstIndex(of: "'"), end > i + 1, end - i - 1 <= 8 else {
                    throw CalcError(message: L("unterminated character constant"))
                }
                var v: UInt64 = 0
                for u in String(c[(i + 1) ..< end]).utf8 { v = v << 8 | UInt64(u) }
                out.append(.num(v))
                i = end + 1
                continue
            }
            let two = i + 1 < c.count ? String(c[i ... i + 1]) : ""
            if ["<<", ">>", "**"].contains(two) { out.append(.op(two)); i += 2; continue }
            guard "+-*/%&|^~()".contains(ch) else { throw CalcError(message: L("unexpected character %@", String(ch))) }
            out.append(.op(String(ch)))
            i += 1
        }
        return out
    }

    struct Val { var value: UInt64; var signed: Bool }

    struct Parser {
        let tokens: [Tok]
        let vars: [String: UInt64]
        var i = 0

        static let binary: [String: Int] = ["|": 1, "^": 2, "&": 3, "<<": 4, ">>": 4, "+": 5, "-": 5, "*": 6, "/": 6, "%": 6, "**": 8]

        mutating func expression(_ minPrec: Int) throws -> Val {
            var lhs = try unary()
            while i < tokens.count, case .op(let op) = tokens[i], let prec = Self.binary[op], prec >= minPrec {
                i += 1
                // ** is right-associative.
                let rhs = try expression(op == "**" ? prec : prec + 1)
                lhs = try apply(op, lhs, rhs)
            }
            return lhs
        }

        mutating func unary() throws -> Val {
            guard i < tokens.count else { throw CalcError(message: L("incomplete expression")) }
            let t = tokens[i]
            i += 1
            switch t {
            case .num(let n): return Val(value: n, signed: false)
            case .ident(let name):
                guard let v = vars[name] else { throw CalcError(message: L("unknown: %@", "\(name)")) }
                return Val(value: v, signed: false)
            case .op("-"): let v = try unary(); return Val(value: 0 &- v.value, signed: true)
            case .op("+"): return try unary()
            case .op("~"): let v = try unary(); return Val(value: ~v.value, signed: v.signed)
            case .op("("):
                let v = try expression(0)
                guard i < tokens.count, tokens[i] == .op(")") else { throw CalcError(message: L("missing “)”")) }
                i += 1
                return v
            default: throw CalcError(message: L("unexpected: %@", "\(t)"))
            }
        }

        func apply(_ op: String, _ a: Val, _ b: Val) throws -> Val {
            let signed = a.signed || b.signed
            let x = a.value, y = b.value
            let r: UInt64
            switch op {
            case "+": r = x &+ y
            case "-": r = x &- y
            case "*": r = x &* y
            case "/", "%":
                guard y != 0 else { throw CalcError(message: L("Division by 0")) }
                if signed {
                    let sx = Int64(bitPattern: x), sy = Int64(bitPattern: y)
                    guard !(sx == .min && sy == -1) else { throw CalcError(message: L("overflow")) }
                    r = UInt64(bitPattern: op == "/" ? sx / sy : sx % sy)
                } else {
                    r = op == "/" ? x / y : x % y
                }
            case "<<": r = y >= 64 ? 0 : x << y
            case ">>": r = y >= 64 ? 0 : x >> y
            case "&": r = x & y
            case "|": r = x | y
            case "^": r = x ^ y
            case "**":
                var base = x, e = y, acc: UInt64 = 1
                while e > 0 { if e & 1 == 1 { acc = acc &* base }; base = base &* base; e >>= 1 }
                r = acc
            default: throw CalcError(message: L("operator %@", "\(op)"))
            }
            return Val(value: r, signed: signed)
        }
    }

    /// The result in all common representations.
    public struct Views: Sendable, Equatable {
        public let unsigned: String, signed: String, hex: String, octal: String, binary: String
        public let ascii: String, float32: String, float64: String

        public init(_ v: UInt64, bits: Int = 64) {
            let mask: UInt64 = bits == 64 ? .max : (1 << UInt64(bits)) - 1
            let m = v & mask
            unsigned = String(m)
            let shift = UInt64(64 - bits)
            signed = String(Int64(bitPattern: m << shift) >> Int64(shift))
            hex = "0x" + String(m, radix: 16, uppercase: true)
            octal = "0o" + String(m, radix: 8)
            let b = String(m, radix: 2)
            let padded = String(repeating: "0", count: max(0, bits - b.count)) + b
            binary = stride(from: 0, to: padded.count, by: 4).map {
                let s = padded.index(padded.startIndex, offsetBy: $0)
                return String(padded[s ..< padded.index(s, offsetBy: 4, limitedBy: padded.endIndex)!])
            }.joined(separator: " ")
            let bytes = (0 ..< bits / 8).reversed().map { UInt8(m >> UInt64(8 * $0) & 0xFF) }
            ascii = String(bytes.map { (0x20..<0x7F).contains($0) ? Character(UnicodeScalar($0)) : "·" })
            float32 = "\(Float(bitPattern: UInt32(truncatingIfNeeded: m)))"
            float64 = "\(Double(bitPattern: m))"
        }
    }
}
