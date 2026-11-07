import Foundation

/// Version of the running binary. The app reads it from its bundle's
/// Info.plist; the CLI has no bundle, so `make` links a small Info.plist into
/// its `__TEXT,__info_plist` section, which `Bundle.main` reads the same way.
/// A plain `swift build` has neither and reports `dev`.
public struct BuildInfo: Equatable, Sendable {
    public let version: String
    public let build: String?
    public let commit: String?

    public init(version: String, build: String?, commit: String?) {
        self.version = version
        self.build = build
        self.commit = commit
    }

    public init(infoDictionary info: [String: Any]?) {
        func value(_ key: String) -> String? {
            guard let s = info?[key] as? String, !s.isEmpty else { return nil }
            return s
        }
        self.init(
            version: value("CFBundleShortVersionString") ?? "dev",
            build: value("CFBundleVersion"),
            commit: value("HexwerkCommit")
        )
    }

    public static let current = BuildInfo(infoDictionary: Bundle.main.infoDictionary)

    /// Build number and commit, e.g. `build 12, f0ff933`; nil when both are unknown.
    public var details: String? {
        let parts = [build.map { L("build %@", $0) }, commit].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// One line for `--version`, e.g. `0.1.0 (build 12, f0ff933)`.
    public var summary: String {
        details.map { "\(version) (\($0))" } ?? version
    }
}
