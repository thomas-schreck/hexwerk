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

extension ProjectState {
    /// Synthesized decoding requires every key, even those with defaults, so
    /// an older or hand-edited project without e.g. `offsetBase` would not
    /// load at all. Only the file identity is required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filePath = try c.decode(String.self, forKey: .filePath)
        fileSize = try c.decode(UInt64.self, forKey: .fileSize)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        bookmarks = try c.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? []
        format = try c.decodeIfPresent(Format.self, forKey: .format)
        yaraRules = try c.decodeIfPresent([String].self, forKey: .yaraRules) ?? []
        cursor = try c.decodeIfPresent(UInt64.self, forKey: .cursor) ?? 0
        selectionStart = try c.decodeIfPresent(UInt64.self, forKey: .selectionStart)
        selectionEnd = try c.decodeIfPresent(UInt64.self, forKey: .selectionEnd)
        offsetBase = try c.decodeIfPresent(UInt64.self, forKey: .offsetBase) ?? 0
    }
}

public enum ProjectError: Error, CustomStringConvertible, LocalizedError {
    /// The file exists but cannot be read or decoded.
    case unreadable(URL, String)

    public var description: String {
        switch self {
        case .unreadable(let url, let detail):
            L("Project file %@ could not be read and is left unchanged: %@", url.path, detail)
        }
    }
    public var errorDescription: String? { description }
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
        (try? read(url)) ?? nil
    }

    /// Like `load(for:in:)`, but a project file that exists and cannot be
    /// read throws, so the caller can tell the user.
    public static func read(for file: URL, in dir: URL = directory) throws -> ProjectState? {
        try read(sidecar(for: file)) ?? read(url(for: file, in: dir))
    }

    /// nil if there is no file; throws if there is one that does not decode.
    public static func read(_ url: URL) throws -> ProjectState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(ProjectState.self, from: try Data(contentsOf: url))
        } catch {
            throw ProjectError.unreadable(url, error.localizedDescription)
        }
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

    /// Returns where the state went (nil: nothing to keep). Throws without
    /// touching anything if an existing project file cannot be read: it may
    /// hold bookmarks this version could not load, and overwriting it with
    /// the (empty) current state would lose them.
    @discardableResult
    public static func save(_ state: ProjectState, for file: URL, in dir: URL = directory) throws -> URL? {
        let side = sidecar(for: file)
        let central = url(for: file, in: dir)
        _ = try read(side)
        _ = try read(central)
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

extension Range where Bound == UInt64 {
    /// Where a marked range (bookmark) ends up after `edited` was replaced
    /// by `newLength` bytes, so it keeps marking the same data. Bytes after
    /// the edit move by the length change; ends inside the edit stay within
    /// the new bytes; an insert exactly at the start pushes the range back.
    /// Nil when nothing of the range is left (its bytes were deleted).
    public func adjustedForEdit(replacing edited: Range<UInt64>, newLength: UInt64) -> Range<UInt64>? {
        func inside(_ p: UInt64) -> UInt64 { edited.lowerBound + Swift.min(p - edited.lowerBound, newLength) }
        func shifted(_ p: UInt64) -> UInt64 { p - UInt64(edited.count) + newLength }
        let start = lowerBound < edited.lowerBound ? lowerBound
            : lowerBound >= edited.upperBound ? shifted(lowerBound) : inside(lowerBound)
        let end = upperBound <= edited.lowerBound ? upperBound
            : upperBound >= edited.upperBound ? shifted(upperBound) : inside(upperBound)
        return start < end ? start ..< end : nil
    }

    /// The part of the range inside a document of `count` bytes, nil if none.
    public func clampedToDocument(count: UInt64) -> Range<UInt64>? {
        let r = clamped(to: 0 ..< count)
        return r.isEmpty ? nil : r
    }
}
