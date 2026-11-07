import Foundation
import HexwerkCore
import HexwerkKaitai
import HexwerkMagic
import HexwerkScript
import HexwerkYARA

public enum SandboxedChildError: Error, LocalizedError, CustomStringConvertible, Sendable {
    case notStarted(String)
    /// The child crashed or exited without an answer.
    case stopped
    case timedOut
    /// The child reported a failure of the request itself.
    case failed(String)

    public var description: String {
        switch self {
        case .notStarted(let m): L("The sandboxed parser process could not be started: %@", m)
        case .stopped: L("The sandboxed parser process stopped unexpectedly.")
        case .timedOut: L("The sandboxed parser process did not answer in time and was stopped.")
        case .failed(let m): m
        }
    }

    public var errorDescription: String? { description }
}

/// The CLI's counterpart to the app's XPC helper (#129): a request runs in a
/// child process of the same executable, started with `argument`, which
/// enters `Sandbox` before it reads anything. The child gets the document as
/// an inherited descriptor (3) and libmagic's database as another (4); the
/// request (rules, script, sample) comes over its stdin, the answer goes back
/// over its stdout in the helper's wire formats. The child asks for .ksy
/// files over the same pipes, and the parent answers like the app does.
/// A crash or hang of the child is an error here, never a crash of the CLI.
public struct SandboxedChild: Sendable {
    /// First argument of the child's command line (not a subcommand: it must
    /// not show up in help, completions or the man page).
    public static let argument = "__sandboxed-child"

    /// Added to the request's own time limit before the child is killed.
    public static let grace: TimeInterval = HelperClient.grace

    public let executable: String

    public init(executable: String? = nil) {
        self.executable = executable ?? Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    // MARK: Requests

    /// `snapshot` nil: only load the .ksy (`.loaded` or `.loadError`).
    public func parse(_ snapshot: Snapshot?, ksy: URL, libraryRoots: [URL]) throws -> ParseOutcome {
        let req = ParseRequest(
            header: header(snapshot), ksy: ksy.path, libraryRoots: libraryRoots.map(\.path))
        // Standardized here for both: in the child, which cannot look at
        // folders, /private/tmp/x stays as is instead of becoming /tmp/x.
        let main = ksy.standardizedFileURL
        let data = try run(
            .parse, try RequestCoder.encode(req), file: snapshot?.fileHandle(),
            timeout: ParseLimits().maxSeconds,
            readFormatFile: { path in
                // The format the user named is read as it was in-process
                // (any name); imports only as .ksy files, like in the app.
                guard URL(fileURLWithPath: path).standardizedFileURL == main else { return FormatFileHost.read(path) }
                do {
                    // Foundation's message for a missing file is made here:
                    // the child cannot read Foundation's localized texts.
                    guard let text = try KsyLoader.readFile(main) else {
                        return (nil, CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: main.path]).localizedDescription)
                    }
                    return (text, nil)
                } catch {
                    return (nil, error.localizedDescription)
                }
            })
        return try ParseOutcome(encoded: data)
    }

    /// `snapshot` nil: only compile (hits empty, the warnings or errors).
    public func scan(
        _ snapshot: Snapshot?, rules: YaraRuleBundle, range: Range<UInt64>?, timeout: Int
    ) throws -> YaraScanOutcome {
        let req = ScanRequest(
            header: header(snapshot), rules: rules, range: range, timeout: timeout, maxMatchesPerPattern: nil)
        // Compiling counts too: allow it as long as the scan (as in the app).
        let data = try run(
            .scan, try RequestCoder.encode(req), file: snapshot?.fileHandle(), timeout: 2 * Double(max(1, timeout)))
        return try YaraScanOutcome(encoded: data)
    }

    public func runScript(
        _ source: String, name: String, base: Snapshot, fileName: String, timeout: Double
    ) throws -> (ScriptOutcome, AddedMap) {
        let (wire, map) = base.wire()
        let req = ScriptRequest(
            header: header(base, wire: wire), source: source, name: name, cursor: 0, selection: nil,
            fileName: fileName, readOnly: false, timeout: timeout)
        let data = try run(.script, try RequestCoder.encode(req), file: base.fileHandle(), timeout: timeout)
        return (try ScriptOutcome(encoded: data), map)
    }

    /// Both nil without a database.
    public func detectType(_ snapshot: Snapshot, database: URL?) throws -> TypeOutcome {
        guard let database, let handle = try? FileHandle(forReadingFrom: database) else {
            return TypeOutcome(description: nil, mime: nil)
        }
        let req = TypeRequest(language: L10n.language.rawValue, sample: Magic.sample(snapshot))
        let data = try run(.type, try RequestCoder.encode(req), database: handle, timeout: 30)
        return try TypeOutcome(encoded: data)
    }

    /// Test hook: runs a probe in the sandboxed child (see `Probe`).
    func probe(_ probe: String, timeout: TimeInterval = 30, grace: TimeInterval = SandboxedChild.grace) throws -> String {
        let data = try run(.probe, Data(probe.utf8), timeout: timeout, grace: grace)
        return String(decoding: data, as: UTF8.self)
    }

    private func header(_ snapshot: Snapshot?, wire: SnapshotWire? = nil) -> RequestHeader {
        RequestHeader(
            id: UUID().uuidString, language: L10n.language.rawValue,
            snapshot: wire ?? snapshot?.wire().0 ?? SnapshotWire(pieces: [], added: Data(), count: 0),
            path: snapshot?.fileURL.path ?? "")
    }

    // MARK: Parent side

    enum Op: String, Codable { case parse, scan, script, type, probe }

    struct Envelope: Codable {
        var op: Op
        var request: Data
        var hasFile: Bool
        var hasDatabase: Bool
    }

    /// Frame tags.
    enum Tag {
        static let request: UInt8 = 0
        static let result: UInt8 = 1
        static let failure: UInt8 = 2
        static let readFormatFile: UInt8 = 3
        static let formatFile: UInt8 = 4
    }

    static let fileFD: Int32 = 3
    static let databaseFD: Int32 = 4

    private func run(
        _ op: Op, _ request: Data, file: FileHandle? = nil, database: FileHandle? = nil,
        timeout: TimeInterval, grace: TimeInterval = SandboxedChild.grace,
        readFormatFile: (String) -> (String?, String?) = { _ in (nil, L("Only .ksy files can be read")) }
    ) throws -> Data {
        // The YARA compiler writes the rule files below a folder of its own
        // (includes resolve there); nothing else in the child can write.
        let scratch = op == .scan ? try Self.makeScratch() : nil
        defer { if let scratch { try? FileManager.default.removeItem(atPath: scratch) } }

        let child = try Self.spawn(executable, scratch: scratch, file: file, database: database)
        try? file?.close()
        try? database?.close()
        defer { child.finish() }

        let envelope = try RequestCoder.encode(
            Envelope(op: op, request: request, hasFile: file != nil, hasDatabase: database != nil))
        // The request can exceed the pipe buffer: write it on a thread of its
        // own, so a child that hangs before reading cannot block the timeout.
        let channel = child.channel
        Thread.detachNewThread { try? channel.send(Tag.request, envelope) }

        let deadline = Date().addingTimeInterval(timeout + grace)
        while true {
            let tag: UInt8, payload: Data
            do { (tag, payload) = try channel.receive(deadline: deadline) } catch FrameError.timedOut {
                throw SandboxedChildError.timedOut
            } catch {
                throw SandboxedChildError.stopped
            }
            switch tag {
            case Tag.result: return payload
            case Tag.failure: throw SandboxedChildError.failed(String(decoding: payload, as: UTF8.self))
            case Tag.readFormatFile:
                let (text, error) = readFormatFile(String(decoding: payload, as: UTF8.self))
                var w = WireWriter()
                w.optional(text) { $0.string($1) }
                w.optional(error) { $0.string($1) }
                do { try channel.send(Tag.formatFile, w.data) } catch { throw SandboxedChildError.stopped }
            default: throw SandboxedChildError.stopped
            }
        }
    }

    private static func makeScratch() throws -> String {
        var template = Array((FileManager.default.temporaryDirectory.path + "/hexwerk-sandbox-XXXXXX").utf8CString)
        guard let dir = mkdtemp(&template) else {
            throw SandboxedChildError.notStarted(String(cString: strerror(errno)))
        }
        // The sandbox matches resolved paths (/var is /private/var).
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(dir, &resolved) != nil else {
            rmdir(dir)
            throw SandboxedChildError.notStarted(String(cString: strerror(errno)))
        }
        return resolved.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private struct Running {
        let pid: pid_t
        let channel: Channel

        /// The answer is in (or the child failed): stop it in any case.
        func finish() {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            channel.close()
        }
    }

    private static func spawn(_ exe: String, scratch: String?, file: FileHandle?, database: FileHandle?) throws -> Running {
        func failure(_ code: Int32 = errno) -> SandboxedChildError {
            .notStarted(String(cString: strerror(code)))
        }
        // Descriptors for the child, closed here once it has its copies.
        var forChild: [Int32] = []
        defer { for fd in forChild { Darwin.close(fd) } }
        // Copies above the target numbers 0…4, so no dup2 below is a no-op
        // that would leave close-on-exec set.
        func high(_ fd: Int32) throws -> Int32 {
            let h = fcntl(fd, F_DUPFD_CLOEXEC, 10)
            guard h >= 0 else { throw failure() }
            forChild.append(h)
            return h
        }
        var toChild: [Int32] = [-1, -1], fromChild: [Int32] = [-1, -1]
        guard pipe(&toChild) == 0 else { throw failure() }
        forChild.append(toChild[0])
        guard pipe(&fromChild) == 0 else {
            Darwin.close(toChild[1])
            throw failure()
        }
        forChild.append(fromChild[1])
        let channel = Channel(read: fromChild[0], write: toChild[1])

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        let args = [exe, argument, scratch ?? ""]
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { for a in argv { free(a) } }
        // No environment: nothing of the user's leaks in, nothing steers the child.
        var envp: [UnsafeMutablePointer<CChar>?] = [nil]
        var pid: pid_t = 0
        do {
            posix_spawn_file_actions_adddup2(&actions, try high(toChild[0]), 0)
            posix_spawn_file_actions_adddup2(&actions, try high(fromChild[1]), 1)
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
            if let file { posix_spawn_file_actions_adddup2(&actions, try high(file.fileDescriptor), fileFD) }
            if let database { posix_spawn_file_actions_adddup2(&actions, try high(database.fileDescriptor), databaseFD) }
            // Only the descriptors above reach the child.
            posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
            let rc = posix_spawn(&pid, exe, &actions, &attr, &argv, &envp)
            guard rc == 0 else { throw failure(rc) }
        } catch {
            channel.close()
            throw error
        }
        return Running(pid: pid, channel: channel)
    }

    // MARK: Child side

    /// Entry point of the child (`argument` given): enters the sandbox,
    /// serves one request and exits.
    public static func serve(arguments: [String]) -> Never {
        let channel = Channel(read: 0, write: 1)
        let scratch = arguments.first.flatMap { $0.isEmpty ? nil : $0 }
        do { try Sandbox.enter(scratch: scratch) } catch {
            // Never run unsandboxed.
            try? channel.send(Tag.failure, Data(String(describing: error).utf8))
            exit(70)
        }
        let box = UncheckedSendable(channel)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            let channel = box.value
            do {
                let (tag, data) = try channel.receive(deadline: nil)
                guard tag == Tag.request else { throw WireError("bad request") }
                let envelope = try RequestCoder.decode(Envelope.self, data)
                try channel.send(Tag.result, try handle(envelope, channel: channel, scratch: scratch))
            } catch {
                try? channel.send(Tag.failure, Data(String(describing: error).utf8))
            }
            done.signal()
        }
        // Parsers, wasmtime and JavaScriptCore need the stack (as in the helper).
        thread.stackSize = 64 << 20
        thread.start()
        done.wait()
        exit(0)
    }

    private static func handle(_ e: Envelope, channel: Channel, scratch: String?) throws -> Data {
        func snapshot(_ h: RequestHeader) throws -> Snapshot? {
            if let lang = L10n.Language(rawValue: h.language), lang != L10n.language { L10n.override = lang }
            guard e.hasFile else { return nil }
            let source = try ByteSource(fileDescriptor: fileFD, url: URL(fileURLWithPath: h.path))
            Darwin.close(fileFD)
            return try Snapshot(wire: h.snapshot, original: source)
        }
        switch e.op {
        case .parse:
            let req = try RequestCoder.decode(ParseRequest.self, e.request)
            return HelperWork.parse(
                req, try snapshot(req.header), isCancelled: { false },
                read: { url in try requestFormatFile(url.path, channel: channel) })
        case .scan:
            let req = try RequestCoder.decode(ScanRequest.self, e.request)
            guard let scratch else { throw WireError("no scratch folder") }
            return try HelperWork.scan(req, try snapshot(req.header), scratch: URL(fileURLWithPath: scratch))
        case .script:
            let req = try RequestCoder.decode(ScriptRequest.self, e.request)
            guard let snap = try snapshot(req.header) else { throw SnapshotWireError.invalid("no file") }
            return HelperWork.runScript(req, snap, isCancelled: { false })
        case .type:
            let req = try RequestCoder.decode(TypeRequest.self, e.request)
            if let lang = L10n.Language(rawValue: req.language), lang != L10n.language { L10n.override = lang }
            let db = e.hasDatabase ? MagicDatabase(handle: FileHandle(fileDescriptor: databaseFD, closeOnDealloc: true)) : nil
            return HelperWork.detectType(req, database: db)
        case .probe:
            return Data(Probe.run(String(decoding: e.request, as: UTF8.self)).utf8)
        }
    }

    private static func requestFormatFile(_ path: String, channel: Channel) throws -> String? {
        try channel.send(Tag.readFormatFile, Data(path.utf8))
        let (tag, data) = try channel.receive(deadline: nil)
        guard tag == Tag.formatFile else { throw WireError("bad answer") }
        var r = WireReader(data)
        let text = try r.optional { try $0.string() }
        if let error = try r.optional({ try $0.string() }) { throw HelperError.failed(error) }
        try r.expectEnd()
        return text
    }
}

/// Test probes run inside the sandboxed child: what a compromised parser
/// would try (`open:<path>`, `socket`), and a crash and a hang.
enum Probe {
    static func run(_ probe: String) -> String {
        switch probe {
        case let p where p.hasPrefix("open:"):
            let fd = open(String(p.dropFirst(5)), O_RDONLY)
            defer { if fd >= 0 { close(fd) } }
            return fd >= 0 ? "opened" : "errno \(errno)"
        case let p where p.hasPrefix("write:"):
            let fd = open(String(p.dropFirst(6)), O_WRONLY | O_CREAT, 0o600)
            defer { if fd >= 0 { close(fd) } }
            return fd >= 0 ? "opened" : "errno \(errno)"
        case let p where p.hasPrefix("connect:"):
            // `connect:<port>` on 127.0.0.1, `connect:/path` to a Unix socket.
            // macOS's sandbox does not mediate creating an Internet socket,
            // only what can be done with it, so the probe connects.
            return connect(String(p.dropFirst(8)))
        case "crash":
            // A wild write, as a parser bug would do.
            UnsafeMutablePointer<Int>(bitPattern: 16)!.pointee = 1
            return "alive"
        case "hang":
            while true { sleep(60) }
        default:
            return "unknown probe"
        }
    }

    private static func connect(_ target: String) -> String {
        // Looked up at run time: hexwerk's own code imports no socket
        // functions (NoNetworkTests), not even for this probe.
        typealias SocketFn = @convention(c) (Int32, Int32, Int32) -> Int32
        typealias ConnectFn = @convention(c) (Int32, UnsafePointer<sockaddr>, socklen_t) -> Int32
        let all = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        guard let s = dlsym(all, "socket"), let c = dlsym(all, "connect") else { return "no socket API" }
        let socketFn = unsafeBitCast(s, to: SocketFn.self), connectFn = unsafeBitCast(c, to: ConnectFn.self)
        let unix = target.hasPrefix("/")
        let fd = socketFn(unix ? AF_UNIX : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return "socket errno \(errno)" }
        defer { close(fd) }
        let rc: Int32
        if unix {
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                for (i, b) in target.utf8.prefix(buf.count - 1).enumerated() { buf[i] = b }
            }
            rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connectFn(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(target) ?? 9).bigEndian
            addr.sin_addr.s_addr = in_addr_t(0x7F00_0001).bigEndian
            rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connectFn(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        return rc == 0 ? "connected" : "errno \(errno)"
    }
}

// MARK: - Framing

enum FrameError: Error { case timedOut, closed }

/// Frames over a pipe pair: tag byte, 4-byte big-endian length, payload.
struct Channel: Sendable {
    let read: Int32
    let write: Int32

    /// What a (possibly compromised) child may send in one frame.
    static let maxFrame = 1 << 30

    init(read: Int32, write: Int32) {
        self.read = read
        self.write = write
        // A child that died must not take the parent down with SIGPIPE.
        _ = fcntl(write, F_SETNOSIGPIPE, 1)
    }

    func send(_ tag: UInt8, _ payload: Data) throws {
        guard payload.count <= Self.maxFrame else { throw FrameError.closed }
        let n = UInt32(payload.count)
        var frame = Data([tag, UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
        frame.append(payload)
        try frame.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let w = Darwin.write(write, buf.baseAddress! + off, buf.count - off)
                if w < 0 && errno == EINTR { continue }
                guard w > 0 else { throw FrameError.closed }
                off += w
            }
        }
    }

    func receive(deadline: Date?) throws -> (UInt8, Data) {
        let head = try readExactly(5, deadline: deadline)
        let n = head.dropFirst().reduce(0) { $0 << 8 | Int($1) }
        guard n <= Self.maxFrame else { throw FrameError.closed }
        return (head[head.startIndex], try readExactly(n, deadline: deadline))
    }

    private func readExactly(_ n: Int, deadline: Date?) throws -> Data {
        var out = Data(count: n)
        var off = 0
        while off < n {
            if let deadline {
                let ms = deadline.timeIntervalSinceNow * 1000
                guard ms > 0 else { throw FrameError.timedOut }
                var p = pollfd(fd: read, events: Int16(POLLIN), revents: 0)
                let r = poll(&p, 1, Int32(min(ms, Double(Int32.max))))
                if r < 0 && errno == EINTR { continue }
                guard r >= 0 else { throw FrameError.closed }
                if r == 0 { continue }
            }
            let got = out.withUnsafeMutableBytes { Darwin.read(read, $0.baseAddress! + off, n - off) }
            if got < 0 && errno == EINTR { continue }
            guard got > 0 else { throw FrameError.closed }
            off += got
        }
        return out
    }

    func close() {
        Darwin.close(read)
        Darwin.close(write)
    }
}
