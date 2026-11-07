import Foundation
import Synchronization
import HexwerkCore
import HexwerkKaitai
import HexwerkMagic
import HexwerkScript
import HexwerkYARA

public enum HelperError: Error, LocalizedError, CustomStringConvertible, Sendable {
    /// The helper crashed or was killed while working on the request.
    case stopped
    /// No answer within the request's time limit plus a grace period.
    case timedOut
    /// The helper reported a failure of the request itself.
    case failed(String)

    public var description: String {
        switch self {
        case .stopped: L("The helper process stopped unexpectedly. hexwerk keeps running; the next run starts a new helper.")
        case .timedOut: L("The helper process did not answer in time and was stopped.")
        case .failed(let m): m
        }
    }

    public var errorDescription: String? { description }
}

/// The app's side of the helper connection (#102). One connection serves
/// all windows; when the helper process dies, the waiting requests fail with
/// `HelperError.stopped` and the next request starts a new process (launchd
/// relaunches an interrupted service; an invalidated connection is replaced).
public final class HelperClient: Sendable {
    /// The bundled XPC service, or the helper code in-process when the app
    /// runs without its bundle (`swift run HexwerkApp` during development).
    public static let shared: HelperClient = {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/\(HelperService.name).xpc")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return HelperClient { NSXPCConnection(serviceName: HelperService.name) }
        }
        NSLog("hexwerk: %@ not found, running parsers in-process", bundled.path)
        return .inProcess()
    }()

    /// Same code over an anonymous in-process listener: no isolation, but
    /// the full request/reply path (development builds, tests).
    public static func inProcess() -> HelperClient {
        let delegate = HelperListener()
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        let keep = UncheckedSendable((listener, delegate))
        return HelperClient {
            _ = keep; return NSXPCConnection(listenerEndpoint: keep.value.0.endpoint)
        }
    }

    /// Added to the request's own time limit before the helper is killed.
    public static let grace: TimeInterval = 15

    private let makeConnection: @Sendable () -> NSXPCConnection
    private let current = Mutex<UncheckedSendable<NSXPCConnection>?>(nil)

    public init(makeConnection: @escaping @Sendable () -> NSXPCConnection) {
        self.makeConnection = makeConnection
    }

    private func connection() -> NSXPCConnection {
        current.withLock { cur in
            if let c = cur?.value { return c }
            let c = makeConnection()
            c.remoteObjectInterface = NSXPCInterface(with: HelperXPC.self)
            c.exportedInterface = NSXPCInterface(with: HelperHostXPC.self)
            c.exportedObject = FormatFileHost()
            let ref = UncheckedSendable(c)
            c.invalidationHandler = { [weak self] in
                self?.current.withLock { if $0?.value === ref.value { $0 = nil } }
            }
            c.resume()
            cur = ref
            return c
        }
    }

    /// Forgets a connection whose helper went away, so the next request
    /// opens a new one (and launchd starts a new process). An interrupted
    /// connection could be reused for the bundled service, but not for an
    /// anonymous listener; a fresh one works for both.
    private func drop(_ c: NSXPCConnection) {
        let mine = current.withLock { cur in
            guard cur?.value === c else { return false }
            cur = nil
            return true
        }
        if mine { c.invalidate() }
    }

    // MARK: Requests

    /// Parses `snapshot` with the .ksy at `ksy`. The outer error is a helper
    /// failure; a .ksy that cannot be loaded is `.failure` with the message.
    public func parse(
        _ snapshot: Snapshot, ksy: URL, libraryRoots: [URL],
        limits: ParseLimits = ParseLimits()
    ) async throws -> Result<ParseResult, KaitaiError> {
        let (header, file) = header(snapshot)
        let req = ParseRequest(header: header, ksy: ksy.path, libraryRoots: libraryRoots.map(\.path))
        let data = try await call(id: header.id, timeout: limits.maxSeconds) { p, reply in
            p.parse(try RequestCoder.encode(req), file: file, reply: reply)
        }
        switch try ParseOutcome(encoded: data) {
        case .result(let r): return .success(r)
        case .loadError(let e): return .failure(KaitaiError(e))
        case .loaded: throw HelperError.failed(L("Invalid reply from the helper: %@", "no parse result"))
        }
    }

    public func scan(
        _ snapshot: Snapshot, rules: YaraRuleBundle, range: Range<UInt64>?, timeout: Int,
        maxMatchesPerPattern: Int
    ) async throws -> YaraScanOutcome {
        let (header, file) = header(snapshot)
        let req = ScanRequest(
            header: header, rules: rules, range: range, timeout: timeout,
            maxMatchesPerPattern: maxMatchesPerPattern)
        // Compiling counts too: allow it as long as the scan.
        let data = try await call(id: header.id, timeout: 2 * Double(max(1, timeout))) { p, reply in
            p.scan(try RequestCoder.encode(req), file: file, reply: reply)
        }
        return try YaraScanOutcome(encoded: data)
    }

    /// Runs a script on `base`. If it changed the content, `doc.adopt(edited,
    /// map:base:)` takes the result over (the caller does, on its thread).
    public func runScript(
        _ source: String, name: String, base: Snapshot, context: ScriptContext,
        readOnly: Bool, timeout: Double = ScriptRunner.defaultTimeout
    ) async throws
        -> (ScriptOutcome, AddedMap)
    {
        let (wire, map) = base.wire()
        let (header, file) = header(base, wire: wire)
        let req = ScriptRequest(
            header: header, source: source, name: name, cursor: context.cursor,
            selection: context.selection, fileName: context.fileName,
            readOnly: readOnly, timeout: timeout)
        // Cancelling waits for the helper: the script stops within 0.2 s and
        // its output so far is shown, as before.
        let data = try await call(id: header.id, timeout: timeout, waitWhenCancelled: true) { p, reply in
            p.runScript(try RequestCoder.encode(req), file: file, reply: reply)
        }
        return (try ScriptOutcome(encoded: data), map)
    }

    /// libmagic's description and MIME type of the snapshot's start (#129),
    /// both nil without a database. libmagic is C code with a history of
    /// CVEs, so it runs in the helper like the parsers.
    public func detectType(_ snapshot: Snapshot, database: URL?, timeout: TimeInterval = 30) async throws -> TypeOutcome {
        guard let database, let handle = try? FileHandle(forReadingFrom: database) else {
            return TypeOutcome(description: nil, mime: nil)
        }
        let req = TypeRequest(language: L10n.language.rawValue, sample: Magic.sample(snapshot))
        let data = try await call(id: UUID().uuidString, timeout: timeout) { p, reply in
            p.detectType(try RequestCoder.encode(req), database: handle, reply: reply)
        }
        return try TypeOutcome(encoded: data)
    }

    private func header(_ snapshot: Snapshot, wire: SnapshotWire? = nil) -> (RequestHeader, FileHandle?) {
        (
            RequestHeader(
                id: UUID().uuidString, language: L10n.language.rawValue,
                snapshot: wire ?? snapshot.wire().0, path: snapshot.fileURL.path),
            snapshot.fileHandle()
        )
    }

    /// Sends one request and waits for its reply. Cancelling the calling
    /// task tells the helper to stop and returns at once, or with
    /// `waitWhenCancelled` returns what the helper answers then.
    private func call(
        id: String, timeout: TimeInterval, waitWhenCancelled: Bool = false,
        _ send: (HelperXPC, @escaping @Sendable (Data?, String?) -> Void) throws -> Void
    ) async throws -> Data {
        let conn = connection()
        let ref = UncheckedSendable(conn)
        let pending = Pending()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Data, Error>) in
                pending.set(k)
                if Task.isCancelled && !waitWhenCancelled { pending.finish(.failure(CancellationError())) }
                let proxy =
                    conn.remoteObjectProxyWithErrorHandler { [weak self] _ in
                        pending.finish(.failure(HelperError.stopped))
                        self?.drop(ref.value)
                    } as? HelperXPC
                guard let proxy else { pending.finish(.failure(HelperError.stopped)); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout + Self.grace) {
                    // A hung helper (a parser stuck outside its own limits)
                    // is stopped; other requests it served fail as `stopped`.
                    if pending.finish(.failure(HelperError.timedOut)) {
                        Self.kill(ref.value)
                        self.drop(ref.value)
                    }
                }
                do {
                    try send(proxy) { data, error in
                        pending.finish(data.map { .success($0) } ?? .failure(HelperError.failed(error ?? "")))
                    }
                } catch {
                    pending.finish(.failure(error))
                }
                // Cancelled before the request was out: tell the helper now.
                if Task.isCancelled && waitWhenCancelled { proxy.cancel(id) }
            }
        } onCancel: {
            if waitWhenCancelled || pending.finish(.failure(CancellationError())) {
                (ref.value.remoteObjectProxy as? HelperXPC)?.cancel(id)
            }
        }
    }

    private static func kill(_ c: NSXPCConnection) {
        let pid = c.processIdentifier
        if pid > 0, pid != getpid() { Darwin.kill(pid, SIGKILL) }
    }

    /// Resumes its continuation once, whichever comes first.
    private final class Pending: Sendable {
        private let state = Mutex<(k: CheckedContinuation<Data, Error>?, result: Result<Data, Error>?, done: Bool)>((nil, nil, false))

        func set(_ k: CheckedContinuation<Data, Error>) {
            let r: Result<Data, Error>? = state.withLock { s in
                if let r = s.result { s.result = nil; return r }
                s.k = k
                return nil
            }
            if let r { k.resume(with: r) }
        }

        /// True if this call finished the request.
        @discardableResult
        func finish(_ r: Result<Data, Error>) -> Bool {
            let (k, first): (CheckedContinuation<Data, Error>?, Bool) = state.withLock { s in
                guard !s.done else { return (nil, false) }
                s.done = true
                if let k = s.k { s.k = nil; return (k, true) }
                s.result = r
                return (nil, true)
            }
            k?.resume(with: r)
            return first
        }
    }
}

/// Answers the helper's requests for .ksy files. The helper may be
/// compromised, so it gets nothing but regular files ending in .ksy, of
/// sane size; that is what the in-process loader could read as well.
final class FormatFileHost: NSObject, HelperHostXPC {
    static let maxSize: Int64 = 16 << 20

    func readFormatFile(_ path: String, reply: @escaping @Sendable (String?, String?) -> Void) {
        let r = Self.read(path)
        reply(r.0, r.1)
    }

    static func read(_ path: String) -> (String?, String?) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard path.hasPrefix("/"), url.pathExtension.lowercased() == "ksy" else {
            return (nil, L("Only .ksy files can be read"))
        }
        var st = stat()
        guard stat(url.path, &st) == 0 else { return (nil, nil) }
        guard (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= maxSize else {
            return (nil, L("Only .ksy files can be read"))
        }
        do { return (try String(contentsOf: url, encoding: .utf8), nil) } catch { return (nil, error.localizedDescription) }
    }
}
