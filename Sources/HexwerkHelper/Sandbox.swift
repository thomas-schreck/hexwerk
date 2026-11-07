import Foundation

/// The sandbox the CLI's child process enters before it reads any input
/// (#129). The XPC helper of the app gets the App Sandbox from its
/// entitlements instead; a command line tool has no bundle for that, so the
/// child applies a profile of its own with `sandbox_init`.
///
/// Everything is denied that is not listed: no network, no mach services,
/// no other processes, no file system. The child works on descriptors the
/// parent opened for it and, for YARA only, on a fresh scratch folder the
/// parent created and deletes afterwards (the rule files are written there
/// so includes resolve). The libraries are loaded before the profile applies.
/// What is allowed, and why:
/// - sysctl-read: wasmtime (YARA-X) asks for the page size and aborts without it.
/// - /usr/share/icu: JavaScriptCore loads its Unicode data lazily.
/// JIT code (wasmtime, JavaScriptCore) needs no rule here; it is governed by
/// the Hardened Runtime entitlements of the signed binary (cli.entitlements).
public enum Sandbox {
    static func profile(scratch: String?) -> String {
        var p = """
            (version 1)
            (deny default)
            (allow sysctl-read)
            (allow file-read* (subpath "/usr/share/icu"))

            """
        if let scratch {
            p += "(allow file-read* file-write* (subpath \(literal(scratch))))\n"
            // YARA-X resolves include paths, which looks at every folder above.
            var ancestors: [String] = []
            var dir = (scratch as NSString).deletingLastPathComponent
            while true {
                ancestors.append(literal(dir))
                if dir == "/" { break }
                dir = (dir as NSString).deletingLastPathComponent
            }
            p += "(allow file-read-metadata (literal \(ancestors.joined(separator: ") (literal "))))\n"
        }
        return p
    }

    /// An SBPL string literal.
    static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Enters the sandbox for the rest of the process's life.
    public static func enter(scratch: String?) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sandbox_init(profile(scratch: scratch), 0, &error) == 0 else {
            let message = error.map { String(cString: $0) } ?? "sandbox_init failed"
            if let error { sandbox_free_error(error) }
            throw HelperError.failed(message)
        }
    }
}

// sandbox.h marks these deprecated (and Swift does not import them); they
// remain the documented way for a process to sandbox itself with a profile
// string (flags 0), used by Chromium and others.
@_silgen_name("sandbox_init")
private func sandbox_init(
    _ profile: UnsafePointer<CChar>, _ flags: UInt64, _ errorbuf: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("sandbox_free_error")
private func sandbox_free_error(_ errorbuf: UnsafeMutablePointer<CChar>)
