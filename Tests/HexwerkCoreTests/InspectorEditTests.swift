import Foundation
import Testing
@testable import HexwerkCore

@Suite struct InspectorEditTests {
    /// Encoding a value and reading it back shows the same value.
    @Test func roundTrips() throws {
        let cases: [(String, String)] = [
            ("int8", "-128"), ("uint8", "255"), ("int16", "-2"), ("uint16", "0xBEEF"), ("int32", "-123456"),
            ("uint32", "4000000000"), ("int64", "-9223372036854775808"), ("uint64", "18446744073709551615"),
            ("float32", "1.5"), ("float64", "-0.1"), ("binary", "10100101"),
            ("Unix time 32", "2026-11-06T09:30:00Z"), ("Unix time 64", "1969-07-20T20:17:40Z"),
            ("FILETIME", "2001-09-09T01:46:40Z"), ("DOS date/time", "2026-11-06 09:30:42"),
            ("GUID", "{01234567-89AB-CDEF-0123-456789ABCDEF}"),
            ("ULEB128", "624485"), ("SLEB128", "-123456"), ("ASCII", "\"Hallo\""), ("UTF-8", "\"Grüße\""),
            ("UTF-16 LE", "\"Käse\""), ("UTF-16 BE", "\"Käse\""),
        ]
        for endian in Endian.allCases {
            for (name, text) in cases {
                let bytes = try Inspector.encode(name, text, endian: endian) + Data(repeating: 0, count: 16)
                let shown = Inspector.values(bytes, endian: endian).first { $0.name == name }?.value
                let expected: String = switch name {
                case "uint16": "48879"
                case "ULEB128": "624485 (3 Byte)"
                case "SLEB128": "-123456 (3 Byte)"
                default: text
                }
                #expect(shown == expected, "\(name) \(endian): \(shown ?? "nil")")
            }
        }
    }

    /// Int64.min under the cursor used to trap in abs() (Unix time 64).
    @Test func extremeValuesDoNotCrash() {
        for bytes in [Data(repeating: 0, count: 7) + Data([0x80]), Data(repeating: 0xFF, count: 16), Data([0x80]) + Data(repeating: 0, count: 15)] {
            for e in Endian.allCases { _ = Inspector.values(bytes, endian: e) }
        }
    }

    @Test func knownEncodings() throws {
        #expect(try Inspector.encode("uint32", "0x12345678", endian: .little) == Data([0x78, 0x56, 0x34, 0x12]))
        #expect(try Inspector.encode("uint32", "0x12345678", endian: .big) == Data([0x12, 0x34, 0x56, 0x78]))
        #expect(try Inspector.encode("ULEB128", "624485", endian: .little) == Data([0xE5, 0x8E, 0x26]))
        #expect(try Inspector.encode("SLEB128", "-123456", endian: .little) == Data([0xC0, 0xBB, 0x78]))
    }

    @Test func rejectsBadInput() {
        for (n, t) in [("int8", "128"), ("uint8", "-1"), ("uint16", "65536"), ("int32", "abc"), ("binary", "102"),
                       ("ASCII", "ä"), ("GUID", "{123}"), ("Unix time 32", "gestern"), ("DOS date/time", "1970-01-01")] {
            #expect(throws: Inspector.EncodeError.self, "\(n) \(t)") { try Inspector.encode(n, t, endian: .little) }
        }
    }
}
