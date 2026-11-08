import Foundation
import Synchronization
import HexwerkCore
import HexwerkKaitai
import HexwerkMagic
import HexwerkScript
import HexwerkYARA

/// Accepts connections and serves `HelperXPC`. The XPC service uses it with
/// `NSXPCListener.service()`; a build without the service bundle (`swift run`)
/// and the tests use it in-process with an anonymous listener.
public final class HelperListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let probes: Bool

    /// `probes` exports `HelperProbeXPC` instead of `HelperXPC` (#134). Only
    /// the test-only service `make sandbox-probes` builds passes true; the
    /// service in hexwerk.app does not, and NSXPC rejects every message whose
    /// selector is not in the exported interface.
    public init(probes: Bool = false) {
        self.probes = probes
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.exportedInterface = NSXPCInterface(with: probes ? HelperProbeXPC.self : HelperXPC.self)
        c.remoteObjectInterface = NSXPCInterface(with: HelperHostXPC.self)
        c.exportedObject = HelperServer(connection: c)
        c.resume()
        return true
    }
}

/// Parse result or the .ksy loading error, as the app showed it in-process.
public enum ParseOutcome: Sendable {
    case result(ParseResult)
    case loadError(String)
    /// The .ksy loaded, but there was no file to parse (CLI, #129: the
    /// format's errors come before those of the file, as they did in-process).
    case loaded

    func encoded() -> Data {
        switch self {
        case .result(let r): Data([0]) + r.encoded()
        case .loadError(let e): Data([1]) + Data(e.utf8)
        case .loaded: Data([2])
        }
    }

    /// Decodes on a large stack (the tree is read recursively).
    init(encoded data: Data) throws {
        guard let tag = data.first else { throw WireError("empty reply") }
        let rest = data.dropFirst()
        switch tag {
        case 0: self = .result(try onLargeStack { Result { try ParseResult(encoded: rest) } }.get())
        case 1: self = .loadError(String(decoding: rest, as: UTF8.self))
        case 2 where rest.isEmpty: self = .loaded
        default: throw WireError("bad parse outcome")
        }
    }
}

final class HelperServer: NSObject, HelperProbeXPC, @unchecked Sendable {
    private weak var connection: NSXPCConnection?
    private let cancelled = Mutex<[String: CancelToken]>([:])

    init(connection: NSXPCConnection) { self.connection = connection }

    final class CancelToken: Sendable {
        let flag = Atomic(false)
        var isSet: Bool { flag.load(ordering: .relaxed) }
    }

    func cancel(_ requestID: String) {
        cancelled.withLock { $0[requestID]?.flag.store(true, ordering: .relaxed) }
    }

    /// Runs `work` on its own large-stack thread: requests may take long,
    /// and parsers, wasmtime and JavaScriptCore need the stack.
    private func run<R: Decodable & Sendable>(
        _ type: R.Type, _ data: Data, header: (R) -> RequestHeader, file: FileHandle?,
        reply: @escaping @Sendable (Data?, String?) -> Void,
        _ work: @escaping (R, Snapshot, CancelToken) throws -> Data
    ) {
        let request: R
        do { request = try RequestCoder.decode(type, data) } catch {
            reply(nil, L("Invalid request: %@", String(describing: error)))
            return
        }
        let h = header(request)
        let token = CancelToken()
        cancelled.withLock { $0[h.id] = token }
        let box = UncheckedSendable((request, file, work))
        let thread = Thread { [self] in
            let (request, file, work) = box.value
            defer { cancelled.withLock { $0[h.id] = nil } }
            if let lang = L10n.Language(rawValue: h.language), lang != L10n.language { L10n.override = lang }
            do {
                guard let file else { throw SnapshotWireError.invalid("no file") }
                let source = try ByteSource(fileDescriptor: file.fileDescriptor, url: URL(fileURLWithPath: h.path))
                try? file.close()
                let snapshot = try Snapshot(wire: h.snapshot, original: source)
                reply(try work(request, snapshot, token), nil)
            } catch {
                reply(nil, String(describing: error))
            }
        }
        thread.stackSize = 64 << 20
        thread.start()
    }

    func parse(_ request: Data, file: FileHandle?, reply: @escaping @Sendable (Data?, String?) -> Void) {
        run(ParseRequest.self, request, header: \.header, file: file, reply: reply) { [weak self] req, snapshot, token in
            HelperWork.parse(
                req, snapshot, isCancelled: { token.isSet }, read: { url in try self?.readFormatFile(url) ?? nil })
        }
    }

    func scan(_ request: Data, file: FileHandle?, reply: @escaping @Sendable (Data?, String?) -> Void) {
        run(ScanRequest.self, request, header: \.header, file: file, reply: reply) { req, snapshot, _ in
            try HelperWork.scan(req, snapshot, scratch: FileManager.default.temporaryDirectory)
        }
    }

    func runScript(_ request: Data, file: FileHandle?, reply: @escaping @Sendable (Data?, String?) -> Void) {
        run(ScriptRequest.self, request, header: \.header, file: file, reply: reply) { req, snapshot, token in
            HelperWork.runScript(req, snapshot, isCancelled: { token.isSet })
        }
    }

    /// The database is loaded once per helper process; later requests carry
    /// the descriptor too but it is not read again.
    private static let magic = Mutex<MagicDatabase?>(nil)

    func detectType(_ request: Data, database: FileHandle?, reply: @escaping @Sendable (Data?, String?) -> Void) {
        let req: TypeRequest
        do { req = try RequestCoder.decode(TypeRequest.self, request) } catch {
            reply(nil, L("Invalid request: %@", String(describing: error)))
            return
        }
        let box = UncheckedSendable(database)
        let thread = Thread {
            if let lang = L10n.Language(rawValue: req.language), lang != L10n.language { L10n.override = lang }
            let db = Self.magic.withLock { cached in
                if cached == nil, let h = box.value { cached = MagicDatabase(handle: h) }
                return cached
            }
            try? box.value?.close()
            reply(HelperWork.detectType(req, database: db), nil)
        }
        thread.stackSize = 16 << 20
        thread.start()
    }

    /// Test hook (#134), reachable only through `HelperListener(probes: true)`:
    /// the CLI child's probes, run in the XPC service. `%TMP%` is the
    /// service's temporary folder (where YARA writes its rule files).
    func probe(_ probe: String, reply: @escaping @Sendable (String) -> Void) {
        let thread = Thread {
            reply(Probe.run(probe.replacingOccurrences(of: "%TMP%", with: FileManager.default.temporaryDirectory.path)))
        }
        thread.stackSize = 16 << 20
        thread.start()
    }

    /// Asks the app for a .ksy file; waits for the answer.
    private func readFormatFile(_ url: URL) throws -> String? {
        guard let connection else { throw HelperError.stopped }
        // The synchronous proxy calls one of the two blocks before returning.
        let answer = Mutex<Result<String?, Error>>(.failure(HelperError.stopped))
        let proxy =
            connection.synchronousRemoteObjectProxyWithErrorHandler { e in
                answer.withLock { $0 = .failure(e) }
            } as? HelperHostXPC
        proxy?.readFormatFile(url.path) { text, error in
            answer.withLock { $0 = error.map { .failure(HelperError.failed($0)) } ?? .success(text) }
        }
        return try answer.withLock { $0 }.get()
    }
}

struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
