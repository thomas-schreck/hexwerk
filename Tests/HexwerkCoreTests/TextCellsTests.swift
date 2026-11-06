import Testing
@testable import HexwerkCore

@Suite struct TextCellsTests {
    @Test func utf8Spans() {
        let bytes = Array("aä中😀".utf8)   // 1 + 2 + 3 + 4 bytes
        let cells = TextCells.decode(bytes, as: .utf8)
        #expect(cells == [
            .char("a", span: 1),
            .char("ä", span: 2), .continuation,
            .char("中", span: 3), .continuation, .continuation,
            .char("😀", span: 4), .continuation, .continuation, .continuation,
        ])
    }

    @Test func invalidAndControl() {
        // Lone continuation, overlong "/" (C0 AF), surrogate (ED A0 80), NUL, cut-off ä.
        let cells = TextCells.decode([0x80, 0xC0, 0xAF, 0xED, 0xA0, 0x80, 0x00, 0xC3], as: .utf8)
        #expect(cells.allSatisfy { $0 == .unprintable })
    }

    @Test func contextBeforeVisibleRange() {
        // "ä" starts one byte before the visible part: only its continuation shows.
        let cells = TextCells.decode(Array("xä!".utf8), from: 2, as: .utf8)
        #expect(cells == [.continuation, .char("!", span: 1)])
    }

    @Test func latin1AndAscii() {
        #expect(TextCells.decode([0x41, 0xE4, 0x09], as: .latin1) == [.char("A", span: 1), .char("ä", span: 1), .unprintable])
        #expect(TextCells.decode([0x41, 0xE4], as: .ascii) == [.char("A", span: 1), .unprintable])
    }

    @Test func combiningMarkAloneIsUnprintable() {
        #expect(TextCells.decode(Array("\u{0301}".utf8), as: .utf8) == [.unprintable, .continuation])
    }

    /// Random bytes must not trap and must keep the cell count.
    @Test func robust() {
        var rng = SplitMix(seed: 3)
        for _ in 0..<500 {
            let b = (0..<Int.random(in: 0...40, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            let from = b.isEmpty ? 0 : Int.random(in: 0...min(3, b.count), using: &rng)
            #expect(TextCells.decode(b, from: from, as: .utf8).count == b.count - from)
        }
    }
}
