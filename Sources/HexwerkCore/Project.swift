import CryptoKit
import Foundation

/// Per-file working state (SPEC FR-10.7): remembered automatically and
/// exportable as a `.hexwerk` project file.
public struct ProjectState: Codable, Sendable, Equatable {
    public struct Bookmark: Codable, Sendable, Equatable {
        public var name: String
        public var start: UInt64
        public var end: UInt64
        public var color: Int
        public init(name: String, start: UInt64, end: UInt64, color: Int) {
            self.name = name; self.start = start; self.end = end; self.color = color
        }
    }

    public struct Format: Codable, Sendable, Equatable {
        public var path: String
        public var title: String
        public init(path: String, title: String) { self.path = path; self.title = title }
    }

    public var version = 1
    public var filePath: String
    public var fileSize: UInt64
    public var bookmarks: [Bookmark] = []
    public var format: Format?
    public var yaraRules: [String] = []
    public var cursor: UInt64 = 0
    public var selectionStart: UInt64?
    public var selectionEnd: UInt64?
    public var offsetBase: UInt64 = 0

    public init(filePath: String, fileSize: UInt64) {
        self.filePath = filePath
        self.fileSize = fileSize
    }

    /// Nothing worth remembering beyond the cursor.
    public var isTrivial: Bool {
        bookmarks.isEmpty && format == nil && yaraRules.isEmpty && cursor == 0 && selectionStart == nil
    }
}

/// Per-file state lives in `<file>.hexwerk` next to the file as soon as
/// there is something worth keeping (bookmarks) or that file already exists.
/// Cursor and auto-detected format alone go to a central fallback, so merely
/// looking at a file leaves nothing behind in its folder; read-only folders
/// fall back the same way.
public enum ProjectStore {
    public static let directory = HexwerkPaths.projects
    public static let fileExtension = "hexwerk"

    /// `firmware.bin` → `firmware.bin.hexwerk`.
    public static func sidecar(for file: URL) -> URL {
        file.standardizedFileURL.appendingPathExtension(fileExtension)
    }

    /// Central fallback: one JSON per path (hash, so no characters clash).
    public static func url(for file: URL, in dir: URL = directory) -> URL {
        let key = SHA256.hash(data: Data(file.standardizedFileURL.path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(key + ".json")
    }

    public static func load(for file: URL, in dir: URL = directory) -> ProjectState? {
        load(sidecar(for: file)) ?? load(url(for: file, in: dir))
    }

    public static func load(_ url: URL) -> ProjectState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProjectState.self, from: data)
    }

    /// The file a project belongs to: the sibling without `.hexwerk` if it
    /// exists (the folder may have moved), else the recorded path.
    public static func target(of project: URL, _ state: ProjectState) -> URL {
        if project.pathExtension.lowercased() == fileExtension {
            let sibling = project.deletingPathExtension()
            if FileManager.default.fileExists(atPath: sibling.path) { return sibling }
        }
        return URL(fileURLWithPath: state.filePath)
    }

    /// Returns where the state went (nil: nothing to keep).
    @discardableResult
    public static func save(_ state: ProjectState, for file: URL, in dir: URL = directory) throws -> URL? {
        let side = sidecar(for: file)
        let central = url(for: file, in: dir)
        let fm = FileManager.default
        if fm.fileExists(atPath: side.path) || !state.bookmarks.isEmpty {
            if (try? write(state, to: side)) != nil {
                try? fm.removeItem(at: central)
                return side
            }
        }
        if state.isTrivial {
            try? fm.removeItem(at: central)
            return nil
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try write(state, to: central)
        return central
    }

    public static func write(_ state: ProjectState, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(state).write(to: url, options: .atomic)
    }
}
