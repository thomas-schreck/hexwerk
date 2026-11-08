import Foundation
import Testing
@testable import HexwerkCore
import HexwerkScript

/// #143: base address per file, merge in diff, checksums with excluded ranges.
@Suite struct AddressMapTests {
    @Test func convertsBothWays() {
        let m = AddressMap(base: 0x0800_0000)
        #expect(m.address(of: 0) == 0x0800_0000 && m.address(of: 0x10) == 0x0800_0010)
        #expect(m.offset(of: 0x0800_0010, count: 0x100) == 0x10)
        #expect(m.offset(of: 0x0800_0100, count: 0x100) == 0x100)  // end position
        #expect(m.offset(of: 0x0800_0101, count: 0x100) == nil)
        #expect(m.offset(of: 0x07FF_FFFF, count: 0x100) == nil)
        #expect(AddressMap().offset(of: 5, count: 10) == 5)
    }

    @Test func rejectsBasesThatOverflow() {
        #expect(AddressMap.isValid(base: .max - 10, count: 10))
        #expect(!AddressMap.isValid(base: .max - 9, count: 10))
        #expect(!AddressMap.isValid(base: .max, count: 1))
        #expect(AddressMap(base: .max).address(of: 1) == 0)  // wraps, never traps
    }

    @Test func goToTargets() {
        let m = AddressMap(base: 0x1000)
        #expect(m.target(of: "0x1010", cursor: 0, count: 0x20) == 0x10)
        #expect(m.target(of: "4100", cursor: 0, count: 0x20) == 4)
        #expect(m.target(of: "0x10", cursor: 0, count: 0x20) == nil)  // below the base
        #expect(m.target(of: "+0x8", cursor: 4, count: 0x20) == 0xC)
        #expect(m.target(of: "-8", cursor: 4, count: 0x20) == 0)
        #expect(m.target(of: "−2", cursor: 4, count: 0x20) == 2)
        #expect(m.target(of: "+0xffffffffffffffff", cursor: 4, count: 0x20) == nil)
        #expect(m.target(of: "0x0000_1020", cursor: 0, count: 0x20) == 0x20)
        #expect(m.target(of: "zz", cursor: 0, count: 0x20) == nil)
        #expect(AddressMap().target(of: "0x10", cursor: 0, count: 0x20) == 0x10)
    }

    /// A base address alone used to count as "nothing worth remembering",
    /// so it was dropped when the window closed.
    @Test func projectWithOnlyABaseAddressIsKept() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hexwerk-base-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = URL(fileURLWithPath: "/nonexistent-hexwerk/fw.bin")
        var s = ProjectState(filePath: file.path, fileSize: 64)
        s.offsetBase = 0x0800_0000
        #expect(!s.isTrivial)
        #expect(try ProjectStore.save(s, for: file, in: dir) != nil)
        #expect(ProjectStore.load(for: file, in: dir)?.offsetBase == 0x0800_0000)
    }

    @Test func scriptSeesBaseAddressButKeepsOffsets() throws {
        let url = try tempFile(Data(0 ..< 32))
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try Document(url: url)
        let r = ScriptRunner.run(
            """
            print(typeof hw.baseAddress, String(hw.baseAddress), String(hw.address(0x10)))
            print(hw.offset(0xFFFFFFFF80000010n), hw.u8(4), hw.cursor)
            hw.goto(hw.offset(hw.address(3)))
            """, document: doc,
            context: ScriptContext(cursor: 2, baseAddress: 0xFFFF_FFFF_8000_0000))
        #expect(r.error == nil, "\(String(describing: r.error))")
        #expect(r.output == ["bigint 18446744071562067968 18446744071562067984", "16 4 2"])
        #expect(r.goTo == 3)
        let bad = ScriptRunner.run("hw.offset(5)", document: doc, context: ScriptContext(baseAddress: 0x100))
        #expect(bad.error?.message.contains("invalid address") == true)
        // Without a base address, addresses are offsets.
        let plain = ScriptRunner.run("print(String(hw.baseAddress), hw.offset(7))", document: doc, context: ScriptContext())
        #expect(plain.output == ["0 7"])
    }
}

@Suite struct TakeOverTests {
    func doc(_ bytes: [UInt8]) throws -> (Document, URL) {
        let url = try tempFile(Data(bytes))
        return (try Document(url: url), url)
    }

    func snapshot(_ bytes: [UInt8]) throws -> (Snapshot, URL) {
        let url = try tempFile(Data(bytes))
        return (try Document(url: url, readOnly: true).snapshot(), url)
    }

    @Test func takingAllMakesTheFilesEqualAndUndoes() throws {
        var rng = SplitMix(seed: 143)
        let a: [UInt8] = (0 ..< 3000).map { _ in UInt8.random(in: 0 ... 255, using: &rng) }
        var b = a
        b[10] = ~b[10]
        b.insert(contentsOf: [1, 2, 3], at: 500)
        b.removeSubrange(1000 ..< 1100)
        b.append(contentsOf: [9, 9])
        let (d, ua) = try doc(a)
        let (other, ub) = try snapshot(b)
        defer { for u in [ua, ub] { try? FileManager.default.removeItem(at: u) } }
        let ops = AlignedDiff.diff(d.snapshot(), other)
        #expect(ops.count >= 4)
        try d.takeOver(ops, from: other)
        #expect([UInt8](d.read(0 ..< d.count)) == b)
        #expect(AlignedDiff.diff(d.snapshot(), other).isEmpty)
        d.undo()  // one step
        #expect([UInt8](d.read(0 ..< d.count)) == a)
        #expect(!d.canUndo)
    }

    @Test func takingOneLeavesTheOthers() throws {
        let a = [UInt8](repeating: 0x11, count: 200)
        var b = a
        b[5] = 0xAA
        b[150] = 0xBB
        let (d, ua) = try doc(a)
        let (other, ub) = try snapshot(b)
        defer { for u in [ua, ub] { try? FileManager.default.removeItem(at: u) } }
        let ops = AlignedDiff.diff(d.snapshot(), other)
        #expect(ops.count == 2)
        try d.takeOver([ops[1]], from: other)
        #expect(d.read(150 ..< 151) == Data([0xBB]) && d.read(5 ..< 6) == Data([0x11]))
        // The diff follows: only the first difference remains.
        #expect(AlignedDiff.diff(d.snapshot(), other) == [ops[0]])
    }

    @Test func refusesOpsThatDoNotFit() throws {
        let (d, ua) = try doc([1, 2, 3, 4])
        let (other, ub) = try snapshot([5, 6, 7, 8])
        defer { for u in [ua, ub] { try? FileManager.default.removeItem(at: u) } }
        // Past the end, unsorted: nothing changes.
        #expect(throws: DocumentError.self) { try d.takeOver([DiffOp(.replace, a: 2 ..< 6, b: 2 ..< 4)], from: other) }
        #expect(throws: DocumentError.self) {
            try d.takeOver([DiffOp(.replace, a: 2 ..< 3, b: 2 ..< 3), DiffOp(.replace, a: 0 ..< 1, b: 0 ..< 1)], from: other)
        }
        #expect(d.read(0 ..< 4) == Data([1, 2, 3, 4]) && !d.canUndo)
        let ro = try Document(url: ua, readOnly: true)
        #expect(throws: DocumentError.self) { try ro.takeOver([DiffOp(.replace, a: 0 ..< 1, b: 0 ..< 1)], from: other) }
    }
}

@Suite struct ExcludedChecksumTests {
    @Test func includedRanges() {
        #expect(Checksum.included(0 ..< 10, excluding: []) == [0 ..< 10])
        #expect(Checksum.included(0 ..< 10, excluding: [2 ..< 4]) == [0 ..< 2, 4 ..< 10])
        // Unsorted, overlapping, touching, empty, outside, covering an end.
        #expect(
            Checksum.included(2 ..< 20, excluding: [15 ..< 30, 5 ..< 7, 6 ..< 9, 9 ..< 10, 12 ..< 12, 0 ..< 3, 40 ..< 50])
                == [3 ..< 5, 10 ..< 15])
        #expect(Checksum.included(0 ..< 10, excluding: [0 ..< 10]).isEmpty)
    }

    @Test func skipsExcludedBytes() throws {
        let data = Data("123456789".utf8) + Data([0xDE, 0xAD, 0xBE, 0xEF]) + Data("tail".utf8)
        let url = try tempFile(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let s = try Document(url: url, readOnly: true).snapshot()
        let r = Checksum.compute([.crc32, .sha256], s, excluding: [9 ..< 13])
        #expect(r?[.crc32] == Checksum.compute(.crc32, Data("123456789tail".utf8)))
        #expect(r?[.sha256] == Checksum.compute(.sha256, Data("123456789tail".utf8)))
        // Exclusions combine with a range; outside parts are ignored.
        #expect(Checksum.crc32.compute(s, range: 0 ..< 13, excluding: [9 ..< 100]) == "cbf43926")
        // Nothing excluded: unchanged.
        #expect(Checksum.crc32.compute(s, excluding: []) == Checksum.compute(.crc32, data))
    }

    @Test func parsesRanges() {
        #expect(Checksum.parseRange("0x1fc:4") == 0x1FC ..< 0x200)
        #expect(Checksum.parseRange("16:0x10") == 16 ..< 32)
        #expect(Checksum.parseRange("0xffffffffffffffff:2") == UInt64.max ..< UInt64.max)
        for bad in ["", "5", "5:", ":5", "a:1", "1:2:3", "-1:2"] { #expect(Checksum.parseRange(bad) == nil, "\(bad)") }
    }
}

extension CLITests {
    @Test func hashExcludesRanges() throws {
        let url = try tempFile(Data("123456789".utf8) + Data([0xDE, 0xAD, 0xBE, 0xEF]))
        defer { try? FileManager.default.removeItem(at: url) }
        let (s, out) = try run(["hash", "--algo", "crc32", "--exclude", "0x9:4", url.path])
        #expect(s == 0)
        #expect(out == "cbf43926  \(url.path)\n")
        let (s2, out2) = try run(["hash", "--algo", "crc32", "--exclude", "9:2", "--exclude", "11:0x2", "--json", url.path])
        #expect(s2 == 0 && out2.contains("cbf43926"))
        #expect(try run(["hash", "--exclude", "9-13", url.path]).0 != 0)
    }

    @Test func dumpWithBaseAddress() throws {
        let url = try tempFile(Data("ABCDEFGHIJKLMNOPQRS".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let (s, out) = try run(["dump", "--base", "0x08000000", "--offset", "16", url.path])
        #expect(s == 0)
        #expect(out.hasPrefix("08000010  51 52 53 ") && out.hasSuffix(" |QRS|\n08000013\n"))
        // Without --base the output is unchanged.
        #expect(try run(["dump", "--offset", "16", url.path]).1.hasPrefix("00000010  51 52 53"))
        #expect(try run(["dump", "--base", "0xffffffffffffffff", url.path]).0 == 1)
    }
}
