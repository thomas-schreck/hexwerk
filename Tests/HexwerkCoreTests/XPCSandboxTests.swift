import Foundation
import Synchronization
import Testing
@testable import HexwerkHelper
import HexwerkMagic

/// The app's XPC helper under its real App Sandbox (#134): the probes of
/// `SandboxTests`, run inside the signed service that `make sandbox-probes`
/// builds (the helper's code with the probes exported, signed with
/// `Resources/Parser.entitlements` exactly like the one in hexwerk.app).
/// An XPC service can only be reached from its own bundle, so the tests run
/// the bundle's host executable, which prints one answer per command.
/// Skipped without the bundle (plain `swift test`).
@Suite(.enabled(if: ProbeBundle.available, "make sandbox-probes first"))
struct XPCSandboxTests {
    static let root = ProbeBundle.root
    static let host = ProbeBundle.host
    static let service = ProbeBundle.bundle.appendingPathComponent(
        "Contents/XPCServices/de.schreck-thomas.hexwerk.Parser.probes.xpc")

    /// One answer per command (see Sources/HexwerkProbeHost); `%HOST%` is
    /// the host's pid, `%TMP%` the service's temporary folder.
    private func run(_ commands: [String]) throws -> [String] {
        let p = Process()
        p.executableURL = Self.host
        p.arguments = commands
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        try #require(lines.count == commands.count, "host answered \(lines)")
        return lines.map(String.init)
    }

    private func probe(_ commands: String...) throws -> [String] { try run(commands) }

    /// The tested service is signed with the entitlements in the repository,
    /// and so is the helper in dist/hexwerk.app if `make app` built one.
    @Test func serviceHasTheHelpersEntitlements() throws {
        let expected = try #require(
            NSDictionary(contentsOf: Self.root.appendingPathComponent("Resources/Parser.entitlements")))
        #expect(try Self.entitlements(Self.service) == expected)
        let app = Self.root.appendingPathComponent("dist/hexwerk.app/Contents/XPCServices/de.schreck-thomas.hexwerk.Parser.xpc")
        if FileManager.default.fileExists(atPath: app.path) {
            #expect(try Self.entitlements(app) == expected)
        }
    }

    static func entitlements(_ bundle: URL) throws -> NSDictionary? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-d", "--entitlements", "-", "--xml", bundle.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return try PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary
    }

    /// No user files, no files outside the container, no sockets. The
    /// container's temporary folder is writable (YARA writes its rules there).
    @Test func helperCannotOpenFilesOrSockets() throws {
        let secret = try tempFile(Data("secret".utf8))
        defer { try? FileManager.default.removeItem(at: secret) }
        let target = secret.deletingLastPathComponent().appendingPathComponent("hexwerk-\(UUID().uuidString)")
        var r = try probe(
            "open:" + secret.path, "open:" + NSHomeDirectory() + "/.zshrc", "list:" + NSHomeDirectory(),
            "write:" + target.path, "write:/tmp/hexwerk-\(UUID().uuidString)", "write:%TMP%/probe",
            "connect:9", "connect:/var/run/mDNSResponder",
            // Allowed by the App Sandbox, denied by the entitlements.
            "connect:/var/run/syslog", "open:/etc/hosts", "list:/Applications", "list:/Volumes",
            "open:/Library/Preferences/SystemConfiguration/preferences.plist")
        #expect(r[5] == "opened")
        r.remove(at: 5)
        #expect(r == Array(repeating: "errno \(EPERM)", count: 12), "\(r)")
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    /// The App Sandbox alone allows most of these (not signals, the pid
    /// list or rusage of others); the helper's entitlements deny the rest on
    /// top (`temporary-exception.sbpl`).
    @Test func helperCannotReachProcessesOrHardware() throws {
        let r = try probe(
            "fork", "exec:/usr/bin/true", "signal-parent:%HOST%", "procargs:%HOST%", "procall",
            "pidpath:%HOST%", "pidinfo:%HOST%", "listpids", "rusage:%HOST%", "iokit", "mach:com.apple.cfprefsd.daemon",
            "mach:com.apple.system.notification_center", "mach:com.apple.pasteboard.1",
            "mach:com.apple.windowserver.active", "mach:com.apple.tccd")
        #expect(Array(r[0 ..< 9]) == Array(repeating: "errno \(EPERM)", count: 9), "\(r)")
        #expect(r[9] == "denied")
        #expect(r[10...].allSatisfy { $0 != "found" }, "\(r[10...])")
    }

    /// Parse (with an import answered by the host), libmagic, YARA-X and a
    /// script work under that sandbox, and leave no descriptor behind.
    @Test func helperStillParsesScansAndRunsScripts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hexwerk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func file(_ name: String, _ text: String) throws -> String {
            let url = dir.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }
        let doc = dir.appendingPathComponent("doc.bin").path
        try (SandboxTests.png + Data("HW".utf8)).write(to: URL(fileURLWithPath: doc))
        let ksy = try file("main.ksy", "meta: {id: main, imports: [part]}\nseq:\n  - {id: head, type: part}\n")
        _ = try file("part.ksy", "meta: {id: part, endian: le}\nseq:\n  - {id: n, type: u2}\n")
        let yar = try file(
            "r.yar",
            "import \"math\"\nrule a { strings: $s = /H[A-Z]/ condition: $s and math.entropy(0, filesize) > 0 }\n"
                + "rule b { condition: false }\n")
        let js = try file(
            "s.js", "print(hw.hex(0, 4), hw.fileName, new Date(0).toISOString(), new Intl.NumberFormat('de-DE').format(1234.5))")
        let magic = try #require(Magic.databasePath)
        let r = try probe("@type:\(doc):\(magic)", "@parse:\(doc):\(ksy)", "@scan:\(doc):\(yar)", "@script:\(doc):\(js)", "fds")
        #expect(r[0].hasPrefix("PNG image data, 53 x 37"))
        #expect(r[1] == "fields head")
        #expect(r[2] == "rules a")
        #expect(r[3] == "89 50 4E 47 doc.bin 1970-01-01T00:00:00.000Z 1.234,5")
        #expect(r[4] == "0,1,2")
    }
}

enum ProbeBundle {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let bundle = root.appendingPathComponent(".build/sandbox-probes/hexwerk-probes.app")
    static let host = bundle.appendingPathComponent("Contents/MacOS/HexwerkProbeHost")
    static var available: Bool { FileManager.default.isExecutableFile(atPath: host.path) }
}

/// The probes are no attack surface of the shipped helper (#134): its
/// listener does not export them, so NSXPC rejects a probe message and the
/// caller's error handler fires; with probes exported, the probe answers.
/// Both outcomes are waited for explicitly (the deadline only guards
/// against a hang), so a slow, loaded machine cannot turn one into the other.
@Suite struct HelperProbeExportTests {
    enum Outcome: Equatable { case answered, rejected, noReply }

    private func probe(listener delegate: HelperListener) -> Outcome {
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        let c = NSXPCConnection(listenerEndpoint: listener.endpoint)
        c.remoteObjectInterface = NSXPCInterface(with: HelperProbeXPC.self)
        c.resume()
        defer { c.invalidate(); listener.invalidate() }
        let done = DispatchSemaphore(value: 0)
        let outcome = Mutex(Outcome.noReply)
        @Sendable func finish(_ o: Outcome) {
            let first = outcome.withLock { cur in
                guard cur == .noReply else { return false }
                cur = o
                return true
            }
            if first { done.signal() }
        }
        let proxy = c.remoteObjectProxyWithErrorHandler { _ in finish(.rejected) } as? HelperProbeXPC
        proxy?.probe("fds") { _ in finish(.answered) }
        _ = done.wait(timeout: .now() + 120)
        return outcome.withLock { $0 }
    }

    @Test func shippedListenerDoesNotExportProbes() {
        #expect(probe(listener: HelperListener()) == .rejected)
        #expect(probe(listener: HelperListener(probes: true)) == .answered)
    }
}
