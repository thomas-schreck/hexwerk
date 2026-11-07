import Foundation
import Testing
@testable import HexwerkCore
@testable import HexwerkHelper
import HexwerkKaitai
import HexwerkMagic
import HexwerkYARA

/// The CLI's sandboxed child process (#129) and libmagic in the app's helper.
/// The child is the built CLI (`swift build` first, like the CLI tests).
@Suite struct SandboxTests {
    static let child = SandboxedChild(executable: CLITests.exe.path)

    private func requireCLI() throws {
        try #require(FileManager.default.isExecutableFile(atPath: CLITests.exe.path), "swift build missing")
    }

    /// What a compromised parser would try: read the user's files, write
    /// one, connect somewhere. All fail with EPERM, the sandbox's answer.
    @Test func childCannotOpenFilesOrSockets() throws {
        try requireCLI()
        let secret = try tempFile(Data("secret".utf8))
        defer { try? FileManager.default.removeItem(at: secret) }
        #expect(FileHandle(forReadingAtPath: secret.path) != nil)  // readable outside the sandbox
        #expect(try Self.child.probe("open:" + secret.path) == "errno \(EPERM)")
        #expect(try Self.child.probe("open:" + NSHomeDirectory()) == "errno \(EPERM)")
        let target = secret.deletingLastPathComponent().appendingPathComponent("hexwerk-\(UUID().uuidString)")
        #expect(try Self.child.probe("write:" + target.path) == "errno \(EPERM)")
        #expect(!FileManager.default.fileExists(atPath: target.path))
        // Creating a socket is not mediated by macOS's sandbox; using one is.
        // Outside the sandbox the same connects fail with ECONNREFUSED/ENOENT.
        #expect(try Self.child.probe("connect:9") == "errno \(EPERM)")
        #expect(try Self.child.probe("connect:/var/run/syslog") == "errno \(EPERM)")
    }

    @Test func crashingChildIsAnError() throws {
        try requireCLI()
        #expect {
            try Self.child.probe("crash")
        } throws: { ($0 as? SandboxedChildError).map { if case .stopped = $0 { true } else { false } } ?? false }
    }

    @Test func hangingChildIsKilledAtItsTimeout() throws {
        try requireCLI()
        let start = Date()
        #expect {
            try Self.child.probe("hang", timeout: 0.5, grace: 0)
        } throws: { ($0 as? SandboxedChildError).map { if case .timedOut = $0 { true } else { false } } ?? false }
        #expect(Date().timeIntervalSince(start) < 10)
    }

    /// Through the CLI: a crash is a message and status 1, not a crash.
    @Test func sandboxedChildErrorReadsCleanly() {
        #expect(SandboxedChildError.stopped.description.contains("stopped unexpectedly"))
        #expect(SandboxedChildError.timedOut.description.contains("did not answer in time"))
    }

    static let png = Data(
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 0, 0, 0, 53, 0, 0, 0, 37, 8, 6, 0, 0, 0]
            + [UInt8](repeating: 0, count: 64))

    private func snapshot(_ data: Data) throws -> (Snapshot, URL) {
        let url = try tempFile(data)
        return (try Document(url: url, readOnly: true).snapshot(), url)
    }

    @Test func childTypeEqualsInProcess() throws {
        try requireCLI()
        let db = try #require(Magic.databasePath)
        let (snap, url) = try snapshot(Self.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let t = try Self.child.detectType(snap, database: URL(fileURLWithPath: db))
        #expect(t.description == Magic.describe(snap) && t.description?.hasPrefix("PNG image data, 53 x 37") == true)
        #expect(t.mime == Magic.mime(snap))
        #expect(try Self.child.detectType(snap, database: nil) == TypeOutcome(description: nil, mime: nil))
    }

    /// The app's libmagic request (#129) over the helper's XPC path.
    @Test func helperTypeEqualsInProcess() async throws {
        let db = try #require(Magic.databasePath)
        let (snap, url) = try snapshot(Self.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let client = HelperClient.inProcess()
        let t = try await client.detectType(snap, database: URL(fileURLWithPath: db))
        #expect(t.description == Magic.describe(snap) && t.mime == Magic.mime(snap))
        #expect(t.description?.hasPrefix("PNG image data") == true)
        // A second request reuses the database the helper loaded.
        #expect(try await client.detectType(snap, database: URL(fileURLWithPath: db)) == t)
        #expect(try await client.detectType(snap, database: nil) == TypeOutcome(description: nil, mime: nil))
    }

    @Test func magicDatabaseFromMemoryMatchesFile() throws {
        let db = try #require(Magic.databasePath)
        let (snap, url) = try snapshot(Self.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let mem = try #require(MagicDatabase(try Data(contentsOf: URL(fileURLWithPath: db))))
        #expect(mem.describe(Magic.sample(snap)) == Magic.describe(snap))
        #expect(mem.mime(Magic.sample(snap)) == Magic.mime(snap))
        #expect(MagicDatabase(Data()) == nil)
        #expect(MagicDatabase(Data("not a database".utf8))?.describe(Magic.sample(snap)) == nil)
    }

    // MARK: The parsers in the child

    @Test func childParseEqualsInProcessAndAsksForImports() throws {
        try requireCLI()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hexwerk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ksy = dir.appendingPathComponent("main.ksy")
        try "meta: {id: main, imports: [part]}\nseq:\n  - {id: head, type: part}\n".write(to: ksy, atomically: true, encoding: .utf8)
        try "meta: {id: part, endian: le}\nseq:\n  - {id: n, type: u2}\n".write(
            to: dir.appendingPathComponent("part.ksy"), atomically: true, encoding: .utf8)
        let (snap, url) = try snapshot(Data([0x34, 0x12, 0xFF]))
        defer { try? FileManager.default.removeItem(at: url) }
        let local = KaitaiInterpreter.parse(snap, file: try KsyLoader().load(ksy))
        guard case .result(let remote) = try Self.child.parse(snap, ksy: ksy, libraryRoots: []) else {
            Issue.record("no parse result")
            return
        }
        #expect(WireTests.lines(remote) == WireTests.lines(local))
        guard case .loaded = try Self.child.parse(nil, ksy: ksy, libraryRoots: []) else {
            Issue.record("load only")
            return
        }
        guard case .loadError = try Self.child.parse(snap, ksy: dir.appendingPathComponent("missing.ksy"), libraryRoots: []) else {
            Issue.record("missing .ksy")
            return
        }
    }

    /// YARA-X (wasmtime) runs under the profile, includes resolve in the scratch folder.
    /// Rules below /private/var (the real path of /var): includes must keep
    /// that spelling, or they are written where YARA-X does not look.
    @Test func childScanFindsMatchesAndFollowsIncludes() throws {
        try requireCLI()
        let tmp = FileManager.default.temporaryDirectory.path
        let dir = URL(fileURLWithPath: (tmp.hasPrefix("/var/") ? "/private" : "") + tmp)
            .appendingPathComponent("hexwerk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let main = dir.appendingPathComponent("main.yar")
        try "include \"inc.yar\"\nrule a { strings: $s = \"HW\" condition: $s }\n".write(to: main, atomically: true, encoding: .utf8)
        try "rule b { condition: filesize > 2 }\n".write(to: dir.appendingPathComponent("inc.yar"), atomically: true, encoding: .utf8)
        let (snap, url) = try snapshot(Data("..HW..".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let bundle = try YaraRuleBundle.collect(files: [main])
        #expect(bundle.includes.map(\.path) == [dir.appendingPathComponent("inc.yar").path])
        guard case .hits(let hits, _) = try Self.child.scan(snap, rules: bundle, range: nil, timeout: 10) else {
            Issue.record("no hits")
            return
        }
        #expect(hits.map(\.rule).sorted() == ["a", "b"])
        #expect(hits.first { $0.rule == "a" }?.matches.first?.offset == 2)
        try "rule {".write(to: main, atomically: true, encoding: .utf8)
        guard case .compileErrors = try Self.child.scan(nil, rules: try YaraRuleBundle.collect(files: [main]), range: nil, timeout: 10)
        else {
            Issue.record("compile error expected")
            return
        }
    }

    @Test func childScriptEditsComeBack() throws {
        try requireCLI()
        let url = try tempFile(Data([1, 2, 3, 4]))
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try Document(url: url)
        let base = doc.snapshot()
        let (outcome, map) = try Self.child.runScript(
            "print(hw.hex(0, 4), hw.fileName); hw.write(1, [9])", name: "t.js", base: base, fileName: "f.bin", timeout: 10)
        #expect(outcome.result.output == ["01 02 03 04 f.bin"] && outcome.result.error == nil)
        try doc.adopt(try #require(outcome.edited), map: map, base: base)
        #expect(doc.read(0 ..< doc.count) == Data([1, 9, 3, 4]))
    }

    /// The profile quotes the scratch path as an SBPL string.
    @Test func profileEscapesScratchPath() {
        #expect(Sandbox.literal(#"/a"b\c"#) == #""/a\"b\\c""#)
        #expect(!Sandbox.profile(scratch: nil).contains("file-write"))
        #expect(!Sandbox.profile(scratch: nil).contains("network"))
        let withScratch = Sandbox.profile(scratch: "/tmp/x/y")
        #expect(withScratch.contains(#"(allow file-read* file-write* (subpath "/tmp/x/y"))"#))
        #expect(withScratch.contains(#"(allow file-read-metadata (literal "/tmp/x") (literal "/tmp") (literal "/"))"#))
    }
}
