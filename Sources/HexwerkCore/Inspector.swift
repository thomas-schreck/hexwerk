import Foundation

public enum Endian: String, Sendable, CaseIterable {
    case little, big
}

/// One row of the data inspector. `value` is nil when there are not enough
/// bytes left (e.g. an int64 two bytes before the end of the file).
public struct InspectorValue: Sendable, Equatable {
    public let name: String
    public let value: String?
}

/// Interprets the bytes at a position as common data types (SPEC FR-4.x).
public enum Inspector {
    /// How many bytes the inspector looks at; strings are cut off here.
    public static let window = 64

    public static func values(_ data: Data, endian: Endian) -> [InspectorValue] {
        let b = [UInt8](data.prefix(window))
        var out: [InspectorValue] = []
        func add(_ name: String, _ v: String?) { out.append(InspectorValue(name: name, value: v)) }

        func uint(_ n: Int) -> UInt64? {
            guard b.count >= n else { return nil }
            let bytes = endian == .little ? Array(b[0..<n]) : b[0..<n].reversed()
            return bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * $1.offset) }
        }
        func le(_ n: Int, from: Int = 0) -> UInt64? {   // fixed little endian
            guard b.count >= from + n else { return nil }
            return b[from..<from + n].enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * $1.offset) }
        }

        add("int8", uint(1).map { String(Int8(truncatingIfNeeded: $0)) })
        add("uint8", uint(1).map { String($0) })
        add("int16", uint(2).map { String(Int16(truncatingIfNeeded: $0)) })
        add("uint16", uint(2).map { String($0) })
        add("int32", uint(4).map { String(Int32(truncatingIfNeeded: $0)) })
        add("uint32", uint(4).map { String($0) })
        add("int64", uint(8).map { String(Int64(bitPattern: $0)) })
        add("uint64", uint(8).map { String($0) })
        add("float32", uint(4).map { "\(Float(bitPattern: UInt32($0)))" })
        add("float64", uint(8).map { "\(Double(bitPattern: $0))" })
        add("binary", b.first.map { String($0, radix: 2).leftPadded(to: 8) })

        add("Unix time 32", uint(4).map { iso(Double(UInt32($0))) })
        add("Unix time 64", uint(8).flatMap { v in
            let s = Int64(bitPattern: v)
            // Years 0001–9999; no abs(): abs(Int64.min) traps.
            return s > -62_135_596_800 && s < 253_402_300_800 ? iso(Double(s)) : nil
        })
        add("FILETIME", uint(8).flatMap { v in
            // 100 ns ticks since 1601-01-01.
            let secs = Double(v) / 10_000_000 - 11_644_473_600
            return secs < 253_402_300_800 ? iso(secs) : nil
        })
        add("DOS date/time", le(4).flatMap(dosDateTime))
        add("GUID", b.count >= 16 ? guid(b) : nil)

        add("ULEB128", leb128(b, signed: false))
        add("SLEB128", leb128(b, signed: true))

        add("ASCII", cString(b, encoding: .ascii))
        add("UTF-8", cString(b, encoding: .utf8))
        add("UTF-16 LE", utf16String(b, littleEndian: true))
        add("UTF-16 BE", utf16String(b, littleEndian: false))
        return out
    }

    private static func iso(_ secs: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date(timeIntervalSince1970: secs))
    }

    /// MS-DOS packed date/time: low word = time, high word = date.
    private static func dosDateTime(_ v: UInt64) -> String? {
        let time = UInt16(v & 0xFFFF), date = UInt16(v >> 16)
        let day = date & 0x1F, month = (date >> 5) & 0x0F, year = 1980 + Int(date >> 9)
        let sec = (time & 0x1F) * 2, minute = (time >> 5) & 0x3F, hour = time >> 11
        guard (1...31).contains(day), (1...12).contains(month), hour < 24, minute < 60, sec < 60 else { return nil }
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d", year, month, day, hour, minute, sec)
    }

    /// Microsoft byte order: the first three fields are little endian.
    private static func guid(_ b: [UInt8]) -> String {
        func hex(_ s: ArraySlice<UInt8>) -> String { s.map { String(format: "%02X", $0) }.joined() }
        return "{\(hex(b[0..<4].reversed()[...]))-\(hex(b[4..<6].reversed()[...]))-\(hex(b[6..<8].reversed()[...]))-\(hex(b[8..<10]))-\(hex(b[10..<16]))}"
    }

    private static func leb128(_ b: [UInt8], signed: Bool) -> String? {
        var result: UInt64 = 0, shift: UInt64 = 0
        for (i, byte) in b.prefix(10).enumerated() {
            result |= UInt64(byte & 0x7F) << shift
            shift += 7
            if byte & 0x80 == 0 {
                if signed && shift < 64 && byte & 0x40 != 0 { result |= ~0 << shift }
                return L("%@ (%ld bytes)", signed ? String(Int64(bitPattern: result)) : String(result), i + 1)
            }
        }
        return nil
    }

    private static func cString(_ b: [UInt8], encoding: String.Encoding) -> String? {
        let bytes = b.prefix { $0 != 0 }
        if encoding == .ascii && bytes.contains(where: { $0 >= 0x80 }) { return nil }
        return String(data: Data(bytes), encoding: encoding).map(quote)
    }

    private static func utf16String(_ b: [UInt8], littleEndian: Bool) -> String? {
        var units: [UInt16] = []
        var i = 0
        while i + 1 < b.count {
            let u = littleEndian ? UInt16(b[i]) | UInt16(b[i + 1]) << 8 : UInt16(b[i]) << 8 | UInt16(b[i + 1])
            if u == 0 { break }
            units.append(u)
            i += 2
        }
        guard !units.isEmpty else { return nil }
        return quote(String(decoding: units, as: UTF16.self))
    }

    /// Control and bidi characters made visible so one value stays one line
    /// and cannot steer a terminal.
    private static func quote(_ s: String) -> String {
        "\"" + TerminalText.escape(s) + "\""
    }
}

extension String {
    func leftPadded(to n: Int, with c: Character = "0") -> String {
        count >= n ? self : String(repeating: c, count: n - count) + self
    }
}

extension InspectorValue {
    /// Localized label for display; `name` is the stable identifier used by
    /// `Inspector.encode` and the app's grouping.
    public var title: String { Inspector.title(of: name) }
}

extension Inspector {
    public static func title(of id: String) -> String {
        switch id {
        case "binary": L("binary")
        case "Unix time 32": L("Unix time 32")
        case "Unix time 64": L("Unix time 64")
        case "DOS date/time": L("DOS date/time")
        default: id     // type names like int32, GUID, UTF-8 are not translated
        }
    }
}
