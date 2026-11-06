import Foundation
import Testing
@testable import HexwerkCore

/// Hostile files must not be able to steer the terminal (issue #9).
@Suite struct TerminalTextTests {
    static let hostile = "A\u{1B}]0;pwned\u{07}\u{1B}[2J\u{9B}31m\u{202E}cod.exe\u{2066}\u{7F}"

    @Test func escapeMasksC0C1DelAndBidi() {
        let s = TerminalText.escape(Self.hostile)
        #expect(s == "A\\x1B]0;pwned\\x07\\x1B[2J\\x9B31m\\u{202E}cod.exe\\u{2066}\\x7F")
        #expect(!s.unicodeScalars.contains(where: TerminalText.isUnsafe))
        #expect(TerminalText.escape("Grüße C:\\tmp") == "Grüße C:\\tmp")
        #expect(TerminalText.escape("a\tb\nc", keepingLayout: true) == "a\tb\nc")
        #expect(TerminalText.escape("a\tb\u{1B}", keepingLayout: true) == "a\tb\\x1B")
    }

    @Test func escapeJSONStaysValidAndLossless() throws {
        let data = try JSONSerialization.data(withJSONObject: ["v": Self.hostile])
        let json = TerminalText.escapeJSON(String(decoding: data, as: UTF8.self))
        #expect(TerminalText.escapeJSON("{\n  \"a\" : 1\n}") == "{\n  \"a\" : 1\n}")
        #expect(!json.unicodeScalars.contains(where: TerminalText.isUnsafe))
        let back = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String]
        #expect(back?["v"] == Self.hostile)
    }

    @Test func inspectorQuotesC1AndBidi() {
        let bytes = Array("x\u{9B}2J\u{202E}y\0".utf8)
        let v = Inspector.values(Data(bytes), endian: .little).first { $0.name == "UTF-8" }?.value
        #expect(v == "\"x\\x9B2J\\u{202E}y\"")
    }

    @Test func cliStringsAndParseOutputIsEscaped() throws {
        let url = try tempFile(Data(Self.hostile.utf8) + Data([0]))
        let ksy = try tempFile(
            Data(
                """
                meta:
                  id: hostile
                seq:
                  - id: s
                    type: strz
                    encoding: UTF-8
                """.utf8))
        defer { for u in [url, ksy] { try? FileManager.default.removeItem(at: u) } }
        let cli = CLITests()
        let (s1, strings) = try cli.run(["strings", "-e", "utf8", "-n", "3", url.path])
        #expect(s1 == 0)
        let (s2, parse) = try cli.run(["parse", "--ksy", ksy.path, url.path])
        #expect(s2 == 0)
        let (s3, json) = try cli.run(["parse", "--json", "--ksy", ksy.path, url.path])
        #expect(s3 == 0)
        #expect(parse.contains("\\x1B]0;pwned"))
        for out in [strings, parse, json] {
            #expect(!out.unicodeScalars.contains { TerminalText.isUnsafe($0) && $0 != "\n" })
        }
    }
}
