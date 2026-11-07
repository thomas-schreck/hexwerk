internal import CMagic
import Foundation
import HexwerkCore

/// File type description via libmagic, like `file`.
public enum Magic {
    /// Version of the linked libmagic, e.g. `5.46`.
    public static var version: String {
        let v = magic_version()
        return "\(v / 100).\(String(format: "%02d", v % 100))"
    }

    /// Database search order: $HEXWERK_MAGIC, the app bundle, next to the executable, Homebrew.
    public static var databasePath: String? {
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["HEXWERK_MAGIC"] { candidates.append(env) }
        if let res = Bundle.main.resourcePath { candidates.append(res + "/magic.mgc") }
        // CLI from the release tarball: magic.mgc sits next to the binary.
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent("magic.mgc").path)
        }
        candidates.append("/Applications/hexwerk.app/Contents/Resources/magic.mgc")
        candidates += ["/opt/homebrew/share/misc/magic.mgc", "/usr/local/share/misc/magic.mgc"]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// libmagic's cookies are not thread safe; one per flag set, used under a lock.
    nonisolated(unsafe) private static var cookies: [Int32: OpaquePointer] = [:]
    private static let lock = NSLock()

    /// Bytes looked at: libmagic needs the start of the file (and for some
    /// formats a bit more); 1 MiB covers its default limits.
    static let window: UInt64 = 1 << 20

    /// Human-readable description, e.g. "ELF 64-bit LSB executable, ARM aarch64 …".
    public static func describe(_ snap: Snapshot) -> String? { run(snap, flags: MAGIC_NONE) }

    /// MIME type with charset, e.g. "application/x-executable; charset=binary".
    public static func mime(_ snap: Snapshot) -> String? { run(snap, flags: MAGIC_MIME) }

    /// The bytes libmagic looks at: the start of the snapshot.
    public static func sample(_ snap: Snapshot) -> Data { snap.read(0 ..< min(snap.count, window)) }

    private static func run(_ snap: Snapshot, flags: Int32) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let cookie = cookie(flags) else { return nil }
        // Compressed/decompress checks and external programs stay off: input is untrusted.
        return snap.withContiguousBytes(0 ..< min(snap.count, window)) { query(cookie, $0) }
    }

    static func query(_ cookie: OpaquePointer, _ buf: UnsafeRawBufferPointer) -> String? {
        // Multi-part results (fat binaries) come with escaped newlines.
        magic_buffer(cookie, buf.baseAddress, buf.count).map {
            String(cString: $0).replacingOccurrences(of: "\\012- ", with: "").replacingOccurrences(of: "\\012-", with: "")
        }
    }

    private static func cookie(_ flags: Int32) -> OpaquePointer? {
        if let c = cookies[flags] { return c }
        guard let path = databasePath, let c = magic_open(flags | MAGIC_ERROR) else { return nil }
        guard magic_load(c, path) == 0 else { magic_close(c); return nil }
        cookies[flags] = c
        return c
    }
}

/// A libmagic database loaded from memory, for the sandboxed processes (#129)
/// that cannot open `magic.mgc` by path: they get it as a descriptor.
public final class MagicDatabase: @unchecked Sendable {
    /// libmagic keeps pointers into the buffer for the cookies' lifetime.
    private let buffer: UnsafeMutableRawBufferPointer
    private var cookies: [Int32: OpaquePointer] = [:]
    private let lock = NSLock()

    /// Upper bound for the database (Homebrew's is about 11 MiB).
    static let maxSize = 256 << 20

    /// nil if the data is empty or too large; a bad database shows up as nil results.
    public init?(_ data: Data) {
        guard !data.isEmpty, data.count <= Self.maxSize else { return nil }
        buffer = .allocate(byteCount: data.count, alignment: 16)
        data.copyBytes(to: buffer)
    }

    /// Reads the whole database from `handle` (positioned at its start).
    public convenience init?(handle: FileHandle) {
        guard let data = try? handle.readToEnd() else { return nil }
        self.init(data)
    }

    deinit {
        for c in cookies.values { magic_close(c) }
        buffer.deallocate()
    }

    /// Like `Magic.describe`, on the sample from `Magic.sample`.
    public func describe(_ sample: Data) -> String? { run(sample, flags: MAGIC_NONE) }

    /// Like `Magic.mime`, on the sample from `Magic.sample`.
    public func mime(_ sample: Data) -> String? { run(sample, flags: MAGIC_MIME) }

    private func run(_ sample: Data, flags: Int32) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let cookie = cookie(flags) else { return nil }
        return sample.prefix(Int(Magic.window)).withUnsafeBytes { Magic.query(cookie, $0) }
    }

    private func cookie(_ flags: Int32) -> OpaquePointer? {
        if let c = cookies[flags] { return c }
        guard let c = magic_open(flags | MAGIC_ERROR) else { return nil }
        var ptr: UnsafeMutableRawPointer? = buffer.baseAddress
        var size = buffer.count
        guard magic_load_buffers(c, &ptr, &size, 1) == 0 else { magic_close(c); return nil }
        cookies[flags] = c
        return c
    }
}
