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

    /// Lock files stay (another instance may hold them) and are left out.
    func files(_ store: RecoveryStore, locks: Bool = false) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? [])
            .filter { locks || !$0.hasSuffix(".lock") }.sorted()
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
        let names = files(e.store, locks: true)
        #expect(names.count == 3)  // metadata, data, lock
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

    /// 3 MiB: more than the first and last MiB that are sampled.
    static let large = Data((0 ..< (3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7) })

    /// `fullHashLimit: 0` gives the identity checks used for files too large to hash.
    func recordThenChange(
        _ content: Data? = nil, fullHashLimit: UInt64? = nil, _ change: (Env) throws -> Void
    ) throws -> (Error?, Document, Env) {
        let e = try content.map { try env($0) } ?? env()
        let store = fullHashLimit.map { RecoveryStore(directory: e.store.directory, fullHashLimit: $0) } ?? e.store
        let d = try Document(url: e.file)
        try edit(d)
        _ = try RecoveryWriter(store: store, url: e.file).write(d.recoveryContent())
        try change(e)
        let rec = try #require(try store.record(for: e.file))
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

    func expectRefused(_ result: (Error?, Document, Env), _ expected: RecoveryMismatch) {
        let (error, fresh, e) = result
        defer { e.cleanup() }
        guard case .fileChanged(let m) = error as? RecoveryError, m == expected else {
            Issue.record("expected \(expected), got \(String(describing: error))")
            return
        }
        #expect(!fresh.isModified && !fresh.canUndo)
    }

    /// Overwrites `offset` in place and sets the mtime back, as a
    /// reproducible build with SOURCE_DATE_EPOCH would.
    func changeInPlaceKeepingDate(_ e: Env, at offset: Int) throws {
        let t = mtime(e.file)
        var data = try Data(contentsOf: e.file)
        data[offset] ^= 0xFF
        let h = try FileHandle(forWritingTo: e.file)
        try h.write(contentsOf: data)
        try h.close()
        setMtime(e.file, t.tv_sec, t.tv_nsec)
    }

    /// A new file with a changed middle and the old mtime renamed over it.
    func replaceKeepingDate(_ e: Env, at offset: Int?) throws {
        let t = mtime(e.file)
        var data = try Data(contentsOf: e.file)
        if let offset { data[offset] ^= 0xFF }
        let tmp = e.dir.appendingPathComponent("new.tmp")
        try data.write(to: tmp)
        setMtime(tmp, t.tv_sec, t.tv_nsec)
        #expect(rename(tmp.path, e.file.path) == 0)
    }

    @Test func refusesWhenDateChangedOnLargeFile() throws {
        expectRefused(try recordThenChange(fullHashLimit: 0) { e in setMtime(e.file, 1_000_000, 0) }, .modificationDate)
    }

    /// Hashed completely, only the bytes count: a touched file is fine.
    @Test func restoresWhenOnlyTheDateChangedOnHashedFile() throws {
        let (error, fresh, e) = try recordThenChange { e in setMtime(e.file, 1_000_000, 0) }
        defer { e.cleanup() }
        #expect(error == nil)
        #expect(fresh.isModified)
    }

    /// Same size, mtime put back, change outside the sampled MiB at both ends.
    @Test func refusesMiddleChangeBehindTheDate() throws {
        expectRefused(try recordThenChange(Self.large) { e in try changeInPlaceKeepingDate(e, at: 3 << 19) }, .content)
        // Too large to hash: the ctime still moved.
        expectRefused(
            try recordThenChange(Self.large, fullHashLimit: 0) { e in try changeInPlaceKeepingDate(e, at: 3 << 19) },
            .modificationDate)
    }

    @Test func refusesReplacedFileWithTheSameDate() throws {
        expectRefused(try recordThenChange(Self.large) { e in try replaceKeepingDate(e, at: 3 << 19) }, .content)
        expectRefused(
            try recordThenChange(Self.large, fullHashLimit: 0) { e in try replaceKeepingDate(e, at: 3 << 19) }, .replaced)
        // Same bytes in a new file: the pieces mean the same.
        let (error, fresh, e) = try recordThenChange(Self.large) { e in try replaceKeepingDate(e, at: nil) }
        defer { e.cleanup() }
        #expect(error == nil && fresh.isModified)
    }

    @Test func refusesWhenContentChangedBehindTheDate() throws {
        expectRefused(try recordThenChange { e in try changeInPlaceKeepingDate(e, at: 4095) }, .content)
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

    // MARK: Crafted histories (each must fall back to the content alone)

    /// A recorded edit session and its record, for tampering.
    func recorded() throws -> (Env, Document, RecoveryRecord) {
        let e = try env()
        let d = try Document(url: e.file)
        try edit(d)
        _ = try RecoveryWriter(store: e.store, url: e.file).write(d.recoveryContent())
        return (e, d, try #require(try e.store.record(for: e.file)))
    }

    func tampered(_ r: RecoveryRecord, _ change: (inout RecoveryPayload) -> Void) -> RecoveryRecord {
        var p = r.payload
        change(&p)
        return RecoveryRecord(path: r.path, recordedAt: r.recordedAt, hasHistory: true, fingerprint: r.fingerprint, payload: p)
    }

    /// Restores `bad`; the history must be refused and the content come back
    /// as one undo step that leads to the file.
    func expectContentOnly(_ e: Env, _ d: Document, _ bad: RecoveryRecord) throws {
        let fresh = try Document(url: e.file)
        #expect(try fresh.restore(bad) == false)
        #expect(all(fresh) == all(d))
        fresh.undo()
        #expect(!fresh.isModified)
        #expect(all(fresh) == (try Data(contentsOf: e.file)))
    }

    /// Chains and replays, but undoing everything does not end at the file.
    @Test func historyNotEndingAtTheFileIsRefused() throws {
        let (e, d, good) = try recorded()
        defer { e.cleanup() }
        let bad = tampered(good) { p in
            p.undo.removeFirst()
            p.savedState = p.undo[0].before
        }
        try expectContentOnly(e, d, bad)
    }

    @Test func stateOutsideTheChainIsRefused() throws {
        let (e, d, good) = try recorded()
        defer { e.cleanup() }
        let bad = tampered(good) { p in
            p.lastState += 1
            p.state = p.lastState
        }
        try expectContentOnly(e, d, bad)
    }

    @Test func redoThatDoesNotReplayIsRefused() throws {
        let (e, d, good) = try recorded()
        defer { e.cleanup() }
        #expect(!good.payload.redo.isEmpty)
        let bad = tampered(good) { p in p.redo[0].changes[0].index = 10_000 }
        try expectContentOnly(e, d, bad)
    }

    /// A redo step leading back to savedState would show changed content as saved.
    @Test func repeatedStatesAreRefused() throws {
        let (e, d, good) = try recorded()
        defer { e.cleanup() }
        let bad = tampered(good) { p in p.redo[p.redo.count - 1].after = p.savedState }
        try expectContentOnly(e, d, bad)
    }

    // MARK: Data file

    /// Same length, one byte changed: only the checksum notices.
    @Test func modifiedDataFileIsReported() throws {
        let e = try env()
        defer { e.cleanup() }
        let d = try Document(url: e.file)
        try edit(d)
        _ = try RecoveryWriter(store: e.store, url: e.file).write(d.recoveryContent())
        let name = try #require(files(e.store).first { $0.hasSuffix(".added") })
        var bytes = try Data(contentsOf: e.store.dataURL(name))
        bytes[0] ^= 0x01
        try bytes.write(to: e.store.dataURL(name))
        #expect(throws: RecoveryError.self) { try e.store.record(for: e.file) }
    }

    /// After a save the buffer starts over; more new bytes than before must
    /// not be appended to the old data file.
    @Test func saveThenLargerEditStartsANewDataFile() throws {
        let e = try env()
        defer { e.cleanup() }
        let d = try Document(url: e.file)
        let w = RecoveryWriter(store: e.store, url: e.file)
        try d.insert(Data(repeating: 0x41, count: 10), at: 0)
        _ = try w.write(d.recoveryContent())
        try d.save()
        try d.insert(Data(repeating: 0x42, count: 20), at: 5)
        _ = try w.write(d.recoveryContent())
        #expect(all(try restored(e)) == all(d))
    }

    /// Removed behind the writer's back (another instance, Discard All): the
    /// next write starts the data file over instead of leaving a hole.
    @Test func dataFileRemovedBehindTheWritersBack() throws {
        let e = try env()
        defer { e.cleanup() }
        let d = try Document(url: e.file)
        let w = RecoveryWriter(store: e.store, url: e.file)
        try d.insert(Data(repeating: 0x41, count: 100), at: 0)
        _ = try w.write(d.recoveryContent())
        let name = try #require(files(e.store).first { $0.hasSuffix(".added") })
        unlink(e.store.dataURL(name).path)
        try d.insert(Data([0x42]), at: 0)
        #expect(try w.write(d.recoveryContent()) == .saved)
        #expect(all(try restored(e)) == all(d))
    }

    /// A FIFO in place of the data file must fail, not block.
    @Test func fifoAsDataFileDoesNotHang() throws {
        let e = try env()
        defer { e.cleanup() }
        let d = try Document(url: e.file)
        try d.insert(Data([1]), at: 0)
        _ = try RecoveryWriter(store: e.store, url: e.file).write(d.recoveryContent())
        let name = try #require(files(e.store).first { $0.hasSuffix(".added") })
        unlink(e.store.dataURL(name).path)
        #expect(mkfifo(e.store.dataURL(name).path, 0o600) == 0)
        #expect(throws: RecoveryError.self) { try e.store.record(for: e.file) }
    }

    @Test func folderBehindASymlinkIsNotTrusted() throws {
        let e = try env()
        defer { e.cleanup() }
        let d = try Document(url: e.file)
        try d.insert(Data([1]), at: 0)
        _ = try RecoveryWriter(store: e.store, url: e.file).write(d.recoveryContent())
        let link = RecoveryStore(directory: e.dir.appendingPathComponent("linked"))
        try FileManager.default.createSymbolicLink(at: link.directory, withDestinationURL: e.store.directory)
        #expect(throws: RecoveryError.self) { try link.record(for: e.file) }
        #expect(link.pending().isEmpty)
    }

    /// Two instances editing one file: the record is always the complete
    /// state of whichever wrote last, and one instance's discard leaves a
    /// newer record of the other alone.
    @Test func twoInstancesKeepTheRecordConsistent() throws {
        let e = try env()
        defer { e.cleanup() }
        let a = try Document(url: e.file), b = try Document(url: e.file)
        let wa = RecoveryWriter(store: e.store, url: e.file), wb = RecoveryWriter(store: e.store, url: e.file)
        try a.insert(Data(repeating: 0xAA, count: 50), at: 0)
        _ = try wa.write(a.recoveryContent())
        try b.insert(Data(repeating: 0xBB, count: 70), at: 0)
        _ = try wb.write(b.recoveryContent())
        #expect(all(try restored(e)) == all(b))
        try a.insert(Data([0xA1]), at: 0)
        _ = try wa.write(a.recoveryContent())
        #expect(all(try restored(e)) == all(a))
        wb.discard()
        #expect(all(try restored(e)) == all(a))
        wa.discard()
        #expect(try e.store.record(for: e.file) == nil)
        #expect(files(e.store).isEmpty)
    }

    /// A write queued before `stop` (window closed after Keep for Later)
    /// must not run afterwards.
    @MainActor @Test func queuedWriteAfterStopIsDropped() async throws {
        let e = try env()
        defer { e.cleanup() }
        nonisolated(unsafe) let d = try Document(url: e.file)
        let a = RecoveryAutosave(store: e.store, url: e.file, delay: .milliseconds(1))
        try d.insert(Data([1]), at: 0)
        let release = DispatchSemaphore(value: 0)
        a.queue.async { release.wait() }  // hold the queue
        a.schedule { d.recoveryContent() }
        try await Task.sleep(for: .milliseconds(100))  // taken and queued
        a.stop()
        release.signal()
        a.waitUntilIdle()
        #expect(try e.store.record(for: e.file) == nil)
    }
}
