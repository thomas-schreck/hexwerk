import Foundation
import Testing
@testable import HexwerkCore

/// Auto-recovery of unsaved changes (#139).
@Suite struct RecoveryTests {
    struct Env {
        let dir: URL
        let file: URL
        var store: RecoveryStore { RecoveryStore(directory: dir.appendingPathComponent("support/Recovery")) }
        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    func env(_ content: Data = Data((0 ..< 4096).map { UInt8($0 & 0xFF) })) throws -> Env {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hexwerk-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("firmware.bin")
        try content.write(to: file)
        return Env(dir: dir, file: file)
    }

    func all(_ d: Document) -> Data { d.read(0 ..< d.count) }

    func mode(_ url: URL) -> mode_t {
        var st = stat()
        stat(url.path, &st)
        return st.st_mode & 0o777
    }

    func files(_ store: RecoveryStore) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []).sorted()
    }

    /// Edits with an undo history and a redo step.
    func edit(_ d: Document) throws {
        try d.overwrite(at: 0, with: Data([0xDE, 0xAD]))
        try d.insert(Data("hello".utf8), at: 100)
        try d.delete(200 ..< 300)
        try d.replaceAll([10 ..< 12, 20 ..< 22], with: Data([0xAA]))
        try d.insert(Data([1, 2, 3]), at: 3000)
        d.undo()  // leaves one redo step
    }

    @Test func roundTripRestoresContentAndUndoHistory() throws {
        let e = try env()
        defer { e.cleanup() }
        let d = try Document(url: e.file)
        try edit(d)
        let writer = RecoveryWriter(store: e.store, url: e.file)
        #expect(try writer.write(d.recoveryContent()) == .saved)

        let rec = try #require(try e.store.record(for: e.file))
        #expect(rec.hasHistory)
        #expect(rec.path == RecoveryStore.path(for: e.file))
        let fresh = try Document(url: e.file)
        #expect(try fresh.restore(rec))
        #expect(all(fresh) == all(d))
        #expect(fresh.isModified)
        #expect(fresh.modifiedRanges == d.modifiedRanges)
        // Redo and undo behave as in the session that crashed.
        fresh.redo()
        d.redo()
        #expect(all(fresh) == all(d))
        while fresh.canUndo { fresh.undo() }
        #expect(!fresh.isModified)
        #expect(all(fresh) == (try Data(contentsOf: e.file)))
        // New edits after a restore get fresh states (no clash with old ones).
        fresh.redo()
        try fresh.insert(Data([9]), at: 0)
        #expect(fresh.isModified && !fresh.canRedo)
    }

    @Test func filesArePrivate() throws {
        let e = try env()
        defer { e.cleanup() }
        let d = try Document(url: e.file)
        try edit(d)
        _ = try RecoveryWriter(store: e.store, url: e.file).write(d.recoveryContent())
        #expect(mode(e.store.directory) == 0o700)
        let names = files(e.store)
        #expect(names.count == 2)  // metadata + data
        for n in names { #expect(mode(e.store.directory.appendingPathComponent(n)) == 0o600, "\(n)") }
    }

    @Test func sameFileViaSymlinkFindsTheRecord() throws {
        let e = try env()
        defer { e.cleanup() }
        let link = e.dir.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: e.file)
        let d = try Document(url: e.file)
        try d.insert(Data([7]), at: 0)
        _ = try RecoveryWriter(store: e.store, url: e.file).write(d.recoveryContent())
        let rec = try #require(try e.store.record(for: link))
        let viaLink = try Document(url: link)
        try viaLink.restore(rec)
        #expect(all(viaLink) == all(d))
    }

    // MARK: Mismatch detection

    func recordThenChange(_ change: (Env) throws -> Void) throws -> (Error?, Document, Env) {
        let e = try env()
        let d = try Document(url: e.file)
        try edit(d)
        _ = try RecoveryWriter(store: e.store, url: e.file).write(d.recoveryContent())
        try change(e)
        let rec = try #require(try e.store.record(for: e.file))
        let fresh = try Document(url: e.file)
        do { try fresh.restore(rec) } catch { return (error, fresh, e) }
        return (nil, fresh, e)
    }

    func setMtime(_ url: URL, _ sec: Int, _ nsec: Int) {
        var times = [timespec(tv_sec: sec, tv_nsec: nsec), timespec(tv_sec: sec, tv_nsec: nsec)]
        utimensat(AT_FDCWD, url.path, &times, 0)
    }

    func mtime(_ url: URL) -> timespec {
        var st = stat()
        stat(url.path, &st)
        return st.st_mtimespec
    }

    @Test func refusesWhenSizeChanged() throws {
        let (error, fresh, e) = try recordThenChange { e in
            let h = try FileHandle(forWritingTo: e.file)
            try h.seekToEnd()
            try h.write(contentsOf: Data([0]))
            try h.close()
        }
        defer { e.cleanup() }
        guard case .fileChanged(.size(4096, 4097)) = error as? RecoveryError else {
            Issue.record("expected a size mismatch, got \(String(describing: error))")
            return
        }
        #expect(!fresh.isModified && !fresh.canUndo)
        #expect(all(fresh) == (try Data(contentsOf: e.file)))
    }

    @Test func refusesWhenModificationDateChanged() throws {
        let (error, fresh, e) = try recordThenChange { e in setMtime(e.file, 1_000_000, 0) }
        defer { e.cleanup() }
        guard case .fileChanged(.modificationDate) = error as? RecoveryError else {
            Issue.record("expected a date mismatch, got \(String(describing: error))")
            return
        }
        #expect(!fresh.isModified)
    }

    /// Same size, modification time put back: the sampled hash catches it.
    @Test func refusesWhenContentChangedBehindTheDate() throws {
        let (error, fresh, e) = try recordThenChange { e in
            let t = mtime(e.file)
            var data = try Data(contentsOf: e.file)
            data[4095] ^= 0xFF
            let h = try FileHandle(forWritingTo: e.file)
            try h.write(contentsOf: data)
            try h.close()
            setMtime(e.file, t.tv_sec, t.tv_nsec)
        }
        defer { e.cleanup() }
        guard case .fileChanged(.content) = error as? RecoveryError else {
            Issue.record("expected a content mismatch, got \(String(describing: error))")
            return
        }
        #expect(!fresh.isModified)
    }

    @Test func refusesAnotherFile() throws {
        let e = try env()
        defer { e.cleanup() }
        let d = try Document(url: e.file)
        try d.insert(Data([1]), at: 0)
        _ = try RecoveryWriter(store: e.store, url: e.file).write(d.recoveryContent())
        let rec = try #require(try e.store.record(for: e.file))
        let other = e.dir.appendingPathComponent("other.bin")
        try FileManager.default.copyItem(at: e.file, to: other)
        let o = try Document(url: other)
        #expect(o.recoveryMismatch(rec) == .otherFile)
        #expect(throws: RecoveryError.self) { try o.restore(rec) }
        #expect(!o.isModified)
    }

    // MARK: Damage

    @Test func damagedMetadataIsReported() throws {
        let e = try env()
        defer { e.cleanup() }
        let d = try Document(url: e.file)
        try edit(d)
        let w = RecoveryWriter(store: e.store, url: e.file)
        _ = try w.write(d.recoveryContent())
        let meta = e.store.metaURL(w.key)
        var bytes = try Data(contentsOf: meta)
        bytes[bytes.count / 2] ^= 0x01
        try bytes.write(to: meta)
        #expect(throws: RecoveryError.self) { try e.store.record(for: e.file) }
        #expect(e.store.pending().isEmpty)
    }

    @Test func truncatedDataIsReported() throws {
        let e = try env()
        defer { e.cleanup() }
        let d = try Document(url: e.file)
        try edit(d)
        _ = try RecoveryWriter(store: e.store, url: e.file).write(d.recoveryContent())
        let data = try #require(files(e.store).first { $0.hasSuffix(".added") })
        try Data([1]).write(to: e.store.dataURL(data))
        #expect(throws: RecoveryError.self) { try e.store.record(for: e.file) }
    }

    /// A history that does not replay back to the file is not trusted: the
    /// content comes back as one undo step instead.
    @Test func inconsistentHistoryFallsBackToContent() throws {
        let e = try env()
        defer { e.cleanup() }
        let d = try Document(url: e.file)
        try edit(d)
        _ = try RecoveryWriter(store: e.store, url: e.file).write(d.recoveryContent())
        let good = try #require(try e.store.record(for: e.file))
        var p = good.payload
        p.undo[0].changes[0].index += 1
        let bad = RecoveryRecord(
            path: good.path, recordedAt: good.recordedAt, hasHistory: true, fingerprint: good.fingerprint, payload: p)
        let fresh = try Document(url: e.file)
        #expect(try fresh.restore(bad) == false)
        #expect(all(fresh) == all(d))
        #expect(fresh.isModified && !fresh.canRedo)
        fresh.undo()
        #expect(!fresh.isModified && !fresh.canUndo)
        #expect(all(fresh) == (try Data(contentsOf: e.file)))
    }

    @Test func piecesOutsideTheFileAreRefused() throws {
        let e = try env()
        defer { e.cleanup() }
        let d = try Document(url: e.file)
        try d.insert(Data([1]), at: 0)
        _ = try RecoveryWriter(store: e.store, url: e.file).write(d.recoveryContent())
        let good = try #require(try e.store.record(for: e.file))
        var p = good.payload
        p.pieces[1].start = 1 << 40
        let bad = RecoveryRecord(
            path: good.path, recordedAt: good.recordedAt, hasHistory: true, fingerprint: good.fingerprint, payload: p)
        let fresh = try Document(url: e.file)
        #expect(throws: RecoveryError.self) { try fresh.restore(bad) }
        #expect(!fresh.isModified)
    }

    // MARK: Writing

    /// The added buffer only grows between saves: later writes append.
    @Test func writesAppendOnlyNewBytesAndStartOverAfterSave() throws {
        let e = try env()
        defer { e.cleanup() }
        let d = try Document(url: e.file)
        let w = RecoveryWriter(store: e.store, url: e.file)
        try d.insert(Data(repeating: 0x41, count: 1000), at: 0)
        _ = try w.write(d.recoveryContent())
        let first = try #require(files(e.store).first { $0.hasSuffix(".added") })
        try d.insert(Data(repeating: 0x42, count: 10), at: 0)
        _ = try w.write(d.recoveryContent())
        #expect(files(e.store).filter { $0.hasSuffix(".added") } == [first])
        #expect(try Data(contentsOf: e.store.dataURL(first)).count == 1010)
        #expect(all(try restored(e)) == all(d))

        // After a save the buffer starts over; the old data file goes.
        try d.save()
        try d.insert(Data([0x43]), at: 0)
        _ = try w.write(d.recoveryContent())
        let now = files(e.store).filter { $0.hasSuffix(".added") }
        #expect(now.count == 1 && now != [first])
        #expect(all(try restored(e)) == all(d))
    }

    func restored(_ e: Env) throws -> Document {
        let fresh = try Document(url: e.file)
        try fresh.restore(try #require(try e.store.record(for: e.file)))
        return fresh
    }

    @Test func tooLargeRemovesTheOlderRecord() throws {
        let e = try env()
        defer { e.cleanup() }
        let store = RecoveryStore(directory: e.store.directory, maxAddedBytes: 100)
        let d = try Document(url: e.file)
        let w = RecoveryWriter(store: store, url: e.file)
        try d.insert(Data(repeating: 1, count: 50), at: 0)
        #expect(try w.write(d.recoveryContent()) == .saved)
        try d.insert(Data(repeating: 2, count: 51), at: 0)
        #expect(try w.write(d.recoveryContent()) == .tooLarge)
        #expect(try store.record(for: e.file) == nil)
        #expect(files(store).isEmpty)
    }

    @Test func largeHistoryIsDroppedBeforeTheContent() throws {
        let e = try env()
        defer { e.cleanup() }
        let d = try Document(url: e.file)
        for i in 0 ..< 200 { try d.overwrite(at: UInt64(i * 7), with: Data([0xEE])) }
        let unlimited = try RecoveryWriter(store: e.store, url: e.file).write(d.recoveryContent())
        #expect(unlimited == .saved)
        let size = try Data(contentsOf: e.store.metaURL(RecoveryStore.key(forPath: RecoveryStore.path(for: e.file)))).count
        let store = RecoveryStore(directory: e.store.directory, maxMetaBytes: size - 1)
        #expect(try RecoveryWriter(store: store, url: e.file).write(d.recoveryContent()) == .saved)
        let rec = try #require(try store.record(for: e.file))
        #expect(!rec.hasHistory)
        let fresh = try Document(url: e.file)
        #expect(try fresh.restore(rec) == false)
        #expect(all(fresh) == all(d))
    }

    @Test func saveAsMovesTheRecord() throws {
        let e = try env()
        defer { e.cleanup() }
        let d = try Document(url: e.file)
        let w = RecoveryWriter(store: e.store, url: e.file)
        try d.insert(Data([1]), at: 0)
        _ = try w.write(d.recoveryContent())
        let other = e.dir.appendingPathComponent("copy.bin")
        try d.save(as: other)
        try d.insert(Data([2]), at: 0)
        _ = try w.write(d.recoveryContent())
        #expect(try e.store.record(for: e.file) == nil)
        #expect(try e.store.record(for: other) != nil)
        #expect(e.store.pending().map(\.path) == [RecoveryStore.path(for: other)])
    }

    // MARK: Autosave

    /// The content is taken on the main thread once edits paused.
    @MainActor @Test func autosaveDebouncesDiscardsAndStops() async throws {
        let e = try env()
        defer { e.cleanup() }
        nonisolated(unsafe) let d = try Document(url: e.file)
        let a = RecoveryAutosave(store: e.store, url: e.file, delay: .milliseconds(20))
        var taken = 0
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(150))
            a.waitUntilIdle()
        }
        try d.insert(Data([1]), at: 0)
        a.schedule { taken += 1; return d.recoveryContent() }
        try d.insert(Data([2]), at: 0)
        a.schedule { taken += 1; return d.recoveryContent() }
        // Discarding right away drops both scheduled writes.
        a.discardNow()
        try await settle()
        #expect(files(e.store).isEmpty)
        #expect(taken == 0)

        // Only the latest of a burst is taken and written.
        a.schedule { taken += 1; return d.recoveryContent() }
        a.schedule { taken += 1; return d.recoveryContent() }
        try await settle()
        #expect(taken == 1)
        #expect(all(try restored(e)) == all(d))

        // Keep for Later: written at once; then no more writes.
        try d.insert(Data([3]), at: 0)
        #expect(a.writeNow(d.recoveryContent()) == .saved)
        a.stop()
        try d.insert(Data([4]), at: 0)
        a.schedule { d.recoveryContent() }
        try await settle()
        #expect(all(try restored(e)).first == 3)

        // A record restored in a new session belongs to the new window's writer.
        let b = RecoveryAutosave(store: e.store, url: e.file)
        b.discardNow()
        #expect(try e.store.record(for: e.file) == nil)
    }

    @Test func discardAllRemovesEverything() throws {
        let e = try env()
        defer { e.cleanup() }
        let d = try Document(url: e.file)
        try d.insert(Data([1]), at: 0)
        _ = try RecoveryWriter(store: e.store, url: e.file).write(d.recoveryContent())
        try Data("junk".utf8).write(to: e.store.directory.appendingPathComponent("0123.recovery"))
        #expect(e.store.pending().count == 1)
        e.store.discardAll()
        #expect(files(e.store).isEmpty)
    }
}
