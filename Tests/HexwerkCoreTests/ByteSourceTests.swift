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
        let bytes = Data((0..<1000).map { UInt8($0 % 256) })
        let url = try tempFile(bytes)
        defer { try? FileManager.default.removeItem(at: url) }

        let src = try ByteSource(url: url)
        #expect(src.count == 1000)
        #expect(src.read(0..<4) == Data([0, 1, 2, 3]))
        #expect(src.read(256..<258) == Data([0, 1]))
        #expect(src.read(0..<1000) == bytes)
    }

    @Test func clipsOutOfRange() throws {
        let url = try tempFile(Data([1, 2, 3]))
        defer { try? FileManager.default.removeItem(at: url) }

        let src = try ByteSource(url: url)
        #expect(src.read(2..<10) == Data([3]))
        #expect(src.read(5..<10).isEmpty)
    }

    @Test func emptyFile() throws {
        let url = try tempFile(Data())
        defer { try? FileManager.default.removeItem(at: url) }

        let src = try ByteSource(url: url)
        #expect(src.count == 0)
        #expect(src.read(0..<10).isEmpty)
    }

    @Test func rejectsDirectory() {
        #expect(throws: ByteSourceError.self) {
            try ByteSource(url: FileManager.default.temporaryDirectory)
        }
    }

    @Test func missingFile() {
        #expect(throws: ByteSourceError.self) {
            try ByteSource(url: URL(fileURLWithPath: "/nonexistent/hexwerk"))
        }
    }
}
