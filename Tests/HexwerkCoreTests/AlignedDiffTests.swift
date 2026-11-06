import Foundation
import Testing
@testable import HexwerkCore

@Suite struct AlignedDiffTests {
    /// Rebuilds B from A and the ops (ops are ordered and disjoint).
    func apply(_ ops: [DiffOp], _ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var pos = 0
        for o in ops {
            out += a[pos ..< Int(o.a.lowerBound)]
            out += b[Int(o.b.lowerBound) ..< Int(o.b.upperBound)]
            pos = Int(o.a.upperBound)
        }
        return out + a[pos...]
    }

    func random(_ n: Int, _ rng: inout SplitMix) -> [UInt8] { (0 ..< n).map { _ in UInt8.random(in: 0...255, using: &rng) } }

    @Test func simpleCases() {
        let a: [UInt8] = Array(0 ..< 200).map { UInt8($0) }
        #expect(AlignedDiff.diff(a, a).isEmpty)
        var b = a; b.insert(contentsOf: [0xAA, 0xBB], at: 50)
        #expect(AlignedDiff.diff(a, b) == [DiffOp(.insert, a: 50 ..< 50, b: 50 ..< 52)])
        var c = a; c.removeSubrange(100 ..< 110)
        #expect(AlignedDiff.diff(a, c) == [DiffOp(.delete, a: 100 ..< 110, b: 100 ..< 100)])
        var d = a; d[7] = 0xFF; d[8] = 0xFF
        #expect(AlignedDiff.diff(a, d) == [DiffOp(.replace, a: 7 ..< 9, b: 7 ..< 9)])
        #expect(AlignedDiff.diff([], [1, 2]) == [DiffOp(.insert, a: 0 ..< 0, b: 0 ..< 2)])
        #expect(AlignedDiff.diff([1, 2], []) == [DiffOp(.delete, a: 0 ..< 2, b: 0 ..< 0)])
    }

    @Test func realignsAfterInsertInLargeFile() {
        var rng = SplitMix(seed: 11)
        let a = random(300_000, &rng)
        var b = a
        b.insert(contentsOf: random(1234, &rng), at: 100_000)
        b[250_000] ^= 0xFF                                   // and one changed byte later
        let ops = AlignedDiff.diff(a, b)
        #expect(ops == [DiffOp(.insert, a: 100_000 ..< 100_000, b: 100_000 ..< 101_234),
                        DiffOp(.replace, a: 248_766 ..< 248_767, b: 250_000 ..< 250_001)])
    }

    /// Random edit sequences: the ops must rebuild B exactly and stay
    /// close to the real amount of change.
    @Test func reconstructsRandomEdits() {
        var rng = SplitMix(seed: 2026)
        for round in 0 ..< 25 {
            let a = random(Int.random(in: 0 ... 60_000, using: &rng), &rng)
            var b = a
            var changed = 0
            for _ in 0 ..< Int.random(in: 0 ... 12, using: &rng) {
                let pos = Int.random(in: 0 ... b.count, using: &rng)
                let n = Int.random(in: 1 ... 300, using: &rng)
                switch Int.random(in: 0 ... 2, using: &rng) {
                case 0: b.insert(contentsOf: random(n, &rng), at: pos)
                case 1: b.removeSubrange(pos ..< min(b.count, pos + n))
                default: for i in pos ..< min(b.count, pos + n) { b[i] = UInt8.random(in: 0...255, using: &rng) }
                }
                changed += n
            }
            let ops = AlignedDiff.diff(a, b)
            #expect(apply(ops, a, b) == b, "round \(round)")
            let size = ops.reduce(0) { $0 + max($1.a.count, $1.b.count) }
            #expect(size <= changed * 3 + 64, "round \(round): \(size) for \(changed)")
        }
    }

    @Test func positionalFallback() throws {
        let ua = try tempFile(Data([1, 2, 3, 4])), ub = try tempFile(Data([1, 9, 3, 4, 5, 6]))
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub) }
        let sa = try Document(url: ua).snapshot(), sb = try Document(url: ub).snapshot()
        #expect(AlignedDiff.positional(sa, sb) == [DiffOp(.replace, a: 1 ..< 2, b: 1 ..< 2), DiffOp(.insert, a: 4 ..< 4, b: 4 ..< 6)])
    }
}
