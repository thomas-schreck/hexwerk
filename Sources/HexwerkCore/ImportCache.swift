import Foundation

/// Folders holding the binary image of an imported Intel HEX / S-Record
/// file while its window is open. The app removes a folder when the window
/// closes; `removeAll` catches what is left on quit or after a crash.
public struct ImportCache: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// `~/Library/Caches/hexwerk/import`.
    public static var user: ImportCache {
        ImportCache(
            root: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("hexwerk/import"))
    }

    /// A new, empty folder for one import.
    public func makeDirectory() throws -> URL {
        let dir = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Removes every import folder. Images still mapped by open documents
    /// stay readable until they are closed (the mapping outlives the name).
    public func removeAll() {
        let fm = FileManager.default
        for entry in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: entry)
        }
    }
}
