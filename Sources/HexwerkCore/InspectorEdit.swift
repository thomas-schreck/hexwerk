import Foundation

/// Values typed into the data inspector, back to bytes (SPEC FR-4.6).
extension Inspector {
    public struct EncodeError: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// Bytes to write at the cursor for `text` in the row `name`. Text
    /// rows write the string without a terminator; LEB128 rows write the
    /// minimal encoding (its length may differ from the old one).
    public static func encode(_ name: String, _ text: String, endian: Endian) throws -> Data {
        let t = text.trimmingCharacters(in: .whitespaces)
        func fail(_ m: String) -> EncodeError { EncodeError(message: m) }
        func bytes(_ v: UInt64, _ n: Int) -> Data {
            let le = (0 ..< n).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) }
            return Data(endian == .little ? le : le.reversed())
        }
        func signed(_ n: Int) throws -> Data {
            guard let v = parseInt(t) else { throw fail(L("not an integer")) }
            let bits = n * 8
            let lo = bits == 64 ? Int64.min : -(Int64(1) << (bits - 1)), hi = bits == 64 ? Int64.max : (Int64(1) << (bits - 1)) - 1
            guard let s = v.signed, s >= lo, s <= hi else { throw fail(L("out of range for int%ld", bits)) }
            return bytes(UInt64(bitPattern: s), n)
        }
        func unsigned(_ n: Int) throws -> Data {
            guard let v = parseInt(t), let u = v.unsigned else { throw fail(L("not an unsigned integer")) }
            guard n == 8 || u < UInt64(1) << UInt64(n * 8) else { throw fail(L("out of range for uint%ld", n * 8)) }
            return bytes(u, n)
        }
        switch name {
        case "int8": return try signed(1)
        case "uint8": return try unsigned(1)
        case "int16": return try signed(2)
        case "uint16": return try unsigned(2)
        case "int32": return try signed(4)
        case "uint32": return try unsigned(4)
        case "int64": return try signed(8)
        case "uint64": return try unsigned(8)
        case "float32":
            guard let f = Float(t) else { throw fail(L("not a number")) }
            return bytes(UInt64(f.bitPattern), 4)
        case "float64":
            guard let d = Double(t) else { throw fail(L("not a number")) }
            return bytes(d.bitPattern, 8)
        case "binary":
            let s = t.replacingOccurrences(of: " ", with: "")
            guard s.count <= 8, let v = UInt8(s, radix: 2) else { throw fail(L("up to 8 bits of 0 and 1")) }
            return Data([v])
        case "Unix time 32":
            let s = try seconds(t)
            guard s >= 0, s <= Double(UInt32.max) else { throw fail(L("out of range 1970–2106")) }
            return bytes(UInt64(s), 4)
        case "Unix time 64":
            // Int64(Double) traps outside its range; exactly: returns nil instead.
            guard let s = Int64(exactly: try seconds(t).rounded(.towardZero)) else { throw fail(L("out of range for int%ld", 64)) }
            return bytes(UInt64(bitPattern: s), 8)
        case "FILETIME":
            let s = try seconds(t) + 11_644_473_600
            guard s >= 0 else { throw fail(L("before 1601")) }
            guard let ticks = UInt64(exactly: (s * 10_000_000).rounded(.towardZero)) else { throw fail(L("out of range for uint%ld", 64)) }
            return bytes(ticks, 8)
        case "DOS date/time":
            let s = try seconds(t)
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: s))
            guard let y = c.year, (1980...2107).contains(y) else { throw fail(L("DOS date only 1980–2107")) }
            let date = UInt64((y - 1980) << 9 | c.month! << 5 | c.day!)
            let time = UInt64(c.hour! << 11 | c.minute! << 5 | c.second! / 2)
            // Always little endian, like the display.
            return Data((0 ..< 4).map { UInt8(truncatingIfNeeded: (date << 16 | time) >> (8 * UInt64($0))) })
        case "GUID":
            // isHexDigit also accepts fullwidth digits, which UInt8(radix:) rejects.
            let h = t.filter { $0.isASCII && $0.isHexDigit }
            guard h.count == 32 else { throw fail(L("GUID needs 32 hex digits")) }
            let raw = stride(from: 0, to: 32, by: 2).map { UInt8(h[h.index(h.startIndex, offsetBy: $0) ..< h.index(h.startIndex, offsetBy: $0 + 2)], radix: 16)! }
            // Microsoft order: first three fields little endian.
            return Data(raw[0 ..< 4].reversed() + raw[4 ..< 6].reversed() + raw[6 ..< 8].reversed() + raw[8...])
        case "ULEB128":
            guard let v = parseInt(t)?.unsigned else { throw fail(L("not an unsigned integer")) }
            var out = Data(), x = v
            repeat {
                var b = UInt8(x & 0x7F); x >>= 7
                if x != 0 { b |= 0x80 }
                out.append(b)
            } while x != 0
            return out
        case "SLEB128":
            guard let v = parseInt(t)?.signed else { throw fail(L("not an integer")) }
            var out = Data(), x = v, more = true
            while more {
                var b = UInt8(x & 0x7F); x >>= 7
                if (x == 0 && b & 0x40 == 0) || (x == -1 && b & 0x40 != 0) { more = false } else { b |= 0x80 }
                out.append(b)
            }
            return out
        case "ASCII":
            let s = unquote(t)
            guard s.unicodeScalars.allSatisfy(\.isASCII) else { throw fail(L("ASCII characters only")) }
            return Data(s.utf8)
        case "UTF-8": return Data(unquote(t).utf8)
        case "UTF-16 LE": return Data(unquote(t).utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        case "UTF-16 BE": return Data(unquote(t).utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
        default: throw fail(L("%@ is not editable", name))
        }
    }

    struct ParsedInt { let signed: Int64?; let unsigned: UInt64? }

    /// Decimal, 0x hex, 0b binary, with optional sign and underscores.
    static func parseInt(_ s: String) -> ParsedInt? {
        var t = s.lowercased().replacingOccurrences(of: "_", with: "")
        var neg = false
        if t.hasPrefix("-") { neg = true; t.removeFirst() } else if t.hasPrefix("+") { t.removeFirst() }
        let mag: UInt64?
        if t.hasPrefix("0x") { mag = UInt64(t.dropFirst(2), radix: 16) }
        else if t.hasPrefix("0b") { mag = UInt64(t.dropFirst(2), radix: 2) }
        else { mag = UInt64(t) }
        guard let m = mag else { return nil }
        if neg {
            guard m <= UInt64(Int64.max) + 1 else { return nil }
            return ParsedInt(signed: m == UInt64(Int64.max) + 1 ? .min : -Int64(m), unsigned: nil)
        }
        return ParsedInt(signed: m <= UInt64(Int64.max) ? Int64(m) : nil, unsigned: m)
    }

    /// ISO 8601 (as displayed), "YYYY-MM-DD HH:MM:SS" (UTC) or seconds.
    static func seconds(_ t: String) throws -> Double {
        if let v = Double(t) {
            // "inf", "nan" and 1e400 parse as Double but are no point in time.
            guard v.isFinite else { throw EncodeError(message: L("not a number")) }
            return v
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: t) { return d.timeIntervalSince1970 }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: t) { return d.timeIntervalSince1970 }
        }
        throw EncodeError(message: L("Date as 2026-11-06T09:30:00Z, 2026-11-06 09:30:00 or seconds"))
    }

    /// Text for the edit field: LEB128 rows drop the "(n Byte)" suffix.
    public static func unquoteForEdit(_ shown: String, name: String) -> String {
        if name.hasSuffix("LEB128"), let i = shown.firstIndex(of: " ") { return String(shown[..<i]) }
        return shown
    }

    static func unquote(_ s: String) -> String {
        s.count >= 2 && s.hasPrefix("\"") && s.hasSuffix("\"") ? String(s.dropFirst().dropLast()) : s
    }
}
