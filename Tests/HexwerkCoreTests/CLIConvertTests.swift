import Foundation
import Testing
@testable import HexwerkCore

/// Issue #21: HEX/S-Record → HEX/S-Record keeps the segments; gaps are not
/// filled with 0xFF (that would flash bytes that were never data).
extension CLITests {
    @Test func convertTextToTextKeepsGaps() throws {
        let segs = [HexRecords.Segment(address: 0, data: Data([1, 2, 3, 4])),
                    HexRecords.Segment(address: 0x0800_0000, data: Data([5, 6]))]
        let hex = try tempFile(Data(HexRecords.intelHex(segs, start: 0x0800_0000).utf8))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hexwerk-conv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: hex); try? FileManager.default.removeItem(at: dir) }

        let srec = dir.appendingPathComponent("out.srec"), back = dir.appendingPathComponent("back.hex")
        #expect(try run(["convert", "--from", "ihex", hex.path, srec.path]).0 == 0)
        // Was a 128 MiB 0xFF fill (minutes to write and to parse back).
        try #require(try Data(contentsOf: srec).count < 1000)
        let s = try HexRecords.parse(String(contentsOf: srec, encoding: .ascii))
        #expect(s.segments == segs)
        #expect(s.startAddress == 0x0800_0000)
        #expect(try run(["convert", srec.path, back.path]).0 == 0)
        #expect(try HexRecords.parse(String(contentsOf: back, encoding: .ascii)).segments == segs)

        // --base moves all segments, keeping their distance.
        let moved = dir.appendingPathComponent("moved.hex")
        #expect(try run(["convert", "--from", "ihex", "--base", "0x1000", hex.path, moved.path]).0 == 0)
        #expect(try HexRecords.parse(String(contentsOf: moved, encoding: .ascii)).segments.map(\.address) == [0x1000, 0x0800_1000])
    }
}
