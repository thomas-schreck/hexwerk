import Foundation
import Testing
@testable import HexwerkCore

@Suite struct HexRecordsTests {
    /// The example from the Intel HEX article (checksums are verified on parse).
    static let ihex = """
    :10010000214601360121470136007EFE09D2190140
    :100110002146017E17C20001FF5F16002148011928
    :10012000194E79234623965778239EDA3F01B2CAA7
    :100130003F0156702B5E712B722B732146013421C7
    :00000001FF
    """

    /// The example from the SREC article.
    static let srec = """
    S00F000068656C6C6F202020202000003C
    S11F00007C0802A6900100049421FFF07C6C1B787C8C23783C6000003863000026
    S11F001C4BFFFFE5398000007D83637880010014382100107C0803A64E800020E9
    S111003848656C6C6F20776F726C642E0A0042
    S5030003F9
    S9030000FC
    """

    @Test func parsesReferenceExamples() throws {
        let i = try HexRecords.parse(Self.ihex)
        #expect(i.segments.count == 1 && i.base == 0x100 && i.segments[0].data.count == 64)
        #expect(i.segments[0].data.prefix(4) == Data([0x21, 0x46, 0x01, 0x36]))
        let s = try HexRecords.parse(Self.srec)
        #expect(s.header == "hello     \0\0")
        #expect(s.segments.count == 1 && s.base == 0 && s.segments[0].data.count == 0x46)
        #expect(String(decoding: s.segments[0].data.suffix(14), as: UTF8.self) == "Hello world.\n\0")
        #expect(s.startAddress == 0)
    }

    @Test func detectsErrors() {
        let badSum = Self.ihex.replacingOccurrences(of: "2146017E17C20001FF5F16002148011928", with: "2146017E17C20001FF5F16002148011929")
        #expect(throws: HexRecords.HexRecordError.self) { try HexRecords.parse(badSum) }
        do { _ = try HexRecords.parse(badSum) } catch let e as HexRecords.HexRecordError { #expect(e.line == 2) } catch {}
        #expect(throws: HexRecords.HexRecordError.self) { try HexRecords.parse("hello") }
        let badCount = Self.srec.replacingOccurrences(of: "S5030003F9", with: "S5030002FA")
        #expect(throws: HexRecords.HexRecordError.self) { try HexRecords.parse(badCount) }
    }

    @Test func roundTripWithGapsAnd64KBoundaries() throws {
        var rng = SplitMix(seed: 3)
        let a = Data((0 ..< 300).map { _ in UInt8.random(in: 0...255, using: &rng) })
        let b = Data((0 ..< 100).map { _ in UInt8.random(in: 0...255, using: &rng) })
        // Segment A crosses 0x0801_0000, B lies above a gap.
        let image = HexRecords.Image(segments: [.init(address: 0x0800_FF80, data: a), .init(address: 0x0801_0400, data: b)],
                                     startAddress: 0x0800_0101, header: nil)
        let flat = try image.flatten()
        #expect(image.gaps == [0x0801_00AC ..< 0x0801_0400])
        for text in [HexRecords.intelHex(flat, base: image.base, start: image.startAddress),
                     HexRecords.srec(flat, base: image.base, start: image.startAddress)] {
            let back = try HexRecords.parse(text)
            #expect(back.base == 0x0800_FF80)
            #expect(try back.flatten() == flat)
            #expect(back.startAddress == 0x0800_0101)
        }
        // Intel HEX: no data record crosses a 64 KiB boundary; S-Record uses S3/S7.
        let ih = HexRecords.intelHex(flat, base: image.base)
        #expect(ih.contains(":020000040801F1"))
        let sr = HexRecords.srec(flat, base: image.base, start: 0)
        #expect(sr.contains("\nS3") && sr.contains("\nS7"))
    }

    @Test func savingKeepsGaps() throws {
        let image = HexRecords.Image(segments: [.init(address: 0x100, data: Data([1, 2])), .init(address: 0x200, data: Data([3]))],
                                     startAddress: nil, header: nil)
        var flat = try image.flatten()
        let segs = HexRecords.segments(flat, base: image.base, gaps: image.gaps)
        #expect(segs == image.segments)
        // An edit inside the gap turns it into data.
        flat[0x50] = 0x42
        let segs2 = HexRecords.segments(flat, base: image.base, gaps: image.gaps)
        #expect(segs2.count == 1 && segs2[0].data.count == 0x101)
    }

    @Test func smallAddressesUseS1AndS9() throws {
        let sr = HexRecords.srec(Data([1, 2, 3]), base: 0x1000)
        #expect(sr.split(separator: "\n").map { String($0.prefix(2)) } == ["S0", "S1", "S5", "S9"])
        #expect(try HexRecords.parse(sr).flatten() == Data([1, 2, 3]))
    }
}

/// Save As of an imported file picks the format from the chosen ending (#3).
@Suite struct HexRecordsFormatTests {
    @Test func formatFromFileExtension() {
        for e in ["hex", "HEX", "ihex", "ihx"] { #expect(HexRecords.Format(fileExtension: e) == .intelHex, "\(e)") }
        for e in ["srec", "s19", "S28", "s37", "mot"] { #expect(HexRecords.Format(fileExtension: e) == .srec, "\(e)") }
        for e in ["bin", "", "txt"] { #expect(HexRecords.Format(fileExtension: e) == nil, "\(e)") }
    }
}
