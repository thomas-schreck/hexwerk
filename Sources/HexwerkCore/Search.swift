import Foundation

/// A byte pattern with wildcards and case-insensitive letters.
public struct SearchPattern: Sendable, Equatable {
    public enum Element: Sendable, Equatable {
        case byte(UInt8)
        case any  // ?? in hex
        case either(UInt8, UInt8)  // ASCII letter, either case
        /// One nibble fixed, the other a wildcard (4? or ?D in hex): a byte
        /// matches when `byte & mask == value`.
        case nibble(value: UInt8, mask: UInt8)
    }
    public let elements: [Element]

    public init(_ elements: [Element]) { self.elements = elements }

    public var count: Int { elements.count }

    /// Hex like "4D 5A ?? 00" (spaces optional). `?` stands for one
    /// nibble: "4?" matches 40–4F, "?D" every byte ending in D, "??" any
    /// byte. Nil if malformed.
    public static func hex(_ text: String) -> SearchPattern? {
        let s = Array(text.unicodeScalars.filter { !Character($0).isWhitespace })
        guard !s.isEmpty, s.count % 2 == 0 else { return nil }
        /// Nibble value, -1 for "?", nil if neither.
        func nibble(_ c: Unicode.Scalar) -> Int? {
            c == "?" ? -1 : c.properties.isASCIIHexDigit ? Int(String(c), radix: 16) : nil
        }
        var out: [Element] = []
        out.reserveCapacity(s.count / 2)
        for i in stride(from: 0, to: s.count, by: 2) {
            guard let hi = nibble(s[i]), let lo = nibble(s[i + 1]) else { return nil }
            switch (hi, lo) {
            case (-1, -1): out.append(.any)
            case (-1, _): out.append(.nibble(value: UInt8(lo), mask: 0x0F))
            case (_, -1): out.append(.nibble(value: UInt8(hi << 4), mask: 0xF0))
            default: out.append(.byte(UInt8(hi << 4 | lo)))
            }
        }
        return SearchPattern(out)
    }

    public enum TextEncoding: String, Sendable, CaseIterable {
        case ascii, utf8, utf16le, utf16be
    }

    /// Text in the given encoding. `ignoreCase` only affects ASCII letters.
    public static func text(_ text: String, encoding: TextEncoding, ignoreCase: Bool = false) -> SearchPattern? {
        guard !text.isEmpty else { return nil }
        if encoding == .ascii && !text.allSatisfy(\.isASCII) { return nil }
        func letter(_ b: UInt8) -> Element {
            guard ignoreCase, let c = Optional(Character(UnicodeScalar(b))), c.isASCII, c.isLetter else { return .byte(b) }
            let lower = UInt8(ascii: c.lowercased().unicodeScalars.first!)
            let upper = UInt8(ascii: c.uppercased().unicodeScalars.first!)
            return .either(lower, upper)
        }
        switch encoding {
        case .ascii, .utf8:
            return SearchPattern(Array(text.utf8).map(letter))
        case .utf16le, .utf16be:
            var out: [Element] = []
            for u in text.utf16 {
                let lo = UInt8(u & 0xFF), hi = UInt8(u >> 8)
                let loEl = hi == 0 ? letter(lo) : .byte(lo)
                out += encoding == .utf16le ? [loEl, .byte(hi)] : [.byte(hi), loEl]
            }
            return SearchPattern(out)
        }
    }

    public enum NumberKind: String, Sendable, CaseIterable {
        case int8, int16, int32, int64, float32, float64
    }

    /// A number as it would be stored in a file. Nil if it doesn't fit.
    public static func number(_ text: String, kind: NumberKind, endian: Endian) -> SearchPattern? {
        var bytes: [UInt8]
        func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        switch kind {
        case .int8:
            if let v = Int8(text) { bytes = le(v) } else if let v = UInt8(text) { bytes = le(v) } else { return nil }
        case .int16:
            if let v = Int16(text) { bytes = le(v) } else if let v = UInt16(text) { bytes = le(v) } else { return nil }
        case .int32:
            if let v = Int32(text) { bytes = le(v) } else if let v = UInt32(text) { bytes = le(v) } else { return nil }
        case .int64:
            if let v = Int64(text) { bytes = le(v) } else if let v = UInt64(text) { bytes = le(v) } else { return nil }
        case .float32:
            guard let v = Float(text) else { return nil }
            bytes = le(v.bitPattern)
        case .float64:
            guard let v = Double(text) else { return nil }
            bytes = le(v.bitPattern)
        }
        if endian == .big { bytes.reverse() }
        return SearchPattern(bytes.map { .byte($0) })
    }

    func matches(_ p: UnsafePointer<UInt8>) -> Bool {
        for (i, e) in elements.enumerated() {
            switch e {
            case .byte(let b): if p[i] != b { return false }
            case .any: continue
            case .either(let a, let b): if p[i] != a && p[i] != b { return false }
            case .nibble(let value, let mask): if p[i] & mask != value { return false }
            }
        }
        return true
    }
}

public enum Search {
    /// More hits than this are not collected; the UI says "mehr als …".
    public static let maxHits = 100_000
    static let chunk = 8 << 20

    /// All matches of `pattern` in `range` of `snapshot`. `progress` gets the
    /// fraction done and returns false to cancel. Matches may not overlap
    /// (after a hit the search continues behind it), like in a text editor.
    public static func find(
        _ pattern: SearchPattern, in snapshot: Snapshot,
        range: Range<UInt64>? = nil,
        progress: (Double) -> Bool = { _ in true }
    ) -> [Range<UInt64>] {
        let r = (range ?? 0 ..< snapshot.count).clamped(to: 0 ..< snapshot.count)
        let n = pattern.count
        guard n > 0, r.count >= n else { return [] }

        // Anchor on the first fixed byte and let memchr skip ahead to it.
        let anchor = pattern.elements.firstIndex { if case .byte = $0 { true } else { false } }
        var hits: [Range<UInt64>] = []
        var pos = r.lowerBound
        let total = Double(r.count)

        while pos + UInt64(n) <= r.upperBound {
            // Overlap n-1 bytes so matches across chunk borders are found.
            let end = min(r.upperBound, pos + UInt64(chunk) + UInt64(n - 1))
            let data = snapshot.read(pos ..< end)
            var nextPos = pos + UInt64(data.count - n + 1)
            data.withUnsafeBytes { raw in
                let base = raw.bindMemory(to: UInt8.self).baseAddress!
                let last = data.count - n  // last valid start
                var i = 0
                while i <= last {
                    if let a = anchor, case .byte(let b) = pattern.elements[a] {
                        guard let hit = memchr(base + i + a, Int32(b), last - i + 1) else { break }
                        i = base.distance(to: hit.assumingMemoryBound(to: UInt8.self)) - a
                    }
                    if pattern.matches(base + i) {
                        let at = pos + UInt64(i)
                        hits.append(at ..< at + UInt64(n))
                        if hits.count >= maxHits { return }
                        i += n
                        // A hit reaching into the overlap moves the next chunk start.
                        nextPos = max(nextPos, at + UInt64(n))
                    } else {
                        i += 1
                    }
                }
            }
            if hits.count >= maxHits { break }
            pos = nextPos
            if !progress(Double(pos - r.lowerBound) / total) { break }
        }
        return hits
    }
}
