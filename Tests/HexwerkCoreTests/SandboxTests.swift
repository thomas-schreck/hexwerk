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

    /// Processes: no fork, exec, mach services, signals to the parent, and
    /// nothing about other processes or the machine (#129 review).
    @Test func childCannotReachProcessesOrHardware() throws {
        try requireCLI()
        let me = getpid()
        #expect(try Self.child.probe("fork") == "errno \(EPERM)")
        #expect(try Self.child.probe("exec:/usr/bin/true") == "errno \(EPERM)")
        #expect(try Self.child.probe("mach:com.apple.cfprefsd.daemon") != "found")
        #expect(try Self.child.probe("mach:com.apple.system.notification_center") != "found")
        #expect(try Self.child.probe("signal-parent") == "errno \(EPERM)")
        #expect(try Self.child.probe("procargs:\(me)") == "errno \(EPERM)")
        #expect(try Self.child.probe("procall") == "errno \(EPERM)")
        #expect(try Self.child.probe("pidpath:\(me)") == "errno \(EPERM)")
        #expect(try Self.child.probe("pidinfo:\(me)") == "errno \(EPERM)")
        #expect(try Self.child.probe("listpids") == "errno \(EPERM)")
        #expect(try Self.child.probe("rusage:\(me)") == "errno \(EPERM)")
        #expect(try Self.child.probe("iokit") == "denied")
    }

    /// Only the pipes reach the child (and, in real requests, descriptors 3 and 4).
    @Test func childInheritsNoOtherDescriptors() throws {
        try requireCLI()
        let devNull = open("/dev/null", O_RDONLY)
        let leaked = fcntl(devNull, F_DUPFD, 10)  // not close-on-exec
        close(devNull)
        defer { close(leaked) }
        #expect(leaked >= 10)
        #expect(try Self.child.probe("fds") == "0,1,2")
    }

    /// The scan's profile: its scratch folder is writable, nothing else.
    @Test func scratchProfileAllowsOnlyItsFolder() throws {
        try requireCLI()
        #expect(try Self.child.probe("write:%SCRATCH%/rules.yar", scratch: true) == "opened")
        #expect(try Self.child.probe("list:%SCRATCH%", scratch: true) == "listed")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hexwerk-\(UUID().uuidString)")
        #expect(try Self.child.probe("write:" + tmp.path, scratch: true) == "errno \(EPERM)")
        #expect(!FileManager.default.fileExists(atPath: tmp.path))
        let secret = try tempFile(Data("secret".utf8))
        defer { try? FileManager.default.removeItem(at: secret) }
        #expect(try Self.child.probe("open:" + secret.path, scratch: true) == "errno \(EPERM)")
        // The folders above the scratch folder: metadata only, no listing.
        #expect(try Self.child.probe("stat:/private", scratch: true) == "ok")
        #expect(try Self.child.probe("list:/private", scratch: true) == "errno \(EPERM)")
        #expect(try Self.child.probe("list:" + NSHomeDirectory(), scratch: true) == "errno \(EPERM)")
        #expect(try Self.child.probe("fork", scratch: true) == "errno \(EPERM)")
    }

    // MARK: Hostile children

    /// A stand-in for a compromised child: a shell script started like the
    /// real one, writing `frames` (printf format) to its stdout.
    private func hostileChild(_ body: String) throws -> (SandboxedChild, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hexwerk-hostile-\(UUID().uuidString).sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
        return (SandboxedChild(executable: url.path), url)
    }

    private func isTimeout(_ e: any Error) -> Bool {
        if case .timedOut? = e as? SandboxedChildError { true } else { false }
    }

    private func isTooLarge(_ e: any Error) -> Bool {
        if case .tooLarge? = e as? SandboxedChildError { true } else { false }
    }

    private func isStopped(_ e: any Error) -> Bool {
        if case .stopped? = e as? SandboxedChildError { true } else { false }
    }

    /// A child that asks for files without end and never reads the answers
    /// fills the pipe; the parent's writes must still end at the deadline.
    @Test func floodingChildThatNeverReadsTimesOut() throws {
        let (child, url) = try hostileChild(#"while :; do printf '\003\000\000\000\001a'; done"#)
        defer { try? FileManager.default.removeItem(at: url) }
        let start = Date()
        #expect(performing: { try child.probe("x", timeout: 1, grace: 0) }, throws: isTimeout)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    /// A frame header promising 1 GiB, then silence: a timeout, and the
    /// payload is not allocated up front. A file request that is too long
    /// for a path ends the request at once.
    @Test func oversizedFramesFromChild() throws {
        let (silent, a) = try hostileChild(#"printf '\001\100\000\000\000'; sleep 30"#)
        defer { try? FileManager.default.removeItem(at: a) }
        #expect(performing: { try silent.probe("x", timeout: 0.5, grace: 0) }, throws: isTimeout)
        let (big, b) = try hostileChild(#"printf '\003\000\020\000\000'; sleep 30"#)
        defer { try? FileManager.default.removeItem(at: b) }
        let start = Date()
        #expect(performing: { try big.probe("x", timeout: 20, grace: 0) }, throws: isStopped)
        #expect(Date().timeIntervalSince(start) < 10)
        // A result over 1 GiB is reported as such, not as a crash.
        let (huge, c) = try hostileChild(#"printf '\001\100\000\000\001'; sleep 30"#)
        defer { try? FileManager.default.removeItem(at: c) }
        #expect(performing: { try huge.probe("x", timeout: 20, grace: 0) }, throws: isTooLarge)
        #expect(SandboxedChildError.tooLarge.description.contains("1 GiB"))
    }

    /// A child that never reads its request (larger than the pipe buffer).
    @Test func childThatNeverReadsTheRequestTimesOut() throws {
        let (child, url) = try hostileChild("sleep 30")
        defer { try? FileManager.default.removeItem(at: url) }
        let start = Date()
        #expect(performing: { try child.probe(String(repeating: "x", count: 1 << 20), timeout: 0.5, grace: 0) }, throws: isTimeout)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    /// Compiling YARA rules has a budget of its own (it had no limit
    /// in-process); the scan's limit starts when the child reports the rules
    /// compiled.
    @Test func scanLimitStartsAfterCompiling() throws {
        let result = YaraScanOutcome.hits([], warnings: []).encoded()
        let frame = [UInt8(1), 0, 0, 0, UInt8(result.count)] + [UInt8](result)
        let octal = frame.map { String(format: "\\%03o", $0) }.joined()
        let bundle = try YaraRuleBundle.collect(files: [])
        // Compiling takes longer than the scan's limit and grace together.
        let (slow, a) = try hostileChild("sleep 2; printf '\\005\\000\\000\\000\\000'; printf '\(octal)'; sleep 30")
        defer { try? FileManager.default.removeItem(at: a) }
        guard case .hits = try slow.scan(nil, rules: bundle, range: nil, timeout: 1, grace: 0.2) else {
            Issue.record("no result")
            return
        }
        // After that, the scan's limit applies.
        let (stuck, b) = try hostileChild("printf '\\005\\000\\000\\000\\000'; sleep 30")
        defer { try? FileManager.default.removeItem(at: b) }
        let start = Date()
        #expect(performing: { try stuck.scan(nil, rules: bundle, range: nil, timeout: 1, grace: 0.2) }, throws: isTimeout)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    /// A killed CLI must not leave its child running (a script loop at full CPU).
    @Test func childExitsWhenTheCLIIsKilled() throws {
        try requireCLI()
        let file = try tempFile(Data([0]))
        defer { try? FileManager.default.removeItem(at: file) }
        let p = Process()
        p.executableURL = CLITests.exe
        p.arguments = ["script", "-e", "while (true) {}", file.path, "--timeout", "120"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        defer { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        var child: pid_t = 0
        for _ in 0 ..< 100 where child == 0 {
            var pids = [pid_t](repeating: 0, count: 16)
            let n = proc_listchildpids(p.processIdentifier, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
            if n > 0 { child = pids[0] } else { usleep(50_000) }
        }
        try #require(child > 0, "no child process")
        usleep(200_000)  // the child is in its loop
        kill(p.processIdentifier, SIGKILL)
        p.waitUntilExit()
        var gone = false
        for _ in 0 ..< 100 where !gone {
            gone = kill(child, 0) != 0 && errno == ESRCH
            if !gone { usleep(50_000) }
        }
        if !gone { kill(child, SIGKILL) }
        #expect(gone)
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
        let local = try Self.localMagic()
        let t = try Self.child.detectType(snap, database: URL(fileURLWithPath: db))
        #expect(t.description == local.describe(Magic.sample(snap)) && t.description?.hasPrefix("PNG image data, 53 x 37") == true)
        #expect(t.mime == local.mime(Magic.sample(snap)) && t.mime?.hasPrefix("image/png") == true)
        #expect(try Self.child.detectType(snap, database: nil) == TypeOutcome(description: nil, mime: nil))
    }

    /// The app's libmagic request (#129) over the helper's XPC path.
    @Test func helperTypeEqualsInProcess() async throws {
        let db = try #require(Magic.databasePath)
        let (snap, url) = try snapshot(Self.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let client = HelperClient.inProcess()
        let t = try await client.detectType(snap, database: URL(fileURLWithPath: db))
        let local = try Self.localMagic()
        #expect(t.description == local.describe(Magic.sample(snap)) && t.mime == local.mime(Magic.sample(snap)))
        #expect(t.description?.hasPrefix("PNG image data") == true)
        // A second request reuses the database the helper loaded.
        #expect(try await client.detectType(snap, database: URL(fileURLWithPath: db)) == t)
        #expect(try await client.detectType(snap, database: nil) == TypeOutcome(description: nil, mime: nil))
    }

    /// libmagic in this process, as the reference for the sandboxed ones.
    static func localMagic() throws -> MagicDatabase {
        let path = try #require(Magic.databasePath)
        return try #require(MagicDatabase(try Data(contentsOf: URL(fileURLWithPath: path))))
    }

    @Test func magicDatabaseFromMemory() throws {
        let (snap, url) = try snapshot(Self.png)
        defer { try? FileManager.default.removeItem(at: url) }
        let mem = try Self.localMagic()
        #expect(mem.describe(Magic.sample(snap))?.hasPrefix("PNG image data, 53 x 37") == true)
        #expect(mem.mime(Magic.sample(snap)) == "image/png; charset=binary")
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
        #expect(Sandbox.profile(scratch: nil).contains("(deny process-info*)"))
        #expect(Sandbox.profile(scratch: nil).contains("(deny iokit-get-properties)"))
        let withScratch = Sandbox.profile(scratch: "/tmp/x/y")
        #expect(withScratch.contains(#"(allow file-read* file-write* (subpath "/tmp/x/y"))"#))
        #expect(withScratch.contains(#"(allow file-read-metadata (literal "/tmp/x") (literal "/tmp") (literal "/"))"#))
    }
}
