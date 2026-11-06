import Foundation

/// Bytes for "Fill Selection": a pattern repeated over a range.
public enum FillPattern {
    /// Above this size the app asks before filling: the bytes are held in
    /// memory (the document's added buffer) until the file is saved.
    public static let confirmAbove: UInt64 = 64 << 20

    /// Refused outright: more than half the machine's memory would swap
    /// or crash rather than fill.
    public static var maximum: UInt64 { ProcessInfo.processInfo.physicalMemory / 2 }

    /// `pattern` repeated to exactly `count` bytes (the last repeat cut
    /// short). Built by doubling, so a large fill costs a few big copies
    /// instead of one append per repeat.
    public static func bytes(_ pattern: Data, count: Int) -> Data {
        guard count > 0, !pattern.isEmpty else { return Data() }
        if pattern.count == 1 { return Data(repeating: pattern[pattern.startIndex], count: count) }
        var out = Data(capacity: count)
        out.append(pattern.prefix(count))
        while out.count < count {
            out.append(out.prefix(count - out.count))
        }
        return out
    }
}
