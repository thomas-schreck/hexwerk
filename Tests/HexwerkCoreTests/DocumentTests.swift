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

    /// Random edits must match a plain Data model, and
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

    /// #17: with many pieces (after a Replace All), each further edit must
    /// only keep the few pieces it touched for undo, not a copy of the list.
    @Test func undoStoresOnlyChangedPieces() throws {
        let url = try tempFile(Data(count: 200_000))
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try Document(url: url)
        let hits = stride(from: UInt64(0), to: 200_000, by: 20).map { $0 ..< $0 + 2 }
        try doc.replaceAll(hits, with: Data([0xAB]))          // ~20k pieces
        let afterReplaceAll = doc.undoFootprint
        for i in 0 ..< 1000 { try doc.overwrite(at: UInt64(i * 7), with: Data([UInt8(i & 0xFF)])) }
        // Each overwrite touches at most a handful of pieces.
        #expect(doc.undoFootprint - afterReplaceAll < 1000 * 8)
        let edited = doc.read(0 ..< doc.count)
        for _ in 0 ..< 1000 { doc.undo() }
        for _ in 0 ..< 1000 { doc.redo() }
        #expect(doc.read(0 ..< doc.count) == edited)
        while doc.canUndo { doc.undo() }
        #expect(doc.read(0 ..< doc.count) == Data(count: 200_000))
        #expect(!doc.isModified)
    }

    /// Undo/redo in any order, grouped steps and replace-all must always
    /// give back exactly the content of that point in history.
    @Test(arguments: 1...10) func undoRedoMatchHistory(seed: Int) throws {
        var rng = SplitMix(seed: UInt64(seed) &* 7919)
        let url = try tempFile(original)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try Document(url: url)
        var history = [original], at = 0       // content after each undo step

        func randomEdit(_ model: inout Data) throws {
            let n = UInt64(model.count)
            let a = UInt64.random(in: 0...n, using: &rng)
            let b = min(n, a + UInt64.random(in: 0...16, using: &rng))
            let bytes = Data((0..<Int.random(in: 1...8, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
            try doc.replace(a..<b, with: bytes)
            model.replaceSubrange(Int(a)..<Int(b), with: bytes)
        }

        for _ in 0..<300 {
            var model = history[at]
            switch Int.random(in: 0..<10, using: &rng) {
            case 0, 1:
                guard doc.canUndo else { continue }
                doc.undo(); at -= 1
            case 2:
                guard doc.canRedo else { continue }
                doc.redo(); at += 1
            case 3:
                // Grouped: several edits, one undo step.
                try doc.grouped { for _ in 0..<3 { try randomEdit(&model) } }
                history.removeSubrange(at + 1 ..< history.count); history.append(model); at += 1
            case 4:
                // Grouped that fails: everything rolled back, no undo step.
                let steps = doc.canUndo
                #expect(throws: DocumentError.self) {
                    try doc.grouped {
                        try randomEdit(&model)
                        try doc.insert(Data([1]), at: doc.count + 1)
                    }
                }
                #expect(doc.read(0..<doc.count) == history[at])
                #expect(doc.canUndo == steps)
                continue
            case 5:
                let len = UInt64(model.count)
                guard len > 64 else { continue }
                let starts = Set((0..<5).map { _ in UInt64.random(in: 0..<len / 8, using: &rng) * 8 })
                let ranges = starts.sorted().map { $0 ..< $0 + 4 }
                try doc.replaceAll(ranges, with: Data([0xEE]))
                for r in ranges.reversed() { model.replaceSubrange(Int(r.lowerBound)..<Int(r.upperBound), with: [0xEE]) }
                history.removeSubrange(at + 1 ..< history.count); history.append(model); at += 1
            default:
                try randomEdit(&model)
                history.removeSubrange(at + 1 ..< history.count); history.append(model); at += 1
            }
            #expect(doc.read(0..<doc.count) == history[at])
            #expect(doc.count == UInt64(history[at].count))
            #expect(doc.isModified == (at != 0))
        }
    }

    @Test func readOnlyRejectsEdits() throws {
        let url = try tempFile(Data([1, 2, 3]))
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try Document(url: url, readOnly: true)
        #expect(throws: DocumentError.self) { try doc.overwrite(at: 0, with: Data([9])) }
        #expect(throws: DocumentError.self) { try doc.save() }
    }

    /// in-place save changes exactly the edited bytes.
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

    /// #7: delete + insert keeps the length but moves original bytes; an
    /// in-place save that writes only new bytes would corrupt the file.
    @Test func inPlaceRefusesMovedBytes() throws {
        let url = try tempFile(Data("ABCD".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try Document(url: url)
        try doc.delete(0..<1)
        try doc.insert(Data("X".utf8), at: 3)
        #expect(doc.read(0..<4) == Data("BCDX".utf8))
        #expect(throws: DocumentError.self) { try doc.save(mode: .inPlace) }
        #expect(try Data(contentsOf: url) == Data("ABCD".utf8))
        #expect(doc.isModified)
        // The atomic save still gets it right.
        try doc.save()
        #expect(try Data(contentsOf: url) == Data("BCDX".utf8))
    }

    /// Insert and delete that cancel out at the same offset leave every
    /// original byte where it was, so in place is fine.
    @Test func inPlaceAllowsBalancedEditAtSameOffset() throws {
        let url = try tempFile(Data("ABCD".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try Document(url: url)
        try doc.delete(1..<2)
        try doc.insert(Data("Y".utf8), at: 1)
        try doc.save(mode: .inPlace)
        #expect(try Data(contentsOf: url) == Data("AYCD".utf8))
    }

    /// #6: one changed byte in a large file is written in place (no full
    /// copy); anything that moves bytes still saves atomically.
    @Test func automaticSaveWritesLargeFilesInPlace() throws {
        let size = Int(Document.inPlaceMinimumSize)
        var big = Data(count: size)
        big[size - 1] = 0x55
        let url = try tempFile(big)
        defer { try? FileManager.default.removeItem(at: url) }
        let inode = try inodeOf(url)
        let doc = try Document(url: url)
        try doc.overwrite(at: 12345, with: Data([0xAA, 0xBB]))
        try doc.save(mode: .automatic)
        #expect(try inodeOf(url) == inode)
        big.replaceSubrange(12345..<12347, with: [0xAA, 0xBB])
        #expect(try Data(contentsOf: url) == big)
        #expect(!doc.isModified)

        try doc.delete(0..<1)
        try doc.insert(Data([0x11]), at: 100)               // same length, bytes moved
        let expected = doc.read(0..<doc.count)
        try doc.save(mode: .automatic)
        #expect(try inodeOf(url) != inode)                  // atomic
        #expect(try Data(contentsOf: url) == expected)
    }

    @Test func automaticSaveKeepsSmallFilesAtomic() throws {
        let url = try tempFile(original)
        defer { try? FileManager.default.removeItem(at: url) }
        let inode = try inodeOf(url)
        let doc = try Document(url: url)
        try doc.overwrite(at: 1, with: Data([1]))
        try doc.save(mode: .automatic)
        #expect(try inodeOf(url) != inode)
        var expected = original
        expected[1] = 1
        #expect(try Data(contentsOf: url) == expected)
    }

    /// #6: reading must not walk all pieces per call. 10k pieces, 20k reads:
    /// a linear walk needs ~10⁸ piece steps, the binary search ~3·10⁵.
    @Test func readWithManyPiecesIsFast() throws {
        let url = try tempFile(Data(count: 400_000))
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try Document(url: url)
        let hits = stride(from: UInt64(0), to: 400_000, by: 80).map { $0 ..< $0 + 1 }
        try doc.replaceAll(hits, with: Data([0xAB]))
        let snap = doc.snapshot()
        var model = Data(count: 400_000)
        for h in hits { model[Int(h.lowerBound)] = 0xAB }
        var rng = SplitMix(seed: 6)
        let start = Date()
        for _ in 0 ..< 20_000 {
            let a = UInt64.random(in: 0 ..< 400_000, using: &rng)
            let b = min(400_000, a + UInt64.random(in: 0 ... 50, using: &rng))
            #expect(snap.read(a ..< b) == model.subdata(in: Int(a) ..< Int(b)))
            let c = snap.withContiguousBytes(a ..< b) { Data($0) }
            #expect(c == model.subdata(in: Int(a) ..< Int(b)))
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 10)   // old code: ~16 s; generous for loaded CI
    }

    /// atomic save with length change, permissions kept.
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

    /// #13: saving through a symlink updates the target and keeps the link.
    @Test func saveKeepsSymlink() throws {
        let target = try tempFile(Data([1, 2, 3]))
        let link = target.appendingPathExtension("link")
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: target)
        }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let doc = try Document(url: link)
        try doc.insert(Data([9]), at: 0)
        try doc.save()

        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        #expect(dest == target.path)
        #expect(try Data(contentsOf: target) == Data([9, 1, 2, 3]))
        #expect(doc.read(0..<doc.count) == Data([9, 1, 2, 3]))
    }

    /// #13: extended attributes (quarantine flag of a sample!) and the full
    /// permission bits survive an atomic save.
    @Test func saveKeepsXattrsAndMode() throws {
        let url = try tempFile(original)
        defer { try? FileManager.default.removeItem(at: url) }
        let q = Data("0081;00000000;hexwerk-test;".utf8)
        let x = Data("value".utf8)
        try setXattr(url, "com.apple.quarantine", q)
        try setXattr(url, "org.hexwerk.test", x)
        chmod(url.path, 0o666)                   // wider than the usual umask allows

        let doc = try Document(url: url)
        try doc.insert(Data([1]), at: 0)
        try doc.save()

        #expect(getXattr(url, "com.apple.quarantine") != nil)
        #expect(getXattr(url, "org.hexwerk.test") == x)
        var st = stat()
        stat(url.path, &st)
        #expect(st.st_mode & 0o7777 == 0o666)
    }

    /// a failing save leaves the original untouched.
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

    /// #5: a write into the mapped file itself makes the mapping unreliable;
    /// saving from it would mix foreign bytes into the result.
    @Test func inPlaceExternalWriteBlocksSave() throws {
        let url = try tempFile(Data([1, 2, 3, 4]))
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try Document(url: url)
        try doc.overwrite(at: 0, with: Data([9]))
        let h = try FileHandle(forWritingTo: url)
        try h.seek(toOffset: 2)
        try h.write(contentsOf: Data([7]))
        try h.close()

        #expect(doc.diskChange() == .modified)
        #expect(throws: DocumentError.self) { try doc.save() }
        #expect(throws: DocumentError.self) { try doc.save(as: url.appendingPathExtension("copy")) }
        #expect(try Data(contentsOf: url) == Data([1, 2, 7, 4]))
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("copy").path))

        try doc.revertToDisk()
        #expect(doc.diskChange() == .none)
        #expect(!doc.isModified)
        #expect(doc.read(0..<doc.count) == Data([1, 2, 7, 4]))
    }

    @Test func truncationIsAnInPlaceChange() throws {
        let url = try tempFile(original)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try Document(url: url)
        try doc.insert(Data([1]), at: 0)
        #expect(truncate(url.path, 100) == 0)
        #expect(doc.diskChange() == .modified)
        #expect(throws: DocumentError.self) { try doc.save() }   // would hit SIGBUS
        #expect(try Data(contentsOf: url).count == 100)
    }

    /// #5: a file replaced by another program (atomic save elsewhere) leaves
    /// our mapping intact, so saving is possible once the user agreed.
    @Test func replacedFileCanStillBeSaved() throws {
        let url = try tempFile(Data([1, 2, 3]))
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try Document(url: url)
        try doc.overwrite(at: 0, with: Data([9]))
        try Data([5, 5, 5, 5]).write(to: url, options: .atomic)

        #expect(doc.diskChange() == .replaced)
        #expect(doc.read(0..<doc.count) == Data([9, 2, 3]))
        doc.keepAfterReplace()
        #expect(doc.diskChange() == .none)
        try doc.save()
        #expect(try Data(contentsOf: url) == Data([9, 2, 3]))
        #expect(doc.diskChange() == .none)
    }

    @Test func deletedFileCountsAsReplaced() throws {
        let url = try tempFile(Data([1, 2, 3]))
        let doc = try Document(url: url)
        try FileManager.default.removeItem(at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(doc.diskChange() == .replaced)
        #expect(doc.read(0..<3) == Data([1, 2, 3]))      // mapping still valid
        doc.keepAfterReplace()
        #expect(doc.diskChange() == .none)
        try doc.overwrite(at: 0, with: Data([4]))
        try doc.save()                                     // writes it back
        #expect(try Data(contentsOf: url) == Data([4, 2, 3]))
    }

    @Test func modifiedRanges() throws {
        let url = try tempFile(original)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try Document(url: url)
        try doc.overwrite(at: 10, with: Data([1, 2]))
        #expect(doc.modifiedRanges == [10..<12])
    }
}

private func setXattr(_ url: URL, _ name: String, _ value: Data) throws {
    let r = value.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, $0.count, 0, 0) }
    guard r == 0 else { throw DocumentError.write(url.path, errno) }
}

private func getXattr(_ url: URL, _ name: String) -> Data? {
    let n = getxattr(url.path, name, nil, 0, 0, 0)
    guard n >= 0 else { return nil }
    var d = Data(count: n)
    let r = d.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, n, 0, 0) }
    return r == n ? d : nil
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

/// #16: both hex digits of a typed byte form one undo step.
@Suite struct NibbleUndoTests {
    @Test func secondNibbleJoinsPreviousUndoStep() throws {
        let url = try tempFile(Data([1, 2, 3]))
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try Document(url: url)
        // Insert mode with a selection: delete + insert as one step, then the low nibble.
        try doc.grouped {
            try doc.delete(1..<2)
            try doc.insert(Data([0x40]), at: 1)
        }
        try doc.amendingLastEdit { try doc.overwrite(at: 1, with: Data([0x41])) }
        #expect(doc.read(0..<10) == Data([1, 0x41, 3]))
        doc.undo()
        #expect(doc.read(0..<10) == Data([1, 2, 3]))
        #expect(!doc.canUndo)
        doc.redo()
        #expect(doc.read(0..<10) == Data([1, 0x41, 3]))
    }

    @Test func amendingWithoutHistoryIsOwnStep() throws {
        let url = try tempFile(Data([1]))
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try Document(url: url)
        try doc.amendingLastEdit { try doc.overwrite(at: 0, with: Data([7])) }
        #expect(doc.canUndo)
        doc.undo()
        #expect(doc.read(0..<1) == Data([1]))
    }
}
