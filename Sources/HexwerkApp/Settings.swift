import Foundation
import HexwerkCore

/// App settings as plain JSON in `~/.config/hexwerk/settings.json` instead
/// of the macOS preferences plist, so they can be read, edited and kept in
/// dotfiles. Same small API as UserDefaults for the few calls hexwerk makes.
final class Settings: @unchecked Sendable {
    static let shared = Settings()

    /// Keys hexwerk used to keep in UserDefaults; copied over once.
    private static let legacyKeys = [
        "sidebarTab", "checksums", "vimMode", "yaraRules", "yaraTimeout",
        "scriptSource", "imageFormat", "imageWidth", "stringsMin",
    ]

    private let url: URL
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    /// Writes are coalesced: the script editor sets a value per keystroke.
    private let writer = Debouncer(delay: .milliseconds(500), label: "hexwerk.settings")

    init(url: URL = HexwerkPaths.settings) {
        self.url = url
        if let data = try? Data(contentsOf: url),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            values = dict
        } else {
            for key in Self.legacyKeys {
                if let v = UserDefaults.standard.object(forKey: key) { values[key] = v }
            }
            if !values.isEmpty { save() }
        }
    }

    func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }

    func set(_ value: Any?, forKey key: String) {
        lock.withLock { values[key] = value }
        writer.schedule { [weak self] in self?.save() }
    }

    /// Writes a pending change now (called before the app quits).
    func flush() { writer.flush() }

    private func save() {
        let data: Data? = lock.withLock {
            try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        }
        guard let data else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
