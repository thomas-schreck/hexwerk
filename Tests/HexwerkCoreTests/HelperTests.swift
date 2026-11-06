import Foundation
import Testing
@testable import HexwerkCore
@testable import HexwerkHelper
@testable import HexwerkKaitai
import HexwerkScript

/// The sandboxed helper (#102): the XPC request path. The XPC service itself
/// only exists inside the app bundle; here the same code runs behind an
/// anonymous in-process listener. YARA scans cannot run in the test process
/// (see YaraTests); they were checked through the bundled service by hand.
@Suite struct HelperTests {
    let sample = Data((0 ..< 4096).map { UInt8(truncatingIfNeeded: $0 &* 7) })

    private func document(_ data: Data? = nil) throws -> (Document, URL) {
        let url = try tempFile(data ?? sample)
        return (try Document(url: url), url)
    }

    @Test func formatFileHostOnlyServesKsyFiles() throws {
        let ksy = FileManager.default.temporaryDirectory.appendingPathComponent("hexwerk-\(UUID().uuidString).ksy")
        try "meta: {id: x}".write(to: ksy, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: ksy) }
        #expect(FormatFileHost.read(ksy.path).0 == "meta: {id: x}")
        #expect(FormatFileHost.read(ksy.path + ".missing.ksy") == (nil, nil))
        #expect(FormatFileHost.read("/etc/passwd").0 == nil && FormatFileHost.read("/etc/passwd").1 != nil)
        #expect(FormatFileHost.read("relative.ksy").0 == nil)
        #expect(FormatFileHost.read("/dev").0 == nil)
    }

    // MARK: XPC path

    @Test func parseThroughHelperEqualsInProcess() async throws {
        let ksyURL = FileManager.default.temporaryDirectory.appendingPathComponent("hexwerk-\(UUID().uuidString).ksy")
        try WireTests.ksy.write(to: ksyURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: ksyURL) }
        let (doc, url) = try document(WireTests.ksyData)
        defer { try? FileManager.default.removeItem(at: url) }
        try doc.overwrite(at: 5, with: Data("Q".utf8))      // unsaved edit
        let local = KaitaiInterpreter.parse(doc.snapshot(), file: try KsyLoader().load(ksyURL), shouldContinue: { true })
        let remote = try await HelperClient.inProcess().parse(doc.snapshot(), ksy: ksyURL, libraryRoots: []).get()
        #expect(WireTests.lines(remote) == WireTests.lines(local))

        let missing = try await HelperClient.inProcess().parse(doc.snapshot(), ksy: ksyURL.appendingPathExtension("ksy"), libraryRoots: [])
        #expect(throws: KaitaiError.self) { try missing.get() }
    }

    @Test func scriptThroughHelperEqualsInProcess() async throws {
        let (doc, url) = try document()
        defer { try? FileManager.default.removeItem(at: url) }
        try doc.insert(Data("hi".utf8), at: 3)
        let source = "print(hw.hex(0, 6), hw.fileName); hw.write(1, [9, 9]); hw.remove(10, 5); hw.select(1, 3)"
        let ctx = ScriptContext(cursor: 2, selection: 1 ..< 2, fileName: "f.bin")
        let base = doc.snapshot()
        let (outcome, map) = try await HelperClient.inProcess().runScript(source, name: "t.js", base: base,
                                                                          context: ctx, readOnly: false)
        let local = Document(editing: base)
        let expected = ScriptRunner.run(source, document: local, context: ctx)
        #expect(outcome.result.output == expected.output && outcome.result.edits == expected.edits)
        #expect(outcome.result.select == expected.select && outcome.result.error == nil)
        try doc.adopt(try #require(outcome.edited), map: map, base: base)
        #expect(doc.read(0 ..< doc.count) == local.read(0 ..< local.count))

        let (err, _) = try await HelperClient.inProcess().runScript("hw.write(0, [1])\nfoo(", name: "t.js", base: doc.snapshot(),
                                                                    context: ctx, readOnly: false)
        #expect(err.result.error != nil && err.edited == nil)
    }

    @Test func cancellingAScriptStopsItInTheHelper() async throws {
        let (doc, url) = try document()
        defer { try? FileManager.default.removeItem(at: url) }
        let client = HelperClient.inProcess()
        let snap = doc.snapshot()
        let task = Task {
            try await client.runScript("print('started'); while (true) {}", name: "loop.js", base: snap,
                                       context: ScriptContext(), readOnly: false)
        }
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()
        let (outcome, _) = try await task.value
        #expect(outcome.result.output == ["started"])
        #expect(outcome.result.error?.message == L("Cancelled"))
    }

    /// A helper that goes away mid-request (crash, kill) is an error for that
    /// request, and the next request gets a new helper.
    @Test func helperCrashIsReportedAndReplaced() async throws {
        let (doc, url) = try document()
        defer { try? FileManager.default.removeItem(at: url) }
        let dying = NSXPCListener.anonymous()
        let dyingDelegate = DyingHelper()
        dying.delegate = dyingDelegate
        dying.resume()
        let healthy = NSXPCListener.anonymous()
        let healthyDelegate = HelperListener()
        healthy.delegate = healthyDelegate
        healthy.resume()
        let endpoints = Endpoints([dying.endpoint, healthy.endpoint])
        let client = HelperClient { NSXPCConnection(listenerEndpoint: endpoints.next()) }

        await #expect(throws: HelperError.self) {
            _ = try await client.runScript("print(1)", name: "a.js", base: doc.snapshot(), context: ScriptContext(), readOnly: false)
        }
        var output: [String] = []
        for _ in 0 ..< 50 where output.isEmpty {
            do {
                output = try await client.runScript("print(hw.size())", name: "b.js", base: doc.snapshot(),
                                                    context: ScriptContext(), readOnly: false).0.result.output
            } catch {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        #expect(output == ["4096"])
        withExtendedLifetime((dying, dyingDelegate, healthy, healthyDelegate)) {}
    }
}

/// Accepts connections and drops them on the first request without replying,
/// as a crashing helper process does.
private final class DyingHelper: NSObject, NSXPCListenerDelegate, HelperXPC, @unchecked Sendable {
    private var connections: [NSXPCConnection] = []

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.exportedInterface = NSXPCInterface(with: HelperXPC.self)
        c.exportedObject = self
        connections.append(c)
        c.resume()
        return true
    }

    private func die() { connections.forEach { $0.invalidate() } }
    func parse(_ request: Data, file: FileHandle?, reply: @escaping @Sendable (Data?, String?) -> Void) { die() }
    func scan(_ request: Data, file: FileHandle?, reply: @escaping @Sendable (Data?, String?) -> Void) { die() }
    func runScript(_ request: Data, file: FileHandle?, reply: @escaping @Sendable (Data?, String?) -> Void) { die() }
    func cancel(_ requestID: String) {}
}

private final class Endpoints: @unchecked Sendable {
    private var list: [NSXPCListenerEndpoint]
    private let lock = NSLock()
    init(_ list: [NSXPCListenerEndpoint]) { self.list = list }
    func next() -> NSXPCListenerEndpoint {
        lock.withLock { list.count > 1 ? list.removeFirst() : list[0] }
    }
}
