import Foundation
import Testing
@testable import HexwerkCore
@testable import HexwerkKaitai

/// Highlight rules, structure hover path and entropy chart mapping (#141).
@Suite struct HighlightRuleTests {
    let block = HighlightMatcher.blockSize

    func hits(_ rules: [HighlightRule], _ data: Data, window: Range<UInt64>? = nil) throws -> [HighlightHit] {
        let (d, url) = try doc(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let snap = d.snapshot()
        let m = HighlightMatcher(rules)
        let w = window ?? 0 ..< snap.count
        var cache = HighlightCache()
        let blocks = m.blocks(covering: w)
        for b in cache.missing(blocks) { cache.store(try #require(m.hits(inBlock: b, of: snap)), forBlock: b) }
        return cache.hits(in: w, blocks: blocks)
    }

    @Test func validity() {
        #expect(HighlightRule(kind: .hex, pattern: "4D 5A ?? 00").isValid)
        #expect(!HighlightRule(kind: .hex, pattern: "4D 5").isValid)
        #expect(!HighlightRule(kind: .hex, pattern: "").isValid)
        #expect(HighlightRule(kind: .text, pattern: "PK").isValid)
        #expect(HighlightRule(kind: .regex, pattern: "[a-z]+").isValid)
        #expect(!HighlightRule(kind: .regex, pattern: "(").isValid)
        #expect(!HighlightRule(kind: .regex, pattern: "").isValid)
    }

    @Test func hexTextAndRegexRules() throws {
        let data = Data("..MZ".utf8) + Data([0x90, 0x00]) + Data("..mz..abc123".utf8)
        let found = try hits(
            [
                HighlightRule(kind: .hex, pattern: "4D 5A ?? 00", color: 1),
                HighlightRule(kind: .text, pattern: "mz", color: 2, ignoreCase: true),
                HighlightRule(kind: .regex, pattern: "[0-9]+", color: 3),
                HighlightRule(kind: .hex, pattern: "2E 2E", color: 4, enabled: false),
                HighlightRule(kind: .hex, pattern: "XYZ", color: 5),  // invalid: ignored
            ], data)
        // Rule order is kept, so later rules draw on top.
        #expect(
            found == [
                HighlightHit(range: 2 ..< 6, color: 1),
                HighlightHit(range: 2 ..< 4, color: 2),
                HighlightHit(range: 8 ..< 10, color: 2),
                HighlightHit(range: 15 ..< 18, color: 3),
            ])
    }

    /// Hex rules take the nibble wildcards of the hex search (#142).
    @Test func nibbleRules() throws {
        #expect(HighlightRule(kind: .hex, pattern: "4? ?D").isValid)
        let data = Data([0x41, 0x0D, 0x00, 0x4F, 0x3D, 0x5D, 0x7E])
        let found = try hits(
            [
                HighlightRule(kind: .hex, pattern: "4? ?D", color: 1),
                HighlightRule(kind: .hex, pattern: "?E", color: 2),
            ], data)
        #expect(
            found == [
                HighlightHit(range: 0 ..< 2, color: 1),
                HighlightHit(range: 3 ..< 5, color: 1),
                HighlightHit(range: 6 ..< 7, color: 2),
            ])
    }

    /// Runs of single-byte hits become one range, so a zero-filled page is
    /// one rectangle per row instead of thousands.
    @Test func zeroRunsMerge() throws {
        let data = Data([1, 0, 0, 0, 2, 0, 3])
        #expect(
            try hits([.zeroBytes(color: 8)], data) == [
                HighlightHit(range: 1 ..< 4, color: 8), HighlightHit(range: 5 ..< 6, color: 8),
            ])
    }

    /// A match crossing a block border belongs to the block it starts in and
    /// is still drawn when only the second block is visible.
    @Test func matchAcrossBlockBorder() throws {
        var data = Data(count: Int(block) * 2)
        let at = Int(block) - 2
        data.replaceSubrange(at ..< at + 4, with: [0xDE, 0xAD, 0xBE, 0xEF])
        let rule = HighlightRule(kind: .hex, pattern: "DE AD BE EF")
        let second = block ..< block + 16
        #expect(HighlightMatcher([rule]).blocks(covering: second) == 0 ... 1)
        #expect(try hits([rule], data, window: second) == [HighlightHit(range: block - 2 ..< block + 2, color: 0)])
        #expect(try hits([rule], data) == [HighlightHit(range: block - 2 ..< block + 2, color: 0)])
    }

    /// Only the blocks around the window are scanned, not the whole file.
    @Test func onlyVisibleBlocks() {
        let m = HighlightMatcher([HighlightRule(kind: .hex, pattern: "00")])
        #expect(m.blocks(covering: 10 * block + 100 ..< 10 * block + 900) == 10 ... 10)
        #expect(HighlightMatcher([HighlightRule(kind: .regex, pattern: "a")]).blocks(covering: 10 * block ..< 10 * block + 1) == 9 ... 10)
        #expect(m.blocks(covering: 0 ..< 1) == 0 ... 0)
    }

    @Test func cancelledReturnsNil() throws {
        let (d, url) = try doc(Data(count: 1000))
        defer { try? FileManager.default.removeItem(at: url) }
        let m = HighlightMatcher([HighlightRule(kind: .regex, pattern: "\\x00+")])
        #expect(m.hits(inBlock: 0, of: d.snapshot(), isCancelled: { true }) == nil)
        #expect(m.hits(inBlock: 99, of: d.snapshot()) == [])
    }

    /// A catastrophic regex must stop when the view no longer needs it,
    /// not only after it finished backtracking.
    @Test func slowRegexStopsWhenCancelled() throws {
        let (d, url) = try doc(Data(repeating: UInt8(ascii: "a"), count: Int(block)))
        defer { try? FileManager.default.removeItem(at: url) }
        let m = HighlightMatcher([HighlightRule(kind: .regex, pattern: "(a+)+b")])
        let start = Date()
        #expect(m.hits(inBlock: 0, of: d.snapshot(), isCancelled: { Date().timeIntervalSince(start) > 0.2 }) == nil)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func cacheIsBounded() {
        var c = HighlightCache()
        for b in 0 ..< UInt64(HighlightCache.maxBlocks + 10) { c.store([], forBlock: b) }
        #expect(c.blocks.count <= HighlightCache.maxBlocks)
        #expect(c.missing(0 ... 2).count <= 3)
    }

    // MARK: Persistence

    @Test func projectKeepsRules() throws {
        let central = FileManager.default.temporaryDirectory.appendingPathComponent("hexwerk-rules-\(UUID().uuidString)")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hexwerk-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { for d in [central, folder] { try? FileManager.default.removeItem(at: d) } }
        let file = folder.appendingPathComponent("fw.bin")
        try Data([1, 2, 3]).write(to: file)
        var s = ProjectState(filePath: file.path, fileSize: 3)
        s.highlightRules = [
            HighlightRule(kind: .hex, pattern: "FF ?? FF", color: 3),
            HighlightRule(kind: .regex, pattern: "abc", color: 1, enabled: false, ignoreCase: true),
        ]
        #expect(!s.isTrivial)
        // Rules are worth a project file next to the file, like bookmarks.
        #expect(try ProjectStore.save(s, for: file, in: central) == ProjectStore.sidecar(for: file))
        #expect(ProjectStore.load(for: file, in: central)?.highlightRules == s.highlightRules)
    }

    @Test func olderProjectsAndHandWrittenRulesLoad() throws {
        let old = #"{"filePath": "/x.bin", "fileSize": 4}"#
        #expect(try JSONDecoder().decode(ProjectState.self, from: Data(old.utf8)).highlightRules == [])
        let hand = #"{"filePath": "/x.bin", "fileSize": 4, "highlightRules": [{"kind": "text", "pattern": "PK"}]}"#
        let r = try #require(try JSONDecoder().decode(ProjectState.self, from: Data(hand.utf8)).highlightRules.first)
        #expect(r.kind == .text && r.pattern == "PK" && r.enabled && !r.ignoreCase && r.color == 0)
    }

    /// Global rules go through the JSON settings file as plain objects.
    @Test func settingsRoundTrip() throws {
        let rules = [HighlightRule(kind: .text, pattern: "ELF", color: 5, ignoreCase: true)]
        let file = try JSONSerialization.data(withJSONObject: ["highlightRules": HighlightRule.jsonObject(rules)])
        let back = try #require(try JSONSerialization.jsonObject(with: file) as? [String: Any])
        #expect(HighlightRule.rules(fromJSONObject: back["highlightRules"]) == rules)
        #expect(HighlightRule.rules(fromJSONObject: nil) == [])
        #expect(HighlightRule.rules(fromJSONObject: [["kind": "nope"], ["kind": "hex", "pattern": "00"]]).count == 1)
    }

    // MARK: Hover and entropy chart

    @Test func hoverPath() throws {
        let r = try parse(
            Data([1, 2, 3, 4, 5, 6]),
            yaml: """
                meta: {id: t, endian: le}
                seq:
                  - {id: magic, type: u2}
                  - {id: hdr, type: header}
                types:
                  header:
                    seq:
                      - {id: a, type: u1}
                      - {id: b, type: u1}
                """)
        #expect(r.root.path(to: 3).map(\.name) == [r.root.name, "hdr", "b"])
        #expect(r.root.path(to: 0).map(\.name) == [r.root.name, "magic"])
        #expect(r.root.path(to: 100).count == 1)
    }

    @Test func entropyChartMapping() {
        let p = EntropyProfile(start: 0x100, blockSize: 0x100, blocks: [1, 2, 3, 4])
        #expect(p.block(atFraction: 0) == 0)
        #expect(p.block(atFraction: 0.6) == 2)
        #expect(p.block(atFraction: 1.5) == 3)
        #expect(p.block(atFraction: -1) == 0)
        #expect(p.block(atFraction: .nan) == 0)
        // Dragging right to left selects the same bytes; the end is clamped.
        #expect(p.range(fromBlock: 3, toBlock: 1, total: 0x480) == 0x200 ..< 0x480)
        #expect(p.range(fromBlock: 0, toBlock: 0, total: 0x480) == 0x100 ..< 0x200)
    }
}
