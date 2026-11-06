import Foundation

/// Byte statistics of a range (SPEC FR-9.1).
public struct ByteStats: Sendable, Codable, Equatable {
    public var histogram: [UInt64]
    public var count: UInt64

    public init(histogram: [UInt64] = Array(repeating: 0, count: 256)) {
        self.histogram = histogram
        count = histogram.reduce(0, +)
    }

    /// Shannon entropy in bits per byte (0 = constant, 8 = random).
    public var entropy: Double { Analysis.entropy(histogram, total: count) }
    public var distinct: Int { histogram.filter { $0 > 0 }.count }
    public var zeroRatio: Double { ratio(histogram[0]) }
    /// Printable ASCII plus tab, LF, CR.
    public var printableRatio: Double {
        ratio(histogram[0x20...0x7E].reduce(0, +) + histogram[9] + histogram[10] + histogram[13])
    }
    public var highRatio: Double { ratio(histogram[0x80...].reduce(0, +)) }

    private func ratio(_ n: UInt64) -> Double { count == 0 ? 0 : Double(n) / Double(count) }
}

/// Entropy per block over a range, for the overview chart.
public struct EntropyProfile: Sendable, Codable, Equatable {
    public let start: UInt64
    public let blockSize: UInt64
    public let blocks: [Double]

    public func range(ofBlock i: Int, total end: UInt64) -> Range<UInt64> {
        let s = start + UInt64(i) * blockSize
        return s ..< min(end, s + blockSize)
    }
}

public enum Analysis {
    public static func entropy(_ histogram: [UInt64], total: UInt64) -> Double {
        guard total > 0 else { return 0 }
        let n = Double(total)
        var h = 0.0
        for c in histogram where c > 0 {
            let p = Double(c) / n
            h -= p * log2(p)
        }
        return h
    }

    /// Histogram of all bytes in `range` plus entropy of about `blocks`
    /// equal blocks. Returns nil if cancelled. Reads in blocks, so memory
    /// stays small for any file size.
    public static func analyze(_ snap: Snapshot, range: Range<UInt64>? = nil, blocks: Int = 1024,
                               isCancelled: () -> Bool = { false },
                               progress: (Double) -> Void = { _ in }) -> (ByteStats, EntropyProfile)? {
        let r = (range ?? 0 ..< snap.count).clamped(to: 0 ..< snap.count)
        let n = UInt64(max(1, blocks))
        // At least 256 bytes per block, otherwise the per-block entropy says little.
        let blockSize = max(256, (UInt64(r.count) + n - 1) / n)
        var total = [UInt64](repeating: 0, count: 256)
        var profile: [Double] = []
        var pos = r.lowerBound
        var block = [UInt64](repeating: 0, count: 256)
        while pos < r.upperBound {
            if isCancelled() { return nil }
            let end = min(r.upperBound, pos + blockSize)
            for i in 0..<256 { block[i] = 0 }
            snap.withContiguousBytes(pos ..< end) { buf in
                block.withUnsafeMutableBufferPointer { h in
                    for b in buf { h[Int(b)] += 1 }
                }
            }
            for i in 0..<256 { total[i] += block[i] }
            profile.append(entropy(block, total: end - pos))
            pos = end
            progress(Double(pos - r.lowerBound) / Double(max(1, r.count)))
        }
        return (ByteStats(histogram: total), EntropyProfile(start: r.lowerBound, blockSize: blockSize, blocks: profile))
    }
}
