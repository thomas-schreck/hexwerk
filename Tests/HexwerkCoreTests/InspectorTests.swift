import Foundation
import Testing
@testable import HexwerkCore

@Suite struct InspectorTests {
    func value(_ bytes: [UInt8], _ name: String, _ endian: Endian = .little) -> String? {
        Inspector.values(Data(bytes), endian: endian).first { $0.name == name }?.value
    }

    /// TC-1.10: known byte sequences for every type, both byte orders.
    @Test func integers() {
        let b: [UInt8] = [0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        #expect(value(b, "int8") == "-2")
        #expect(value(b, "uint8") == "254")
        #expect(value(b, "int16") == "-2")
        #expect(value(b, "uint16") == "65534")
        #expect(value(b, "int32") == "-2")
        #expect(value(b, "int64") == "-2")
        #expect(value(b, "uint64") == "18446744073709551614")
        #expect(value([0x12, 0x34], "uint16", .big) == "4660")
        #expect(value([0x12, 0x34], "uint16", .little) == "13330")
        #expect(value([0x01], "int16") == nil)     // not enough bytes
    }

    @Test func floats() {
        #expect(value([0x00, 0x00, 0x80, 0x3F], "float32") == "1.0")
        #expect(value([0x3F, 0x80, 0x00, 0x00], "float32", .big) == "1.0")
        #expect(value([0, 0, 0, 0, 0, 0, 0xF0, 0x3F], "float64") == "1.0")
    }

    @Test func times() {
        // 2026-11-05T00:00:00Z = 1793836800 = 0x6AEB_C700
        #expect(value([0x00, 0xC7, 0xEB, 0x6A], "Unix time 32") == "2026-11-05T00:00:00Z")
        // FILETIME for 1970-01-01 = 116444736000000000 = 0x019DB1DED53E8000
        #expect(value([0x00, 0x80, 0x3E, 0xD5, 0xDE, 0xB1, 0x9D, 0x01], "FILETIME") == "1970-01-01T00:00:00Z")
        // DOS: 2026-11-05 13:45:30 → date 0x5D65, time 0x6DAF
        #expect(value([0xAF, 0x6D, 0x65, 0x5D], "DOS date/time") == "2026-11-05 13:45:30")
    }

    @Test func guidAndBinary() {
        let b: [UInt8] = [0x33, 0x22, 0x11, 0x00, 0x55, 0x44, 0x77, 0x66, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
        #expect(value(b, "GUID") == "{00112233-4455-6677-8899-AABBCCDDEEFF}")
        #expect(value([0x05], "binary") == "00000101")
    }

    @Test func leb128() {
        #expect(value([0xE5, 0x8E, 0x26], "ULEB128") == L("%@ (%ld bytes)", "624485", 3))
        #expect(value([0xC0, 0xBB, 0x78], "SLEB128") == L("%@ (%ld bytes)", "-123456", 3))
    }

    @Test func strings() {
        #expect(value(Array("Hallo\0xy".utf8), "ASCII") == "\"Hallo\"")
        #expect(value(Array("Grüße\0".utf8), "UTF-8") == "\"Grüße\"")
        #expect(value(Array("Grüße".utf8), "ASCII") == nil)
        #expect(value([0x48, 0x00, 0x69, 0x00, 0x00, 0x00], "UTF-16 LE") == "\"Hi\"")
        #expect(value([0x00, 0x48, 0x00, 0x69], "UTF-16 BE") == "\"Hi\"")
    }

    /// TC-1.13 (part): random data and every length 0…64 must not trap.
    @Test func robustOnRandomInput() {
        var rng = SplitMix(seed: 7)
        for len in 0...64 {
            for _ in 0..<50 {
                let d = Data((0..<len).map { _ in UInt8.random(in: 0...255, using: &rng) })
                _ = Inspector.values(d, endian: .little)
                _ = Inspector.values(d, endian: .big)
            }
        }
    }
}

@Suite struct HexDumpTests {
    /// TC-1.12: identical to `hexdump -C -v`.
    @Test(arguments: [0, 1, 7, 16, 17, 100]) func matchesHexdump(length: Int) throws {
        var rng = SplitMix(seed: UInt64(length))
        let data = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) })
        let url = try tempFile(data)
        defer { try? FileManager.default.removeItem(at: url) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hexdump")
        p.arguments = ["-C", "-v", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        let expected = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        let ours = HexDump.lines(data, startOffset: 0).joined(separator: "\n") + "\n"
        // hexdump prints no lines at all for an empty file.
        #expect(length == 0 ? expected.isEmpty : ours == expected)
    }
}
