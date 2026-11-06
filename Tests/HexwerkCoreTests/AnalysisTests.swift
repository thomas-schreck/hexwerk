import Foundation
import Testing
@testable import HexwerkCore

@Suite struct AnalysisTests {
    @Test func entropyBounds() {
        #expect(Analysis.entropy([UInt64](repeating: 0, count: 255) + [100], total: 100) == 0)
        #expect(abs(Analysis.entropy([UInt64](repeating: 4, count: 256), total: 1024) - 8) < 1e-12)
        #expect(Analysis.entropy([UInt64](repeating: 0, count: 256), total: 0) == 0)
        // Two equally likely values: exactly 1 bit.
        var h = [UInt64](repeating: 0, count: 256); h[0] = 50; h[255] = 50
        #expect(Analysis.entropy(h, total: 100) == 1)
    }

    @Test func profileAndStatsOverEditedDocument() throws {
        // 4 KiB zeros, then 4 KiB of all byte values.
        var d = Data(repeating: 0, count: 4096)
        d.append(Data((0..<4096).map { UInt8($0 & 0xFF) }))
        let url = try tempFile(d)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try Document(url: url)
        let (stats, profile) = try #require(Analysis.analyze(doc.snapshot(), blocks: 8))
        #expect(stats.count == 8192)
        #expect(stats.histogram[0] == 4096 + 16)
        #expect(stats.distinct == 256)
        #expect(profile.blockSize == 1024 && profile.blocks.count == 8)
        #expect(profile.blocks[0...3].allSatisfy { $0 == 0 })
        #expect(profile.blocks[4...7].allSatisfy { abs($0 - 8) < 1e-12 })
        // Edits are seen: overwrite the zero half's first block.
        try doc.overwrite(at: 0, with: Data((0..<1024).map { UInt8($0 & 0xFF) }))
        let (_, p2) = try #require(Analysis.analyze(doc.snapshot(), blocks: 8))
        #expect(abs(p2.blocks[0] - 8) < 1e-12)
        // Sub range and cancel.
        let (s3, p3) = try #require(Analysis.analyze(doc.snapshot(), range: 1000..<1300, blocks: 100))
        #expect(s3.count == 300 && p3.blockSize == 256 && p3.blocks.count == 2 && p3.start == 1000)
        #expect(Analysis.analyze(doc.snapshot(), isCancelled: { true }) == nil)
    }

    @Test func ratios() {
        var h = [UInt64](repeating: 0, count: 256)
        h[0] = 1; h[0x41] = 2; h[0x0A] = 1; h[0x90] = 4
        let s = ByteStats(histogram: h)
        #expect(s.count == 8 && s.zeroRatio == 0.125 && s.printableRatio == 0.375 && s.highRatio == 0.5)
    }

    @Test func exportFormats() throws {
        let d = Data([0x00, 0x41, 0x22, 0x5C, 0xFF] + Array(repeating: 0x01, count: 10))
        #expect(ExportFormat.hex.render(d.prefix(3)) == "00 41 22")
        #expect(Data(base64Encoded: ExportFormat.base64.render(d)) == d)
        let c = ExportFormat.c.render(d, name: "buf")
        #expect(c.hasPrefix("unsigned char buf[15] = {\n    0x00, 0x41,"))
        #expect(c.hasSuffix("0x01\n};"))
        #expect(c.components(separatedBy: "\n").count == 4)     // 12 per line
        #expect(ExportFormat.python.render(d.prefix(5)) == #"data = b"\x00A\"\\\xff""#)
        #expect(ExportFormat.swift.render(Data([1, 2])) == "let data: [UInt8] = [\n    0x01, 0x02\n]")
    }

    /// The Python rendering must be valid Python that yields the same bytes.
    @Test func pythonRoundTrip() throws {
        let d = Data((0...255).map { UInt8($0) })
        let script = ExportFormat.python.render(d) + "\nimport sys; sys.stdout.buffer.write(data)\n"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", "-c", script]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let got = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(got == d)
    }
}
