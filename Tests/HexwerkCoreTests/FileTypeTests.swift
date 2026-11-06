import Foundation
import Testing
@testable import HexwerkCore
import HexwerkMagic

@Suite struct FileTypeTests {
    private func snap(_ d: Data) throws -> (Snapshot, URL) {
        let url = try tempFile(d)
        return (try Document(url: url, readOnly: true).snapshot(), url)
    }

    private func gzipData() throws -> Data {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hexwerk-gz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("hello hexwerk\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try run("/usr/bin/gzip", ["-k", "a.txt"], cwd: dir)
        return try Data(contentsOf: dir.appendingPathComponent("a.txt.gz"))
    }

    @Test func detectsCommonFormats() throws {
        let cases: [(Data, String)] = [
            (image(.png, width: 4, height: 4), "png"),
            (image(.gif, width: 4, height: 4), "gif"),
            (image(.bmp, width: 4, height: 4), "bmp"),
            (image(.jpeg, width: 4, height: 4), "jpeg"),
            (image(.tiff, width: 4, height: 4), "exif"),
            (try gzipData(), "gzip"),
            (Data([0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0]) + Data(repeating: 0, count: 56), "elf"),
            (Data("SQLite format 3\0".utf8) + Data(repeating: 0, count: 84), "sqlite3"),
        ]
        for (d, id) in cases {
            let (s, url) = try snap(d)
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(FileSignatures.detect(s).first?.kaitai == id, "\(id)")
        }
        // Java class vs. Mach-O fat share CAFEBABE.
        let (j, u1) = try snap(Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x34]))
        defer { try? FileManager.default.removeItem(at: u1) }
        #expect(FileSignatures.detect(j).first?.kaitai == "java_class")
        let (f, u2) = try snap(Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x02]))
        defer { try? FileManager.default.removeItem(at: u2) }
        #expect(FileSignatures.detect(f).first?.kaitai == "mach_o_fat")
    }

    @Test func findsEmbeddedFiles() throws {
        let png = image(.png, width: 4, height: 4), gz = try gzipData()
        var d = Data(repeating: 0x11, count: 1000)
        d += png
        d += Data(repeating: 0x22, count: 333)
        d += gz
        let (s, url) = try snap(d)
        defer { try? FileManager.default.removeItem(at: url) }
        let hits = FileSignatures.scanEmbedded(s)
        #expect(hits.contains { $0.offset == 1000 && $0.kaitai == "png" })
        #expect(hits.contains { $0.offset == UInt64(1000 + png.count + 333) && $0.kaitai == "gzip" })
        #expect(!hits.contains { $0.offset == 0 })
    }

    @Test func randomDataHasFewFalsePositives() throws {
        var rng = SplitMix(seed: 7)
        let d = Data((0 ..< (4 << 20)).map { _ in UInt8.random(in: 0...255, using: &rng) })
        let (s, url) = try snap(d)
        defer { try? FileManager.default.removeItem(at: url) }
        // 4 MiB random: signatures need ≥4 fixed bytes or a check, so hits stay rare.
        #expect(FileSignatures.scanEmbedded(s).count < 10)
    }

    @Test func libmagicDescribes() throws {
        let (s, url) = try snap(image(.png, width: 53, height: 37))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(Magic.describe(s)?.hasPrefix("PNG image data, 53 x 37") == true)
        #expect(Magic.mime(s)?.hasPrefix("image/png") == true)
    }
}
