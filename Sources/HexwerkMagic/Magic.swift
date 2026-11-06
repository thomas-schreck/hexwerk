internal import CMagic
import Foundation
import HexwerkCore

/// File type description via libmagic, like `file` (SPEC FR-10.2).
public enum Magic {
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

    private static func run(_ snap: Snapshot, flags: Int32) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let cookie = cookie(flags) else { return nil }
        // Compressed/decompress checks and external programs stay off: input is untrusted.
        return snap.withContiguousBytes(0 ..< min(snap.count, window)) { buf in
            // Multi-part results (fat binaries) come with escaped newlines.
            magic_buffer(cookie, buf.baseAddress, buf.count).map {
                String(cString: $0).replacingOccurrences(of: "\\012- ", with: "").replacingOccurrences(of: "\\012-", with: "")
            }
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
