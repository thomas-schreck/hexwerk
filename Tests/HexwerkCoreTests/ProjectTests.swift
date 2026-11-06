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
        #expect(try ProjectStore.save(s, for: file, in: dir)?.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path)
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

    @Test func toleratesMissingAndBrokenFiles() throws {
        let url = try tempFile(Data("{not json".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ProjectStore.load(url) == nil)
        #expect(ProjectStore.load(URL(fileURLWithPath: "/nonexistent/x.json")) == nil)
    }
}
