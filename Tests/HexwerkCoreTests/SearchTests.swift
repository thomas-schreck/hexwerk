import Foundation
import Testing
@testable import HexwerkCore

/// Naive reference search (non-overlapping) to check the fast one against.
func naiveFind(_ p: SearchPattern, _ d: Data) -> [Range<UInt64>] {
    let b = [UInt8](d)
    var out: [Range<UInt64>] = []
    var i = 0
    while i + p.count <= b.count {
        if b.withUnsafeBufferPointer({ p.matches($0.baseAddress! + i) }) {
            out.append(UInt64(i)..<UInt64(i + p.count))
            i += p.count
        } else { i += 1 }
    }
    return out
}

func doc(_ data: Data) throws -> (Document, URL) {
    let url = try tempFile(data)
    return (try Document(url: url), url)
}

@Suite struct SearchTests {
    @Test func parsesHex() {
        #expect(SearchPattern.hex("4D 5a ?? 00")?.elements == [.byte(0x4D), .byte(0x5A), .any, .byte(0)])
        #expect(SearchPattern.hex("4D5") == nil)
        #expect(SearchPattern.hex("XY") == nil)
        #expect(SearchPattern.hex("") == nil)
    }

    /// wildcards, every hit found, none extra.
    @Test func hexWithWildcards() throws {
        let (d, url) = try doc(Data([0x4D, 0x5A, 0x90, 0x00, 0x4D, 0x5A, 0x01, 0x00, 0x4D, 0x00]))
        defer { try? FileManager.default.removeItem(at: url) }
        let hits = Search.find(.hex("4D 5A ?? 00")!, in: d.snapshot())
        #expect(hits == [0..<4, 4..<8])
    }

    /// Random data + random patterns against the naive reference,
    /// with a small chunk-independent check via an artificially small file.
    @Test(arguments: 1...10) func matchesNaive(seed: Int) throws {
        var rng = SplitMix(seed: UInt64(seed))
        // Small alphabet → many hits and matches across chunk borders.
        let data = Data((0..<200_000).map { _ in UInt8.random(in: 0...3, using: &rng) })
        let (d, url) = try doc(data)
        defer { try? FileManager.default.removeItem(at: url) }
        for _ in 0..<5 {
            let len = Int.random(in: 1...6, using: &rng)
            let p = SearchPattern((0..<len).map { _ in
                Int.random(in: 0...4, using: &rng) == 0 ? .any : .byte(UInt8.random(in: 0...3, using: &rng))
            })
            // The fast search stops at maxHits (e.g. a lone "??" hits every byte).
            #expect(Search.find(p, in: d.snapshot()) == Array(naiveFind(p, data).prefix(Search.maxHits)))
        }
    }

    @Test func acrossChunkBorder() throws {
        var data = Data(count: Search.chunk + 10)
        data.replaceSubrange(Search.chunk - 2 ..< Search.chunk + 2, with: [1, 2, 3, 4])
        let (d, url) = try doc(data)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(Search.find(.hex("01020304")!, in: d.snapshot()) == [UInt64(Search.chunk - 2) ..< UInt64(Search.chunk + 2)])
    }

    /// text in all encodings, with and without case.
    @Test func text() throws {
        var data = Data("xx Hallo xx HALLO".utf8)
        data.append("Hallo".data(using: .utf16LittleEndian)!)
        data.append("Hallo".data(using: .utf16BigEndian)!)
        let (d, url) = try doc(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let s = d.snapshot()
        #expect(Search.find(.text("Hallo", encoding: .utf8)!, in: s) == [3..<8])
        #expect(Search.find(.text("hallo", encoding: .ascii, ignoreCase: true)!, in: s).count == 2)
        #expect(Search.find(.text("Hallo", encoding: .utf16le)!, in: s) == [17..<27])
        #expect(Search.find(.text("HALLO", encoding: .utf16be, ignoreCase: true)!, in: s) == [27..<37])
        #expect(SearchPattern.text("Grüße", encoding: .ascii) == nil)
    }

    @Test func numbers() throws {
        var data = Data([0, 0])
        data.append(contentsOf: withUnsafeBytes(of: Int32(-2).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt16(0x1234).bigEndian, Array.init))
        let (d, url) = try doc(data)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(Search.find(.number("-2", kind: .int32, endian: .little)!, in: d.snapshot()) == [2..<6])
        #expect(Search.find(.number("4660", kind: .int16, endian: .big)!, in: d.snapshot()) == [6..<8])
        #expect(SearchPattern.number("300", kind: .int8, endian: .little) == nil)
    }

    @Test func cancel() throws {
        let (d, url) = try doc(Data(count: 3 * Search.chunk))
        defer { try? FileManager.default.removeItem(at: url) }
        var calls = 0
        _ = Search.find(.hex("01")!, in: d.snapshot()) { _ in calls += 1; return false }
        #expect(calls == 1)
    }

    /// replace all is one undo step.
    @Test func replaceAllUndo() throws {
        let (d, url) = try doc(Data("a-b-c-d".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let hits = Search.find(.text("-", encoding: .ascii)!, in: d.snapshot())
        try d.replaceAll(hits, with: Data("==".utf8))
        #expect(d.read(0..<100) == Data("a==b==c==d".utf8))
        d.undo()
        #expect(d.read(0..<100) == Data("a-b-c-d".utf8))
    }

    /// plain byte search speed (release build gives the real number).
    @Test func speed() throws {
        var rng = SplitMix(seed: 1)
        let data = Data((0..<(16 << 20)).map { _ in UInt8.random(in: 1...255, using: &rng) })
        let (d, url) = try doc(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let t0 = Date()
        _ = Search.find(.hex("00 11 22 33")!, in: d.snapshot())
        let mbps = 16 / Date().timeIntervalSince(t0)
        print("Suche: \(Int(mbps)) MB/s")
        // Debug build; release is checked by hand. Meaningless under a sanitizer.
        if ProcessInfo.processInfo.environment["HEXWERK_SANITIZER"] == nil { #expect(mbps > 100) }
    }
}

@Suite struct CompareTests {
    @Test func differences() throws {
        var a = Data(count: 1000), b = Data(count: 1003)
        a[5] = 1; b[5] = 2
        a.replaceSubrange(100..<110, with: Data(repeating: 7, count: 10))
        let (da, ua) = try doc(a), (db, ub) = try doc(b)
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub) }
        #expect(Compare.differences(da.snapshot(), db.snapshot()) == [5..<6, 100..<110, 1000..<1003])
    }

    /// same results as the system tools.
    @Test func checksums() throws {
        let (d, url) = try doc(Data("The quick brown fox jumps over the lazy dog".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let s = d.snapshot()
        #expect(Checksum.md5.compute(s) == "9e107d9d372bb6826bd81d3542a419d6")
        #expect(Checksum.sha1.compute(s) == "2fd4e1c67a2d28fced849ee1bb76e7391b93eb12")
        #expect(Checksum.sha256.compute(s) == "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
        #expect(Checksum.crc32.compute(s) == "414fa339")
        #expect(Checksum.crc32.compute(s, range: 0..<3) == Checksum.crc32.compute(try doc(Data("The".utf8)).0.snapshot()))
    }
}
