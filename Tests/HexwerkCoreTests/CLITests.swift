import Foundation
import Testing
@testable import HexwerkCore

/// The command line tools as a user runs them (SPEC FR-8.3/8.4).
@Suite struct CLITests {
    static let exe = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".build/debug/hexwerk")

    func run(_ args: [String]) throws -> (Int32, String) {
        try #require(FileManager.default.isExecutableFile(atPath: Self.exe.path))
        let p = Process()
        p.executableURL = Self.exe
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, text)
    }

    /// Only the failure path: a real `open` would launch the app.
    @Test func openRejectsMissingFilesAndFolders() throws {
        #expect(try run(["open", "/nonexistent/hexwerk-file.bin"]).0 != 0)
        #expect(try run(["open", FileManager.default.temporaryDirectory.path]).0 != 0)
    }

    @Test func hashMatchesShasumAndCrc() throws {
        let url = try tempFile(Data("123456789".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let (s, out) = try run(["hash", "--algo", "crc32,sha-256,crc-16/modbus", "--json", url.path])
        #expect(s == 0)
        let obj = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: String]
        #expect(obj?["crc32"] == "cbf43926")
        #expect(obj?["crc-16/modbus"] == "4b37")
        #expect(obj?["sha-256"] == "15e2b0d3c33891ebb0f1ef609ec419420c20e320ce94c65fbc8c3312448eb225")
        #expect(try run(["hash", "--algo", "nope", url.path]).0 == 64)
    }

    @Test func diffReportsRangesAndExitCode() throws {
        let a = try tempFile(Data([0, 1, 2, 3, 4, 5, 6, 7]))
        let b = try tempFile(Data([0, 1, 9, 9, 4, 5, 6, 7, 8]))
        let c = try tempFile(Data([0, 1, 2, 3, 4, 5, 6, 7]))
        defer { for u in [a, b, c] { try? FileManager.default.removeItem(at: u) } }
        let (s1, out) = try run(["diff", "--json", a.path, b.path])
        #expect(s1 == 1)
        let ranges = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [[String: Any]]
        #expect(ranges?.count == 2)
        #expect(try run(["diff", a.path, c.path]).0 == 0)
    }
}
