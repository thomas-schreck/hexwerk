import Foundation

/// One difference between two files, with offsets in both.
public struct DiffOp: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case replace, insert, delete    // insert: only in B; delete: only in A
    }
    public let kind: Kind
    public let a: Range<UInt64>
    public let b: Range<UInt64>

    public init(_ kind: Kind, a: Range<UInt64>, b: Range<UInt64>) {
        self.kind = kind
        self.a = a
        self.b = b
    }
}

/// Comparison that realigns after inserted or deleted bytes, like a text
/// diff but for binaries: anchors from content-defined samples (as in
/// rsync), extended in both directions; small gaps get an exact LCS.
public enum AlignedDiff {
    /// Both files are read into memory; beyond this, fall back to `positional`.
    public static let maxSize: UInt64 = 256 << 20
    /// Gaps up to this size (each side) are solved exactly.
    static let exactGap = 2048
    static let k = 32                  // anchor length in bytes
    static let sampleMask: UInt64 = 31 // ~1 sample per 32 positions

    public static func diff(_ a: Snapshot, _ b: Snapshot) -> [DiffOp] {
        if a.count > maxSize || b.count > maxSize { return positional(a, b) }
        let x = [UInt8](a.read(0 ..< a.count)), y = [UInt8](b.read(0 ..< b.count))
        return diff(x, y)
    }

    /// Old behavior: equal offsets, no realignment; a longer tail is
    /// reported as insert/delete. At most `Search.maxHits` operations.
    public static func positional(_ a: Snapshot, _ b: Snapshot) -> [DiffOp] {
        let common = min(a.count, b.count)
        let ranges = Compare.differences(a, b)
        if ranges.count >= Search.maxHits {
            return ranges.prefix(Search.maxHits).map { DiffOp(.replace, a: $0, b: $0) }
        }
        var out = ranges.filter { $0.upperBound <= common }.map { DiffOp(.replace, a: $0, b: $0) }
        if a.count > b.count { out.append(DiffOp(.delete, a: common ..< a.count, b: common ..< common)) }
        if b.count > a.count { out.append(DiffOp(.insert, a: common ..< common, b: common ..< b.count)) }
        return out
    }

    /// True if `ops` from `diff(a, b)` / `positional` stopped at the hit
    /// limit (only the positional comparison has one).
    public static func isTruncated(_ ops: [DiffOp], _ a: Snapshot, _ b: Snapshot, positional: Bool = false) -> Bool {
        (positional || a.count > maxSize || b.count > maxSize) && ops.count >= Search.maxHits
    }

    public static func diff(_ x: [UInt8], _ y: [UInt8]) -> [DiffOp] {
        var out: [DiffOp] = []
        var blocks = matchingBlocks(x, y)
        // Sentinel block at the end so the trailing gap is handled too.
        blocks.append((x.count, y.count, 0))
        var ai = 0, bi = 0
        for (aStart, bStart, len) in blocks {
            gap(x, y, ai ..< aStart, bi ..< bStart, into: &out)
            ai = aStart + len
            bi = bStart + len
        }
        return merge(out)
    }

    // MARK: Anchors

    /// Non-overlapping, increasing matching blocks (aStart, bStart, length).
    static func matchingBlocks(_ x: [UInt8], _ y: [UInt8]) -> [(Int, Int, Int)] {
        guard x.count >= k, y.count >= k else { return trivialBlocks(x, y) }
        // 1. Sampled k-gram hashes of A; duplicates are useless as anchors.
        var index: [UInt64: Int] = [:]
        rolling(x) { h, i in
            guard h & sampleMask == 0 else { return }
            if let old = index[h] { if old >= 0 { index[h] = -1 } } else { index[h] = i }
        }
        // 2. The same samples in B, verified byte by byte.
        var pairs: [(Int, Int)] = []
        rolling(y) { h, j in
            guard h & sampleMask == 0, let i = index[h], i >= 0 else { return }
            if x[i ..< i + k].elementsEqual(y[j ..< j + k]) { pairs.append((i, j)) }
        }
        // 3. Longest chain increasing in both files (pairs are sorted by j).
        let chain = longestIncreasing(pairs)
        // 4. Extend each anchor in both directions; keep blocks disjoint.
        var blocks: [(Int, Int, Int)] = []
        var lastA = 0, lastB = 0
        for (i0, j0) in chain {
            guard i0 >= lastA, j0 >= lastB else { continue }
            var i = i0, j = j0
            while i > lastA, j > lastB, x[i - 1] == y[j - 1] { i -= 1; j -= 1 }
            var e = i0 + k, f = j0 + k
            while e < x.count, f < y.count, x[e] == y[f] { e += 1; f += 1 }
            blocks.append((i, j, e - i))
            lastA = e
            lastB = f
        }
        if blocks.isEmpty { return trivialBlocks(x, y) }
        return blocks
    }

    /// Common prefix and suffix only (inputs too short or no anchors).
    static func trivialBlocks(_ x: [UInt8], _ y: [UInt8]) -> [(Int, Int, Int)] {
        var p = 0
        while p < x.count, p < y.count, x[p] == y[p] { p += 1 }
        var s = 0
        while s < x.count - p, s < y.count - p, x[x.count - 1 - s] == y[y.count - 1 - s] { s += 1 }
        var out: [(Int, Int, Int)] = []
        if p > 0 { out.append((0, 0, p)) }
        if s > 0 { out.append((x.count - s, y.count - s, s)) }
        return out
    }

    /// Rabin–Karp over every k-byte window: calls `body(hash, start)`.
    static func rolling(_ d: [UInt8], _ body: (UInt64, Int) -> Void) {
        let base: UInt64 = 0x100000001B3
        var pow: UInt64 = 1
        for _ in 0 ..< k - 1 { pow = pow &* base }
        var h: UInt64 = 0
        d.withUnsafeBufferPointer { p in
            for i in 0 ..< k { h = h &* base &+ UInt64(p[i]) }
            // Mix so the low bits used for sampling are well distributed.
            func mix(_ v: UInt64) -> UInt64 { var z = v ^ v >> 31; z = z &* 0x7FB5D329728EA185; return z ^ z >> 27 }
            body(mix(h), 0)
            var i = 1
            while i + k <= p.count {
                h = (h &- UInt64(p[i - 1]) &* pow) &* base &+ UInt64(p[i + k - 1])
                body(mix(h), i)
                i += 1
            }
        }
    }

    /// Longest subsequence strictly increasing in .0 (input sorted by .1).
    static func longestIncreasing(_ pairs: [(Int, Int)]) -> [(Int, Int)] {
        var tails: [Int] = []           // index into pairs of the smallest tail per length
        var prev = [Int](repeating: -1, count: pairs.count)
        for (n, p) in pairs.enumerated() {
            var lo = 0, hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if pairs[tails[mid]].0 < p.0 { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { prev[n] = tails[lo - 1] }
            if lo == tails.count { tails.append(n) } else { tails[lo] = n }
        }
        var out: [(Int, Int)] = []
        var n = tails.last ?? -1
        while n >= 0 { out.append(pairs[n]); n = prev[n] }
        return out.reversed()
    }

    // MARK: Gaps

    static func gap(_ x: [UInt8], _ y: [UInt8], _ ra: Range<Int>, _ rb: Range<Int>, into out: inout [DiffOp]) {
        func op(_ kind: DiffOp.Kind, _ a: Range<Int>, _ b: Range<Int>) {
            out.append(DiffOp(kind, a: UInt64(a.lowerBound) ..< UInt64(a.upperBound), b: UInt64(b.lowerBound) ..< UInt64(b.upperBound)))
        }
        if ra.isEmpty && rb.isEmpty { return }
        if ra.isEmpty { op(.insert, ra, rb); return }
        if rb.isEmpty { op(.delete, ra, rb); return }
        if ra.count == rb.count {
            // Same length: changed bytes in place (the common case of patches).
            var i = 0, start: Int?
            while i <= ra.count {
                let differs = i < ra.count && x[ra.lowerBound + i] != y[rb.lowerBound + i]
                if differs, start == nil { start = i }
                if !differs, let s = start {
                    op(.replace, ra.lowerBound + s ..< ra.lowerBound + i, rb.lowerBound + s ..< rb.lowerBound + i)
                    start = nil
                }
                i += 1
            }
            return
        }
        if ra.count <= exactGap && rb.count <= exactGap {
            lcs(x, y, ra, rb, into: &out)
        } else {
            op(.replace, ra, rb)
        }
    }

    /// Exact LCS by dynamic programming (gaps are small).
    static func lcs(_ x: [UInt8], _ y: [UInt8], _ ra: Range<Int>, _ rb: Range<Int>, into out: inout [DiffOp]) {
        let n = ra.count, m = rb.count
        var t = [UInt16](repeating: 0, count: (n + 1) * (m + 1))
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                t[i * (m + 1) + j] = x[ra.lowerBound + i] == y[rb.lowerBound + j]
                    ? t[(i + 1) * (m + 1) + j + 1] + 1
                    : max(t[(i + 1) * (m + 1) + j], t[i * (m + 1) + j + 1])
            }
        }
        var i = 0, j = 0
        func emit(_ kind: DiffOp.Kind, _ a: Int, _ a2: Int, _ b: Int, _ b2: Int) {
            out.append(DiffOp(kind, a: UInt64(ra.lowerBound + a) ..< UInt64(ra.lowerBound + a2),
                              b: UInt64(rb.lowerBound + b) ..< UInt64(rb.lowerBound + b2)))
        }
        while i < n || j < m {
            if i < n, j < m, x[ra.lowerBound + i] == y[rb.lowerBound + j] { i += 1; j += 1; continue }
            if j < m, i == n || t[i * (m + 1) + j + 1] >= t[(i + 1) * (m + 1) + j] {
                emit(.insert, i, i, j, j + 1); j += 1
            } else {
                emit(.delete, i, i + 1, j, j); i += 1
            }
        }
    }

    /// Joins neighbouring ops; delete+insert at the same spot become replace.
    static func merge(_ ops: [DiffOp]) -> [DiffOp] {
        var out: [DiffOp] = []
        for o in ops {
            guard let last = out.last, last.a.upperBound == o.a.lowerBound, last.b.upperBound == o.b.lowerBound else {
                out.append(o)
                continue
            }
            let kind: DiffOp.Kind = last.kind == o.kind ? o.kind : .replace
            out[out.count - 1] = DiffOp(kind, a: last.a.lowerBound ..< o.a.upperBound, b: last.b.lowerBound ..< o.b.upperBound)
        }
        // A replace with one empty side is really an insert or delete.
        return out.map { o in
            if o.a.isEmpty { return DiffOp(.insert, a: o.a, b: o.b) }
            if o.b.isEmpty { return DiffOp(.delete, a: o.a, b: o.b) }
            return o
        }
    }
}
