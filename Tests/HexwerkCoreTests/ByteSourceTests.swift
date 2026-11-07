import Foundation
import Testing
@testable import HexwerkCore

/// Temporary file that is removed when the test ends.
func tempFile(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("hexwerk-\(UUID().uuidString)")
    try data.write(to: url)
    return url
}

@Suite struct ByteSourceTests {
    @Test func readsRanges() throws {
        let bytes = Data((0 ..< 1000).map { UInt8($0 % 256) })
        let url = try tempFile(bytes)
        defer { try? FileManager.default.removeItem(at: url) }

        let src = try ByteSource(url: url)
        #expect(src.count == 1000)
        #expect(src.read(0 ..< 4) == Data([0, 1, 2, 3]))
        #expect(src.read(256 ..< 258) == Data([0, 1]))
        #expect(src.read(0 ..< 1000) == bytes)
    }

    @Test func clipsOutOfRange() throws {
        let url = try tempFile(Data([1, 2, 3]))
        defer { try? FileManager.default.removeItem(at: url) }

        let src = try ByteSource(url: url)
        #expect(src.read(2 ..< 10) == Data([3]))
        #expect(src.read(5 ..< 10).isEmpty)
    }

    @Test func emptyFile() throws {
        let url = try tempFile(Data())
        defer { try? FileManager.default.removeItem(at: url) }

        let src = try ByteSource(url: url)
        #expect(src.count == 0)
        #expect(src.read(0 ..< 10).isEmpty)
    }

    @Test func rejectsDirectory() {
        #expect(throws: ByteSourceError.self) {
            try ByteSource(url: FileManager.default.temporaryDirectory)
        }
    }

    /// #34: open() on a FIFO without a writer blocks forever; it must be
    /// rejected as not a regular file right away.
    @Test func rejectsFIFOWithoutHanging() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hexwerk-fifo-\(UUID().uuidString)")
        guard mkfifo(url.path, 0o600) == 0 else { throw ByteSourceError.open(url.path, errno) }
        defer { unlink(url.path) }

        nonisolated(unsafe) var result: Result<ByteSource, any Error>?
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            result = Result { try ByteSource(url: url) }
            done.signal()
        }
        if done.wait(timeout: .now() + 5) == .timedOut {
            // Unblock the hanging open() so the test run can finish.
            let w = open(url.path, O_WRONLY | O_NONBLOCK)
            done.wait()
            if w >= 0 { close(w) }
            Issue.record("ByteSource(url:) blocked on a FIFO")
        }
        guard case .failure(let error) = result else {
            Issue.record("FIFO was accepted")
            return
        }
        #expect(error is ByteSourceError)
    }

    @Test func missingFile() {
        #expect(throws: ByteSourceError.self) {
            try ByteSource(url: URL(fileURLWithPath: "/nonexistent/hexwerk"))
        }
    }
}
