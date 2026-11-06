import Foundation
import Testing
@testable import HexwerkCore

@Suite struct ProjectTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hexwerk-proj-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func centralFallbackKeyedByPath() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Folder does not exist, so no sidecar is possible: central store.
        let file = URL(fileURLWithPath: "/nonexistent-hexwerk/a/../a/firmware.bin")
        var s = ProjectState(filePath: file.path, fileSize: 1234)
        s.bookmarks = [.init(name: "Header", start: 0, end: 16, color: 2)]
        s.format = .init(path: "/x/elf.ksy", title: "ELF")
        s.cursor = 42
        s.selectionStart = 40; s.selectionEnd = 50
        s.offsetBase = 0x0800_0000
        #expect(
            try ProjectStore.save(s, for: file, in: dir)?.deletingLastPathComponent().standardizedFileURL.path
                == dir.standardizedFileURL.path)
        // The same file under another spelling finds the same state.
        #expect(ProjectStore.load(for: URL(fileURLWithPath: "/nonexistent-hexwerk/a/firmware.bin"), in: dir) == s)
        #expect(ProjectStore.load(for: URL(fileURLWithPath: "/nonexistent-hexwerk/b.bin"), in: dir) == nil)
        // Trivial state removes the file.
        try ProjectStore.save(ProjectState(filePath: file.path, fileSize: 1), for: file, in: dir)
        #expect(ProjectStore.load(for: file, in: dir) == nil)
    }

    @Test func sidecarNextToFile() throws {
        let central = try tempDir(), folder = try tempDir()
        defer { for d in [central, folder] { try? FileManager.default.removeItem(at: d) } }
        let file = folder.appendingPathComponent("dump.bin")
        try Data([1, 2, 3]).write(to: file)
        let side = folder.appendingPathComponent("dump.bin.hexwerk")

        // Cursor alone: nothing appears next to the file.
        var s = ProjectState(filePath: file.path, fileSize: 3)
        s.cursor = 2
        #expect(try ProjectStore.save(s, for: file, in: central) == ProjectStore.url(for: file, in: central))
        #expect(!FileManager.default.fileExists(atPath: side.path))

        // A bookmark moves the state next to the file; the fallback goes away.
        s.bookmarks = [.init(name: "x", start: 0, end: 1, color: 0)]
        #expect(try ProjectStore.save(s, for: file, in: central)?.standardizedFileURL == side.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: ProjectStore.url(for: file, in: central).path))
        #expect(ProjectStore.load(for: file, in: central) == s)

        // Once there, it stays and keeps being updated.
        s.bookmarks = []
        try ProjectStore.save(s, for: file, in: central)
        #expect(ProjectStore.load(side) == s)

        // Moved folder: the project still finds its sibling.
        var moved = s
        moved.filePath = "/old/place/dump.bin"
        #expect(ProjectStore.target(of: side, moved).standardizedFileURL == file.standardizedFileURL)
    }

    /// Issue #24: keys with defaults may be missing (older or hand-edited files).
    @Test func decodesFilesWithoutOptionalKeys() throws {
        let json = #"{"filePath": "/x/fw.bin", "fileSize": 10, "bookmarks": [{"name": "h", "start": 0, "end": 4, "color": 1}]}"#
        let url = try tempFile(Data(json.utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let s = try #require(ProjectStore.load(url))
        #expect(s.bookmarks.count == 1)
        #expect(s.offsetBase == 0 && s.cursor == 0 && s.version == 1 && s.yaraRules.isEmpty)
    }

    /// Issue #24: a sidecar that does not decode is reported, never overwritten.
    @Test func unreadableSidecarIsNotOverwritten() throws {
        let central = try tempDir(), folder = try tempDir()
        defer { for d in [central, folder] { try? FileManager.default.removeItem(at: d) } }
        let file = folder.appendingPathComponent("dump.bin")
        try Data([1, 2, 3]).write(to: file)
        let side = ProjectStore.sidecar(for: file)
        let broken = Data(#"{"filePath": 42, "bookmarks": "from a future version"}"#.utf8)
        try broken.write(to: side)

        #expect(throws: ProjectError.self) { try ProjectStore.read(for: file, in: central) }
        var s = ProjectState(filePath: file.path, fileSize: 3)
        s.cursor = 1
        #expect(throws: ProjectError.self) { try ProjectStore.save(s, for: file, in: central) }
        #expect(try Data(contentsOf: side) == broken)
        #expect(!FileManager.default.fileExists(atPath: ProjectStore.url(for: file, in: central).path))
    }

    @Test func toleratesMissingAndBrokenFiles() throws {
        let url = try tempFile(Data("{not json".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ProjectStore.load(url) == nil)
        #expect(ProjectStore.load(URL(fileURLWithPath: "/nonexistent/x.json")) == nil)
    }
}

/// #30: bookmarks follow their data across inserts and deletes.
@Suite struct BookmarkShiftTests {
    let mark: Range<UInt64> = 0x100 ..< 0x110

    @Test func insertBeforeMovesIt() {
        #expect(mark.adjustedForEdit(replacing: 0 ..< 0, newLength: 4) == 0x104 ..< 0x114)
        // Insert exactly at the start pushes it back too.
        #expect(mark.adjustedForEdit(replacing: 0x100 ..< 0x100, newLength: 2) == 0x102 ..< 0x112)
    }

    @Test func editsAfterOrOverwritesLeaveIt() {
        #expect(mark.adjustedForEdit(replacing: 0x110 ..< 0x110, newLength: 8) == mark)  // insert at end
        #expect(mark.adjustedForEdit(replacing: 0x200 ..< 0x300, newLength: 0) == mark)
        #expect(mark.adjustedForEdit(replacing: 0x0F0 ..< 0x120, newLength: 0x30) == mark)  // same-length overwrite
    }

    @Test func deleteBeforeAndInside() {
        #expect(mark.adjustedForEdit(replacing: 0 ..< 0x10, newLength: 0) == 0xF0 ..< 0x100)
        #expect(mark.adjustedForEdit(replacing: 0x104 ..< 0x108, newLength: 0) == 0x100 ..< 0x10C)
        #expect(mark.adjustedForEdit(replacing: 0x0F8 ..< 0x104, newLength: 0) == 0x0F8 ..< 0x104)  // head cut off
        #expect(mark.adjustedForEdit(replacing: 0x108 ..< 0x200, newLength: 0) == 0x100 ..< 0x108)  // truncated
        #expect(mark.adjustedForEdit(replacing: 0x0 ..< 0x200, newLength: 0) == nil)  // all gone
    }

    @Test func insertInsideGrowsIt() {
        #expect(mark.adjustedForEdit(replacing: 0x108 ..< 0x108, newLength: 4) == 0x100 ..< 0x114)
    }

    @Test func clampAfterTruncation() {
        #expect(mark.clampedToDocument(count: 0x108) == 0x100 ..< 0x108)
        #expect(mark.clampedToDocument(count: 0x100) == nil)
        #expect(mark.clampedToDocument(count: 0x1000) == mark)
    }

    /// The document reports each applied edit, so a mark follows it.
    @Test func documentReportsEdits() throws {
        let url = try tempFile(Data(count: 0x200))
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try Document(url: url)
        var b: Range<UInt64>? = mark
        doc.didReplace = { r, n in b = b?.adjustedForEdit(replacing: r, newLength: n) }
        try doc.insert(Data([1, 2, 3, 4]), at: 0)
        #expect(b == 0x104 ..< 0x114)
        try doc.replaceAll([0 ..< 2, 0x50 ..< 0x52], with: Data())
        #expect(b == 0x100 ..< 0x110)
        try doc.delete(0x108 ..< doc.count)
        #expect(b == 0x100 ..< 0x108)
    }
}
