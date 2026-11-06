import Foundation
import Testing
@testable import HexwerkCore

@Suite struct StringsTests {
    private func snap(_ d: Data) throws -> (Snapshot, URL) {
        let url = try tempFile(d)
        return (try Document(url: url).snapshot(), url)
    }

    @Test func asciiUtf8AndUtf16() throws {
        var d = Data([0x00, 0x01])
        d += Data("Hallo Welt".utf8)                        // ASCII at 2
        d += Data([0xFF, 0x00, 0x00])
        d += Data("Grüße aus München".utf8)                 // UTF-8 at 15
        d += Data([0x00, 0x07])
        d += Data("Käse".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })   // UTF-16LE at odd offset
        d += Data([0x00, 0x00])
        d += Data("abc".utf8)                               // too short
        let (s, url) = try snap(d)
        defer { try? FileManager.default.removeItem(at: url) }

        let ascii = Strings.find(s, encodings: [.ascii])
        #expect(ascii.map(\.text).contains("Hallo Welt"))
        #expect(ascii.first?.offset == 2 && ascii.first?.length == 10)
        #expect(!ascii.contains { $0.text == "abc" })

        let utf8 = Strings.find(s, encodings: [.utf8])
        let g = try #require(utf8.first { $0.text == "Grüße aus München" })
        #expect(g.offset == 15 && g.length == UInt64("Grüße aus München".utf8.count))

        let utf16Off = UInt64(15 + "Grüße aus München".utf8.count + 2)
        #expect(utf16Off % 2 == 1)
        let w = Strings.find(s, encodings: [.utf16le])
        #expect(w.contains { $0.text == "Käse" && $0.offset == utf16Off && $0.length == 8 })
    }

    @Test func runsCrossChunkBordersAndLimits() throws {
        // A string straddling the 4 MiB chunk border.
        var d = Data(repeating: 0, count: (4 << 20) - 5)
        d += Data("BORDERSTRING".utf8)
        d += Data(repeating: 0, count: 10)
        let (s, url) = try snap(d)
        defer { try? FileManager.default.removeItem(at: url) }
        let f = Strings.find(s, encodings: [.ascii, .utf8])
        #expect(f.count == 1)
        #expect(f.first?.text == "BORDERSTRING" && f.first?.offset == UInt64((4 << 20) - 5))
        #expect(Strings.find(s, minLength: 13).isEmpty)
    }

    @Test func regexOverBytes() throws {
        var d = Data("xx user@example.org yy ".utf8)
        d += Data([0x7F, 0x45, 0x4C, 0x46, 0x02])
        d += Data(repeating: 0x41, count: 10)
        let (s, url) = try snap(d)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try RegexSearch.find("[a-z]+@[a-z.]+", in: s) == [3 ..< 19])
        #expect(try RegexSearch.find("\\x7fELF[\\x01\\x02]", in: s) == [23 ..< 28])
        #expect(try RegexSearch.find("a{3}", ignoreCase: true, in: s).count == 3)
        #expect(throws: (any Error).self) { try RegexSearch.find("(", in: s) }
    }

    @Test func regexAcrossChunkBorderWithoutDuplicates() throws {
        var d = Data(repeating: 0x2E, count: (4 << 20) - 3)
        d += Data("NEEDLE".utf8)
        d += Data(repeating: 0x2E, count: 5000)
        d += Data("NEEDLE".utf8)
        let (s, url) = try snap(d)
        defer { try? FileManager.default.removeItem(at: url) }
        let hits = try RegexSearch.find("NEE+DLE", in: s)
        #expect(hits == [UInt64((4 << 20) - 3) ..< UInt64((4 << 20) + 3), UInt64((4 << 20) + 5003) ..< UInt64((4 << 20) + 5009)])
    }
}
