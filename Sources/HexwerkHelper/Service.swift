import Foundation
import Synchronization
import HexwerkCore
import HexwerkKaitai
import HexwerkScript
import HexwerkYARA

/// Accepts connections and serves `HelperXPC`. The XPC service uses it with
/// `NSXPCListener.service()`; a build without the service bundle (`swift run`)
/// and the tests use it in-process with an anonymous listener.
public final class HelperListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.exportedInterface = NSXPCInterface(with: HelperXPC.self)
        c.remoteObjectInterface = NSXPCInterface(with: HelperHostXPC.self)
        c.exportedObject = HelperServer(connection: c)
        c.resume()
        return true
    }
}

/// Parse result or the .ksy loading error, as the app showed it in-process.
enum ParseOutcome {
    case result(ParseResult)
    case loadError(String)

    func encoded() -> Data {
        switch self {
        case .result(let r): Data([0]) + r.encoded()
        case .loadError(let e): Data([1]) + Data(e.utf8)
        }
    }

    /// Decodes on a large stack (the tree is read recursively).
    init(encoded data: Data) throws {
        guard let tag = data.first else { throw WireError("empty reply") }
        let rest = data.dropFirst()
        switch tag {
        case 0: self = .result(try onLargeStack { Result { try ParseResult(encoded: rest) } }.get())
        case 1: self = .loadError(String(decoding: rest, as: UTF8.self))
        default: throw WireError("bad parse outcome")
        }
    }
}

final class HelperServer: NSObject, HelperXPC, @unchecked Sendable {
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
    private func run<R: Decodable & Sendable>(_ type: R.Type, _ data: Data, header: (R) -> RequestHeader, file: FileHandle?,
                                   reply: @escaping @Sendable (Data?, String?) -> Void,
                                   _ work: @escaping (R, Snapshot, CancelToken) throws -> Data) {
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
            let file: KsyFile
            do {
                let loader = KsyLoader(libraryRoots: req.libraryRoots.map { URL(fileURLWithPath: $0) },
                                       read: { url in try self?.readFormatFile(url) ?? nil })
                file = try loader.load(URL(fileURLWithPath: req.ksy))
            } catch {
                return ParseOutcome.loadError(String(describing: error)).encoded()
            }
            let result = KaitaiInterpreter.parse(snapshot, file: file, shouldContinue: { !token.isSet })
            return ParseOutcome.result(result).encoded()
        }
    }

    func scan(_ request: Data, file: FileHandle?, reply: @escaping @Sendable (Data?, String?) -> Void) {
        run(ScanRequest.self, request, header: \.header, file: file, reply: reply) { req, snapshot, _ in
            let rules: YaraRules
            do {
                rules = try req.rules.compile(materializingIn: FileManager.default.temporaryDirectory
                    .appendingPathComponent("yara-\(UUID().uuidString)"))
            } catch let e as YaraCompileError {
                return YaraScanOutcome.compileErrors(e.diagnostics).encoded()
            }
            do {
                let hits = try rules.scan(snapshot, range: req.range, timeout: req.timeout,
                                          maxMatchesPerPattern: req.maxMatchesPerPattern)
                return YaraScanOutcome.hits(hits, warnings: rules.warnings).encoded()
            } catch {
                return YaraScanOutcome.failed(String(describing: error), warnings: rules.warnings).encoded()
            }
        }
    }

    func runScript(_ request: Data, file: FileHandle?, reply: @escaping @Sendable (Data?, String?) -> Void) {
        run(ScriptRequest.self, request, header: \.header, file: file, reply: reply) { req, snapshot, token in
            let copy = Document(editing: snapshot, readOnly: req.readOnly)
            let ctx = ScriptContext(cursor: req.cursor, selection: req.selection, fileName: req.fileName)
            let r = ScriptRunner.run(req.source, name: req.name, document: copy, context: ctx,
                                     timeout: req.timeout, isCancelled: { token.isSet })
            let edited = r.error == nil && copy.isModified
                ? copy.editedContent(sentAddedCount: req.header.snapshot.added.count) : nil
            return ScriptOutcome(result: r, edited: edited).encoded()
        }
    }

    /// Asks the app for a .ksy file; waits for the answer.
    private func readFormatFile(_ url: URL) throws -> String? {
        guard let connection else { throw HelperError.stopped }
        // The synchronous proxy calls one of the two blocks before returning.
        let answer = Mutex<Result<String?, Error>>(.failure(HelperError.stopped))
        let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler { e in
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
