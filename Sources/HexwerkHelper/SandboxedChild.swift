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
    /// A request or result over `Channel.maxFrame` (1 GiB).
    case tooLarge
    /// The child reported a failure of the request itself.
    case failed(String)

    public var description: String {
        switch self {
        case .notStarted(let m): L("The sandboxed parser process could not be started: %@", m)
        case .stopped: L("The sandboxed parser process stopped unexpectedly.")
        case .timedOut: L("The sandboxed parser process did not answer in time and was stopped.")
        case .tooLarge: L("The request or result is larger than the 1 GiB the sandboxed parser process can exchange.")
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
        _ snapshot: Snapshot?, rules: YaraRuleBundle, range: Range<UInt64>?, timeout: Int,
        grace: TimeInterval = SandboxedChild.grace
    ) throws -> YaraScanOutcome {
        let req = ScanRequest(
            header: header(snapshot), rules: rules, range: range, timeout: timeout, maxMatchesPerPattern: nil)
        // Compiling had no time limit in-process: it gets a generous one of
        // its own, and the scan's limit starts when the child reports the
        // rules compiled.
        let data = try run(
            .scan, try RequestCoder.encode(req), file: snapshot?.fileHandle(), timeout: Double(max(1, timeout)),
            firstPhase: Self.compileBudget, grace: grace)
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

    /// Test hook: runs a probe in the sandboxed child (see `Probe`), with
    /// the scan's profile (a scratch folder) if `scratch`.
    func probe(
        _ probe: String, scratch: Bool = false, timeout: TimeInterval = 30, grace: TimeInterval = SandboxedChild.grace
    ) throws -> String {
        let data = try run(.probe, Data(probe.utf8), scratch: scratch, timeout: timeout, grace: grace)
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
        /// The rules are compiled; the scan's own time limit starts.
        static let compiled: UInt8 = 5
    }

    /// Time allowed for compiling YARA rules before the scan's limit applies.
    static let compileBudget: TimeInterval = 600

    /// Largest frame per tag the parent accepts from the child; payloads are
    /// read as they arrive, so a header alone allocates nothing.
    static func maxFrame(_ tag: UInt8) -> Int {
        switch tag {
        case Tag.readFormatFile: 64 << 10  // a path
        case Tag.compiled: 0
        default: Channel.maxFrame
        }
    }

    static let fileFD: Int32 = 3
    static let databaseFD: Int32 = 4

    private func run(
        _ op: Op, _ request: Data, file: FileHandle? = nil, database: FileHandle? = nil, scratch wantsScratch: Bool = false,
        timeout: TimeInterval, firstPhase: TimeInterval? = nil, grace: TimeInterval = SandboxedChild.grace,
        readFormatFile: (String) -> (String?, String?) = { _ in (nil, L("Only .ksy files can be read")) }
    ) throws -> Data {
        // The YARA compiler writes the rule files below a folder of its own
        // (includes resolve there); nothing else in the child can write.
        let scratch = op == .scan || wantsScratch ? try Self.makeScratch() : nil
        defer { if let scratch { try? FileManager.default.removeItem(atPath: scratch) } }

        let child = try Self.spawn(executable, scratch: scratch, file: file, database: database)
        try? file?.close()
        try? database?.close()
        defer { child.finish() }

        let envelope = try RequestCoder.encode(
            Envelope(op: op, request: request, hasFile: file != nil, hasDatabase: database != nil))
        // Every write and read is bounded by the deadline (the parent's end
        // of the request pipe does not block): a child that stops reading
        // or never answers is killed at its time limit.
        var deadline = Date().addingTimeInterval((firstPhase ?? timeout) + grace)
        let channel = child.channel
        do { try channel.send(Tag.request, envelope, deadline: deadline) } catch FrameError.timedOut {
            throw SandboxedChildError.timedOut
        } catch FrameError.tooLarge {
            throw SandboxedChildError.tooLarge
        } catch {
            // The child is gone before it read everything; its failure (if
            // it sent one) is read below.
        }
        var started = firstPhase == nil
        while true {
            let tag: UInt8, payload: Data
            do { (tag, payload) = try channel.receive(deadline: deadline, maxSize: Self.maxFrame) } catch FrameError.timedOut {
                throw SandboxedChildError.timedOut
            } catch FrameError.tooLarge(let tag) where tag != Tag.readFormatFile {
                // Not a crash: a result over the limit (or a child lying about one).
                throw SandboxedChildError.tooLarge
            } catch {
                throw SandboxedChildError.stopped
            }
            switch tag {
            case Tag.result: return payload
            case Tag.failure: throw SandboxedChildError.failed(String(decoding: payload, as: UTF8.self))
            case Tag.compiled where !started:
                started = true
                deadline = Date().addingTimeInterval(timeout + grace)
            case Tag.readFormatFile:
                let (text, error) = readFormatFile(String(decoding: payload, as: UTF8.self))
                var w = WireWriter()
                w.optional(text) { $0.string($1) }
                w.optional(error) { $0.string($1) }
                // The child asks one file at a time and waits for the answer.
                do { try channel.send(Tag.formatFile, w.data, deadline: deadline) } catch FrameError.timedOut {
                    throw SandboxedChildError.timedOut
                } catch {
                    throw SandboxedChildError.stopped
                }
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
        func check(_ rc: Int32) throws { guard rc == 0 else { throw failure(rc) } }
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
        // The parent's ends: never inherited by another process (the child
        // notices the parent's end going away, #129), and writing does not
        // block (Channel.send waits with the deadline instead).
        // (pipe() cannot set close-on-exec atomically on macOS. In the short
        // window before this, only a fork/exec without
        // POSIX_SPAWN_CLOEXEC_DEFAULT on another thread could inherit them;
        // that would only delay the child's exit after a parent crash.)
        for fd in [toChild[1], fromChild[0]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(toChild[1], F_SETFL, fcntl(toChild[1], F_GETFL) | O_NONBLOCK)
        let channel = Channel(read: fromChild[0], write: toChild[1])

        var actions: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        do {
            try check(posix_spawn_file_actions_init(&actions))
        } catch {
            channel.close()
            throw error
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        do {
            try check(posix_spawnattr_init(&attr))
        } catch {
            channel.close()
            throw error
        }
        defer { posix_spawnattr_destroy(&attr) }
        let args = [exe, argument, scratch ?? ""]
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { for a in argv { free(a) } }
        // No environment: nothing of the user's leaks in, nothing steers the child.
        var envp: [UnsafeMutablePointer<CChar>?] = [nil]
        var pid: pid_t = 0
        do {
            try check(posix_spawn_file_actions_adddup2(&actions, try high(toChild[0]), 0))
            try check(posix_spawn_file_actions_adddup2(&actions, try high(fromChild[1]), 1))
            try check(posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0))
            if let file { try check(posix_spawn_file_actions_adddup2(&actions, try high(file.fileDescriptor), fileFD)) }
            if let database {
                try check(posix_spawn_file_actions_adddup2(&actions, try high(database.fileDescriptor), databaseFD))
            }
            // Only the descriptors above reach the child.
            try check(posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)))
            try check(posix_spawn(&pid, exe, &actions, &attr, &argv, &envp))
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
        watchParent()
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

    /// The parent holds the other end of the request pipe until it is done
    /// with the child; the end going away means the parent died (a killed
    /// CLI must not leave a script or scan running). A kqueue on the pipe
    /// sees that while the work thread may be busy or reading the same pipe.
    private static func watchParent() {
        let kq = kqueue()
        guard kq >= 0 else { exit(71) }
        Probe.watcher = kq
        var ev = kevent(
            ident: 0, filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: nil)
        guard kevent(kq, &ev, 1, nil, 0, nil) == 0 else { exit(71) }
        let thread = Thread {
            var out = kevent()
            while true {
                let n = kevent(kq, nil, 0, &out, 1, nil)
                if n < 0 && errno == EINTR { continue }
                if n < 0 || out.flags & UInt16(EV_EOF) != 0 { _exit(0) }
            }
        }
        thread.start()
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
            return try HelperWork.scan(
                req, try snapshot(req.header), scratch: URL(fileURLWithPath: scratch),
                compiled: { try? channel.send(Tag.compiled, Data()) })
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
            let probe = String(decoding: e.request, as: UTF8.self)
            return Data(Probe.run(probe.replacingOccurrences(of: "%SCRATCH%", with: scratch ?? "")).utf8)
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

/// Test probes run inside the sandboxed child, and inside the test-only XPC
/// service of `make sandbox-probes` (#134): what a compromised parser
/// would try (open, write or list files, connect, start processes, look up
/// mach services, signal or inspect other processes, read hardware
/// identifiers), which descriptors it has, and a crash and a hang.
enum Probe {
    /// The child's kqueue that watches for the parent (not inherited).
    nonisolated(unsafe) static var watcher: Int32 = -1

    static func run(_ probe: String) -> String {
        let colon = probe.firstIndex(of: ":")
        let name = String(probe[..<(colon ?? probe.endIndex)])
        let arg = colon.map { String(probe[probe.index(after: $0)...]) } ?? ""
        switch name {
        case "open":
            let fd = open(arg, O_RDONLY)
            defer { if fd >= 0 { close(fd) } }
            return fd >= 0 ? "opened" : "errno \(errno)"
        case "write":
            let fd = open(arg, O_WRONLY | O_CREAT, 0o600)
            defer { if fd >= 0 { close(fd) } }
            return fd >= 0 ? "opened" : "errno \(errno)"
        case "list":
            guard let d = opendir(arg) else { return "errno \(errno)" }
            closedir(d)
            return "listed"
        case "stat":
            var st = stat()
            return stat(arg, &st) == 0 ? "ok" : "errno \(errno)"
        case "connect":
            // `connect:<port>` on 127.0.0.1, `connect:/path` to a Unix socket.
            // macOS's sandbox does not mediate creating an Internet socket,
            // only what can be done with it, so the probe connects.
            return connect(arg)
        case "fork":
            // fork() is unavailable in Swift; the child only exits.
            typealias Fork = @convention(c) () -> pid_t
            guard let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "fork") else { return "no fork" }
            let pid = unsafeBitCast(f, to: Fork.self)()
            if pid == 0 { _exit(0) }
            guard pid > 0 else { return "errno \(errno)" }
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            return "forked"
        case "exec":
            var pid: pid_t = 0
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup(arg), nil]
            defer { free(argv[0]) }
            let rc = posix_spawn(&pid, arg, nil, nil, &argv, nil)
            guard rc == 0 else { return "errno \(rc)" }
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            return "started"
        case "mach": return machLookup(arg)
        case "signal-parent":
            // Signal 0 checks permission only. The XPC service's parent is
            // launchd, so its probe names the app's process (#134).
            return kill(Int32(arg) ?? getppid(), 0) == 0 ? "sent" : "errno \(errno)"
        case "procargs":
            // argv and environment of another process.
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(arg) ?? getppid()]
            return sysctlProbe(&mib)
        case "procall":
            // Other processes in the list (the child sees itself in any case).
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return "errno \(errno)" }
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
            size = procs.count * MemoryLayout<kinfo_proc>.stride
            guard sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 else { return "errno \(errno)" }
            let others = procs.prefix(size / MemoryLayout<kinfo_proc>.stride).filter { $0.kp_proc.p_pid != getpid() }
            return others.isEmpty ? "only self" : "others"
        case "pidpath":
            var buf = [CChar](repeating: 0, count: 4096)
            let n = proc_pidpath(Int32(arg) ?? getppid(), &buf, UInt32(buf.count))
            return n > 0 ? "read" : "errno \(errno)"
        case "pidinfo":
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let n = proc_pidinfo(Int32(arg) ?? getppid(), PROC_PIDTBSDINFO, 0, &info, size)
            return n == size ? "read" : "errno \(errno)"
        case "listpids":
            // Pids of all processes (process-info-listpids).
            var pids = [pid_t](repeating: 0, count: 8192)
            let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
            guard n > 0 else { return "errno \(errno)" }
            return pids.prefix(Int(n)).contains { $0 != getpid() && $0 != 0 } ? "others" : "only self"
        case "rusage":
            // Resource usage of another process (process-info-rusage).
            var info = rusage_info_v0()
            let rc = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(Int32(arg) ?? getppid(), RUSAGE_INFO_V0, $0)
                }
            }
            return rc == 0 ? "read" : "errno \(errno)"
        case "iokit": return ioKitProperty(arg.isEmpty ? "IOPlatformSerialNumber" : arg)
        case "fds":
            // Open descriptors, apart from the watcher's kqueue.
            return (0 ..< 1024).filter { $0 != watcher && fcntl($0, F_GETFD) >= 0 }.map(String.init).joined(separator: ",")
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

    private static func sysctlProbe(_ mib: inout [Int32]) -> String {
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return "errno \(errno)" }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buf, &size, nil, 0) == 0 else { return "errno \(errno)" }
        return size > 0 ? "read" : "empty"
    }

    /// Looked up at run time, so the CLI does not link IOKit for a probe.
    private static func ioKitProperty(_ key: String) -> String {
        // IOServiceGetMatchingService consumes the matching dictionary.
        typealias Matching = @convention(c) (UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
        typealias GetService = @convention(c) (mach_port_t, UnsafeMutableRawPointer?) -> io_object_t
        typealias CreateProperty = @convention(c) (io_object_t, CFString, CFAllocator?, UInt32) -> Unmanaged<CFTypeRef>?
        guard let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
            let m = dlsym(lib, "IOServiceMatching"), let g = dlsym(lib, "IOServiceGetMatchingService"),
            let c = dlsym(lib, "IORegistryEntryCreateCFProperty")
        else { return "no IOKit" }
        let matching = unsafeBitCast(m, to: Matching.self)("IOPlatformExpertDevice")
        let service = unsafeBitCast(g, to: GetService.self)(0, matching)  // 0: kIOMainPortDefault
        guard service != 0 else { return "no service" }
        let value = unsafeBitCast(c, to: CreateProperty.self)(service, key as CFString, nil, 0)?.takeRetainedValue()
        return value == nil ? "denied" : "read"
    }

    private static func machLookup(_ name: String) -> String {
        typealias LookUp = @convention(c) (mach_port_t, UnsafePointer<CChar>, UnsafeMutablePointer<mach_port_t>) -> kern_return_t
        let all = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        guard let f = dlsym(all, "bootstrap_look_up"), let bp = dlsym(all, "bootstrap_port") else { return "no bootstrap" }
        var port: mach_port_t = 0
        let kr = unsafeBitCast(f, to: LookUp.self)(bp.load(as: mach_port_t.self), name, &port)
        return kr == KERN_SUCCESS ? "found" : "kr \(kr)"
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

enum FrameError: Error, CustomStringConvertible {
    case timedOut, closed
    /// The frame with this tag exceeds its limit.
    case tooLarge(UInt8)

    /// The child sends this text back when its result is too large.
    var description: String {
        switch self {
        case .timedOut: "timed out"
        case .closed: "closed"
        case .tooLarge: SandboxedChildError.tooLarge.description
        }
    }
}

/// Frames over a pipe pair: tag byte, 4-byte big-endian length, payload.
struct Channel: Sendable {
    let read: Int32
    let write: Int32

    /// What one frame may hold at most (a request with rules, a result).
    static let maxFrame = 1 << 30

    init(read: Int32, write: Int32) {
        self.read = read
        self.write = write
        // A child that died must not take the parent down with SIGPIPE.
        _ = fcntl(write, F_SETNOSIGPIPE, 1)
    }

    /// With a deadline the write end must be non-blocking: the time limit
    /// holds even if the other side stops reading.
    func send(_ tag: UInt8, _ payload: Data, deadline: Date? = nil) throws {
        guard payload.count <= Self.maxFrame else { throw FrameError.tooLarge(tag) }
        let n = UInt32(payload.count)
        var frame = Data([tag, UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
        frame.append(payload)
        try frame.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                if let deadline { try wait(for: write, events: POLLOUT, until: deadline) }
                let w = Darwin.write(write, buf.baseAddress! + off, buf.count - off)
                if w < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard w > 0 else { throw FrameError.closed }
                off += w
            }
        }
    }

    /// `maxSize` limits the payload per tag; the payload grows as it arrives.
    func receive(deadline: Date?, maxSize: (UInt8) -> Int = { _ in Channel.maxFrame }) throws -> (UInt8, Data) {
        let head = try readExactly(5, deadline: deadline)
        let n = head.dropFirst().reduce(0) { $0 << 8 | Int($1) }
        let tag = head[head.startIndex]
        guard n <= min(maxSize(tag), Self.maxFrame) else { throw FrameError.tooLarge(tag) }
        return (tag, try readExactly(n, deadline: deadline))
    }

    private func readExactly(_ n: Int, deadline: Date?) throws -> Data {
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: min(n, 1 << 20))
        while out.count < n {
            if let deadline { try wait(for: read, events: POLLIN, until: deadline) }
            let got = chunk.withUnsafeMutableBytes { Darwin.read(read, $0.baseAddress!, min($0.count, n - out.count)) }
            if got < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard got > 0 else { throw FrameError.closed }
            out.append(contentsOf: chunk[..<got])
        }
        return out
    }

    private func wait(for fd: Int32, events: Int32, until deadline: Date) throws {
        while true {
            let ms = deadline.timeIntervalSinceNow * 1000
            guard ms > 0 else { throw FrameError.timedOut }
            var p = pollfd(fd: fd, events: Int16(events), revents: 0)
            let r = poll(&p, 1, Int32(min(ms.rounded(.up), Double(Int32.max))))
            if r < 0 && errno == EINTR { continue }
            guard r >= 0 else { throw FrameError.closed }
            // Ready, or the other end closed (the read or write then says so).
            if r > 0 { return }
        }
    }

    func close() {
        Darwin.close(read)
        Darwin.close(write)
    }
}
