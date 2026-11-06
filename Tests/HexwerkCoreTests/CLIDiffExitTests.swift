import Foundation
import Testing

/// Issue #25: like cmp/diff, 1 means "different" and errors are 2.
extension CLITests {
    @Test func diffExitsTwoOnErrors() throws {
        let a = try tempFile(Data([1, 2, 3]))
        defer { try? FileManager.default.removeItem(at: a) }
        #expect(try run(["diff", a.path, "/nonexistent/hexwerk-missing.bin"]).0 == 2)
        #expect(try run(["diff", "/nonexistent/hexwerk-missing.bin", a.path]).0 == 2)
        #expect(try run(["diff", a.path, FileManager.default.temporaryDirectory.path]).0 == 2)
        #expect(try run(["diff", a.path, a.path]).0 == 0)
    }
}
