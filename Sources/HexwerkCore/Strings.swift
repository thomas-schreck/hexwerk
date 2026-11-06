import Foundation

/// Printable strings in binary data, like `strings`.
public struct FoundString: Sendable, Equatable, Hashable {
    public enum Encoding: String, Sendable, CaseIterable { case ascii = "ASCII", utf8 = "UTF-8", utf16le = "UTF-16LE", utf16be = "UTF-16BE" }
    public let offset: UInt64
    /// Length in bytes.
    public let length: UInt64
    public let encoding: Encoding
    /// Text, cut after `Strings.maxTextLength` characters.
    public let text: String
    public var range: Range<UInt64> { offset ..< offset + length }
}

public enum Strings {
    public static let maxTextLength = 256

    static func printable(_ c: UInt32) -> Bool {
        c == 9 || (0x20..<0x7F).contains(c) || (c >= 0xA0 && c != 0xFFFE && c != 0xFFFF && !(0xD800...0xDFFF).contains(c))
    }

    /// One pass per encoding; runs crossing chunk borders are kept.
    /// `minLength` counts characters. Results are sorted by offset.
    public static func find(_ snap: Snapshot, range: Range<UInt64>? = nil, minLength: Int = 4,
                            encodings: Set<FoundString.Encoding> = [.ascii, .utf16le], maxResults: Int = 200_000,
                            isCancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) -> [FoundString] {
        let r = (range ?? 0 ..< snap.count).clamped(to: 0 ..< snap.count)
        // UTF-8 finds everything ASCII finds (and more); skip duplicates.
        let encs = encodings.contains(.utf8) ? encodings.subtracting([.ascii]) : encodings
        // UTF-16 strings can start at even or odd offsets: one scanner per phase.
        var scanners = encs.sorted { $0.rawValue < $1.rawValue }.flatMap { e -> [Scanner] in
            e == .utf16le || e == .utf16be
                ? [Scanner(encoding: e, minLength: minLength, phase: 0), Scanner(encoding: e, minLength: minLength, phase: 1)]
                : [Scanner(encoding: e, minLength: minLength, phase: 0)]
        }
        let chunk: UInt64 = 4 << 20
        var pos = r.lowerBound
        var out: [FoundString] = []
        while pos < r.upperBound, out.count < maxResults {
            if isCancelled() { return out }
            let end = min(r.upperBound, pos + chunk)
            snap.withContiguousBytes(pos ..< end) { buf in
                for i in scanners.indices { scanners[i].feed(buf, base: pos, into: &out) }
            }
            pos = end
            progress(Double(pos - r.lowerBound) / Double(max(1, r.count)))
        }
        for i in scanners.indices { scanners[i].flush(into: &out) }
        out.sort { ($0.offset, $0.encoding.rawValue) < ($1.offset, $1.encoding.rawValue) }
        return Array(out.prefix(maxResults))
    }

    struct Scanner {
        let encoding: FoundString.Encoding
        let minLength: Int
        var start: UInt64 = 0
        var chars = 0
        var text = String.UnicodeScalarView()
        // Pending bytes of a partial UTF-8 / UTF-16 unit.
        var unit: [UInt8] = []
        var unitStart: UInt64 = 0
        var need = 0

        let phase: UInt64

        init(encoding: FoundString.Encoding, minLength: Int, phase: UInt64) {
            self.encoding = encoding
            self.minLength = minLength
            self.phase = phase
        }

        mutating func emit(_ end: UInt64, into out: inout [FoundString]) {
            if chars >= minLength {
                out.append(FoundString(offset: start, length: end - start, encoding: encoding, text: String(text)))
            }
            chars = 0
            text = String.UnicodeScalarView()
        }

        mutating func add(_ c: UInt32, at offset: UInt64, end: UInt64, into out: inout [FoundString]) {
            if printable(c), let s = Unicode.Scalar(c) {
                if chars == 0 { start = offset }
                chars += 1
                if chars <= Strings.maxTextLength { text.append(s) }
            } else {
                emit(offset, into: &out)
            }
            lastEnd = end
        }

        var lastEnd: UInt64 = 0

        mutating func feed(_ buf: UnsafeRawBufferPointer, base: UInt64, into out: inout [FoundString]) {
            for (i, b) in buf.enumerated() {
                let off = base + UInt64(i)
                switch encoding {
                case .ascii:
                    add(b < 0x80 ? UInt32(b) : 0, at: off, end: off + 1, into: &out)
                case .utf8:
                    if need == 0 {
                        switch b {
                        case 0..<0x80: add(UInt32(b), at: off, end: off + 1, into: &out)
                        case 0xC2...0xDF: unit = [b]; unitStart = off; need = 1
                        case 0xE0...0xEF: unit = [b]; unitStart = off; need = 2
                        case 0xF0...0xF4: unit = [b]; unitStart = off; need = 3
                        default: add(0, at: off, end: off + 1, into: &out)
                        }
                    } else if b & 0xC0 == 0x80 {
                        unit.append(b)
                        need -= 1
                        if need == 0 {
                            let c = String(decoding: unit, as: UTF8.self).unicodeScalars.first?.value ?? 0
                            // Overlong/invalid sequences decode to U+FFFD: not printable here.
                            add(c == 0xFFFD ? 0 : c, at: unitStart, end: off + 1, into: &out)
                        }
                    } else {
                        need = 0
                        add(0, at: unitStart, end: off, into: &out)
                        // Re-examine this byte as a start byte.
                        let sub = [b]
                        sub.withUnsafeBytes { feed($0, base: off, into: &out) }
                    }
                case .utf16le, .utf16be:
                    if unit.isEmpty {
                        guard (off &- phase) % 2 == 0 else { continue }
                        unit = [b]; unitStart = off; continue
                    }
                    unit.append(b)
                    let v = encoding == .utf16le ? UInt32(unit[0]) | UInt32(unit[1]) << 8 : UInt32(unit[0]) << 8 | UInt32(unit[1])
                    unit = []
                    // Only U+0000–U+00FF (ASCII, Latin-1 incl. umlauts), like
                    // `strings -el`: other byte pairs are mostly table noise.
                    add(v < 0x100 ? v : 0, at: unitStart, end: off + 1, into: &out)
                }
            }
        }

        mutating func flush(into out: inout [FoundString]) {
            emit(lastEnd, into: &out)
        }
    }
}

/// Regular expressions over raw bytes. Each byte is one
/// Latin-1 character, so `\x00`, `[\x80-\xff]` and offsets map 1:1.
public enum RegexSearch {
    /// Longest match that is still found across a chunk border.
    public static let overlap = 4096

    public static func find(_ pattern: String, ignoreCase: Bool = false, in snap: Snapshot,
                            range: Range<UInt64>? = nil, maxHits: Int = Search.maxHits,
                            progress: (Double) -> Bool = { _ in true }) throws -> [Range<UInt64>] {
        var opts: NSRegularExpression.Options = [.dotMatchesLineSeparators]
        if ignoreCase { opts.insert(.caseInsensitive) }
        let re = try NSRegularExpression(pattern: pattern, options: opts)
        let r = (range ?? 0 ..< snap.count).clamped(to: 0 ..< snap.count)
        let chunk: UInt64 = 4 << 20
        var hits: [Range<UInt64>] = []
        var pos = r.lowerBound
        var nextFree = r.lowerBound      // no overlapping hits, like the byte search
        while pos < r.upperBound, hits.count < maxHits {
            let end = min(r.upperBound, pos + chunk)
            let readEnd = min(r.upperBound, end + UInt64(overlap))
            let data = snap.read(pos ..< readEnd)
            let text = String(decoding: data.map { UInt16($0) }, as: UTF16.self) as NSString
            re.enumerateMatches(in: text as String, options: [], range: NSRange(location: 0, length: text.length)) { m, _, stop in
                guard let m, m.range.length > 0 else { return }
                let s = pos + UInt64(m.range.location)
                // Matches starting in the overlap belong to the next chunk.
                if s >= end && end < r.upperBound { stop.pointee = true; return }
                if s < nextFree { return }
                hits.append(s ..< s + UInt64(m.range.length))
                nextFree = s + UInt64(m.range.length)
                if hits.count >= maxHits { stop.pointee = true }
            }
            pos = end
            if !progress(Double(pos - r.lowerBound) / Double(max(1, r.count))) { break }
        }
        return hits
    }
}
