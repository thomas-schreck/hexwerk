import Foundation
import Testing

/// Issue #22: `convert --base` past 32 bits is an error, not truncation or a trap.
extension CLITests {
    @Test func convertRejectsBaseBeyond32Bits() throws {
        let bin = try tempFile(Data([1, 2, 3, 4]))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("hexwerk-\(UUID().uuidString).hex")
        defer { for u in [bin, out] { try? FileManager.default.removeItem(at: u) } }
        #expect(try run(["convert", "--from", "bin", "--base", "0x100000000", bin.path, out.path]).0 == 2)
        #expect(try run(["convert", "--from", "bin", "--base", "0xfffffffffffffffc", bin.path, out.path]).0 == 2)
        #expect(!FileManager.default.fileExists(atPath: out.path))
        #expect(try run(["convert", "--from", "bin", "--base", "0xfffffffc", bin.path, out.path]).0 == 0)
    }
}
