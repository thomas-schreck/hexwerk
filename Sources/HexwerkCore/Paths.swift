import Foundation

/// Where hexwerk keeps its files: everything under `~/.config/hexwerk`
/// (or `$XDG_CONFIG_HOME/hexwerk`), so it sits with the other dotfiles.
public enum HexwerkPaths {
    public static let config: URL = {
        if let env = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env).appendingPathComponent("hexwerk")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/hexwerk")
    }()

    /// Kaitai format collection (`make formats`).
    public static var formats: URL { config.appendingPathComponent("formats") }
    /// Own and translated `.ksy` files; they win over the collection.
    public static var ksy: URL { config.appendingPathComponent("ksy") }
    public static var yara: URL { config.appendingPathComponent("yara") }
    public static var scripts: URL { config.appendingPathComponent("scripts") }
    /// Fallback for per-file state that has no `.hexwerk` file next to it.
    public static var projects: URL { config.appendingPathComponent("projects") }
    public static var settings: URL { config.appendingPathComponent("settings.json") }
}
