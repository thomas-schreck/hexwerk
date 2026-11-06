import Foundation
import Testing
@testable import HexwerkCore

/// `offset + length` near UInt64.max must clamp to the end of the file, not trap.
extension CLITests {
    @Test func hugeLengthIsClampedNotOverflowed() throws {
        let url = try tempFile(Data("12345678".utf8))
        let rules = try tempFile(Data("rule always { condition: true }".utf8))
        defer { for u in [url, rules] { try? FileManager.default.removeItem(at: u) } }
        let huge = ["--offset", "1", "--length", "0xffffffffffffffff"]

        let (s1, dump) = try run(["dump"] + huge + [url.path])
        #expect(s1 == 0)
        #expect(dump.contains("|2345678|"))
        let (s2, export) = try run(["export", "--format", "base64"] + huge + [url.path])
        #expect(s2 == 0)
        #expect(export.trimmingCharacters(in: .whitespacesAndNewlines) == Data("2345678".utf8).base64EncodedString())
        let (s3, yara) = try run(["yara"] + huge + [rules.path, url.path])
        #expect(s3 == 0)
        #expect(yara.contains("always"))
    }

    @Test func documentOverwriteAtMaxOffsetThrows() throws {
        let url = try tempFile(Data([1, 2, 3]))
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try Document(url: url)
        #expect(throws: DocumentError.self) { try doc.overwrite(at: .max, with: Data([1, 2])) }
        #expect(doc.read(0..<3) == Data([1, 2, 3]))
    }
}
