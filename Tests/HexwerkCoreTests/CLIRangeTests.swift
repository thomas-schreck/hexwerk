import Foundation
import Testing
import HexwerkCore

/// Offsets and lengths from the command line are untrusted input: values past
/// the end of the file or near UInt64.max must give an error, never a trap.
extension CLITests {
    @Test func hashRejectsOffsetPastEndAndClampsHugeLength() throws {
        let url = try tempFile(Data("12345678".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try run(["hash", "--offset", "100", url.path]).0 == 1)
        let (s, out) = try run([
            "hash", "--algo", "crc32", "--json", "--offset", "1",
            "--length", "0xffffffffffffffff", url.path,
        ])
        #expect(s == 0)
        // CRC-32 of "2345678".
        #expect(out.contains(Checksum.compute(.crc32, Data("2345678".utf8))))
    }
}
