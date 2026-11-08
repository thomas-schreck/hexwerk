import Foundation
import Testing

/// The script time limit in the signed release CLI (#131). Only a binary
/// signed with the allow-jit entitlement JIT-compiles scripts, and only
/// compiled loops ignored the limit, so the debug build cannot show this.
/// Runs after `make sign-cli`; skipped without a signed release build,
/// unless HEXWERK_REQUIRE_SIGNED_CLI=1 (CI), which turns a missing or
/// unsigned binary into a failure.
@Suite struct SignedScriptTimeoutTests {
    static let exe = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".build/release/hexwerk")

    /// True if `exe` exists and is signed with com.apple.security.cs.allow-jit.
    static let signedWithJIT: Bool = {
        guard FileManager.default.isExecutableFile(atPath: exe.path) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-d", "--entitlements", "-", "--xml", exe.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).contains("com.apple.security.cs.allow-jit")
    }()

    static let required = ProcessInfo.processInfo.environment["HEXWERK_REQUIRE_SIGNED_CLI"] == "1"

    @Test(
        .enabled(if: signedWithJIT || required, "needs a signed release build (make sign-cli)"),
        arguments: ["while (true) {}", "let i = 0; for (;;) { i++ }"])
    func endlessLoopStopsAtTheLimit(_ source: String) throws {
        try #require(Self.signedWithJIT, "\(Self.exe.path) is missing or not signed with allow-jit")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hexwerk-\(UUID().uuidString)")
        try Data([1, 2, 3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let p = Process()
        p.executableURL = Self.exe
        p.arguments = ["script", "--timeout", "1", "-e", source, file.path]
        p.environment = ["HEXWERK_LANG": "en"]
        let err = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        let t0 = Date()
        try p.run()
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        // Without the fix the child is only killed after limit + 15 s.
        #expect(Date().timeIntervalSince(t0) < 6)
        #expect(p.terminationStatus == 3)
        #expect(message.contains("Time limit of 1 s exceeded"), "\(message)")
    }
}
