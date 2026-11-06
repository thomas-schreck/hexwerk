import Foundation
import Testing
@testable import HexwerkCore

@Suite struct ImportCacheTests {
    let cache = ImportCache(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("hexwerk-import-\(UUID().uuidString)"))

    /// Leftovers of earlier imports are removed on quit and at launch (#32).
    @Test func removeAllDeletesEveryImportFolder() throws {
        defer { try? FileManager.default.removeItem(at: cache.root) }
        let a = try cache.makeDirectory(), b = try cache.makeDirectory()
        #expect(a != b)
        try Data([1, 2, 3]).write(to: a.appendingPathComponent("fw.bin"))
        try Data([4]).write(to: b.appendingPathComponent("boot.bin"))
        cache.removeAll()
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.root.path).isEmpty)
        // Usable again afterwards.
        #expect(FileManager.default.fileExists(atPath: try cache.makeDirectory().path))
    }

    @Test func removeAllWithoutRootIsHarmless() {
        cache.removeAll()
        #expect(!FileManager.default.fileExists(atPath: cache.root.path))
    }
}
