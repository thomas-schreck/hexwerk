import Foundation
import Testing
@testable import HexwerkCore

@Suite struct DocumentTests {
    let original: Data = {
        var rng = SplitMix(seed: 42)
        return Data((0..<4096).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }()

    @Test func overwriteInsertDelete() throws {
        let url = try tempFile(Data([0, 1, 2, 3, 4, 5]))
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try Document(url: url)

        try doc.overwrite(at: 1, with: Data([0xAA, 0xBB]))
        #expect(doc.read(0..<6) == Data([0, 0xAA, 0xBB, 3, 4, 5]))
        try doc.insert(Data([9, 9]), at: 0)
        #expect(doc.read(0..<8) == Data([9, 9, 0, 0xAA, 0xBB, 3, 4, 5]))
        try doc.delete(2..<4)
        #expect(doc.read(0..<100) == Data([9, 9, 0xBB, 3, 4, 5]))
        try doc.insert(Data([7]), at: doc.count)            // append
        #expect(doc.read(0..<100).last == 7)
        try doc.overwrite(at: doc.count - 1, with: Data([1, 2]))  // runs past the end
        #expect(doc.read(0..<100) == Data([9, 9, 0xBB, 3, 4, 5, 1, 2]))
        #expect(doc.count == 8)
    }

    @Test func outOfRangeIsRejected() throws {
        let url = try tempFile(Data([1, 2, 3]))
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try Document(url: url)
        #expect(throws: DocumentError.self) { try doc.insert(Data([1]), at: 4) }
    }

    @Test func emptyDocument() throws {
        let url = try tempFile(Data())
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try Document(url: url)
        try doc.insert(Data([1, 2]), at: 0)
        #expect(doc.read(0..<10) == Data([1, 2]))
    }

    /// TC-1.5 / TC-2.1: random edits must match a plain Data model, and
    /// undoing everything must give back the original.
    @Test(arguments: 1...20) func randomEditsMatchModel(seed: Int) throws {
        var rng = SplitMix(seed: UInt64(seed))
        let url = try tempFile(original)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try Document(url: url)
        var model = original

        for _ in 0..<200 {
            let n = UInt64(model.count)
            let a = UInt64.random(in: 0...n, using: &rng)
            let b = min(n, a + UInt64.random(in: 0...16, using: &rng))
            let bytes = Data((0..<Int.random(in: 0...16, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
            try doc.replace(a..<b, with: bytes)
            model.replaceSubrange(Int(a)..<Int(b), with: bytes)
            #expect(doc.count == UInt64(model.count))
        }
        #expect(doc.read(0..<doc.count) == model)
        // Random sub-ranges read correctly across piece boundaries.
        for _ in 0..<50 {
            let a = Int.random(in: 0...model.count, using: &rng)
            let b = min(model.count, a + Int.random(in: 0...300, using: &rng))
            #expect(doc.read(UInt64(a)..<UInt64(b)) == model.subdata(in: a..<b))
        }
        while doc.canUndo { doc.undo() }
        #expect(doc.read(0..<doc.count) == original)
        #expect(!doc.isModified)
        doc.redo()
        #expect(doc.isModified)
    }

    @Test func readOnlyRejectsEdits() throws {
        let url = try tempFile(Data([1, 2, 3]))
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try Document(url: url, readOnly: true)
        #expect(throws: DocumentError.self) { try doc.overwrite(at: 0, with: Data([9])) }
        #expect(throws: DocumentError.self) { try doc.save() }
    }

    /// TC-1.6: in-place save changes exactly the edited bytes.
    @Test func saveInPlaceWritesOnlyChanges() throws {
        let url = try tempFile(original)
        defer { try? FileManager.default.removeItem(at: url) }
        let inode = try inodeOf(url)
        let doc = try Document(url: url)
        try doc.overwrite(at: 100, with: Data([1, 2, 3]))
        try doc.overwrite(at: 4000, with: Data([4]))
        try doc.save(mode: .inPlace)

        var expected = original
        expected.replaceSubrange(100..<103, with: [1, 2, 3])
        expected[4000] = 4
        #expect(try Data(contentsOf: url) == expected)
        #expect(try inodeOf(url) == inode)      // really in place
        #expect(!doc.isModified)
        #expect(!doc.canUndo)
    }

    @Test func inPlaceRefusesLengthChange() throws {
        let url = try tempFile(original)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try Document(url: url)
        try doc.insert(Data([1]), at: 0)
        #expect(throws: DocumentError.self) { try doc.save(mode: .inPlace) }
        #expect(try Data(contentsOf: url) == original)
    }

    /// TC-2.2: atomic save with length change, permissions kept.
    @Test func saveAtomic() throws {
        let url = try tempFile(original)
        defer { try? FileManager.default.removeItem(at: url) }
        chmod(url.path, 0o600)
        let doc = try Document(url: url)
        try doc.insert(Data([0xFF, 0xFE]), at: 10)
        try doc.delete(2000..<3000)
        let expected = doc.read(0..<doc.count)
        try doc.save()

        #expect(try Data(contentsOf: url) == expected)
        #expect(doc.read(0..<doc.count) == expected)
        var st = stat()
        stat(url.path, &st)
        #expect(st.st_mode & 0o777 == 0o600)
        // No temp file left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.contains(url.lastPathComponent + ".hexwerk-") }
        #expect(leftovers.isEmpty)
    }

    /// TC-1.7: a failing save leaves the original untouched.
    @Test func failedSaveKeepsOriginal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hexwerk-ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("f.bin")
        try original.write(to: url)
        chmod(dir.path, 0o500)                    // no new files allowed
        defer {
            chmod(dir.path, 0o700)
            try? FileManager.default.removeItem(at: dir)
        }
        let doc = try Document(url: url)
        try doc.insert(Data([1]), at: 0)
        #expect(throws: DocumentError.self) { try doc.save() }
        #expect(try Data(contentsOf: url) == original)
        #expect(doc.isModified)                   // edits survive the failure
    }

    @Test func saveAsSwitchesFile() throws {
        let url = try tempFile(Data([1, 2, 3]))
        let other = url.appendingPathExtension("copy")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: other)
        }
        let doc = try Document(url: url)
        try doc.overwrite(at: 0, with: Data([9]))
        try doc.save(as: other)
        #expect(doc.url == other)
        #expect(try Data(contentsOf: other) == Data([9, 2, 3]))
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
    }

    @Test func detectsExternalChange() throws {
        let url = try tempFile(Data([1, 2, 3]))
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try Document(url: url)
        #expect(!doc.hasChangedOnDisk())
        try Data([1, 2, 3, 4]).write(to: url)
        #expect(doc.hasChangedOnDisk())
    }

    @Test func modifiedRanges() throws {
        let url = try tempFile(original)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try Document(url: url)
        try doc.overwrite(at: 10, with: Data([1, 2]))
        #expect(doc.modifiedRanges == [10..<12])
    }
}

private func inodeOf(_ url: URL) throws -> UInt64 {
    var st = stat()
    stat(url.path, &st)
    return UInt64(st.st_ino)
}

/// Deterministic RNG so failing random tests can be reproduced.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
