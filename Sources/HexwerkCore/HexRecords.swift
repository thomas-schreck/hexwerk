import Foundation

/// Intel HEX and Motorola S-Record: text formats for
/// firmware that carry bytes plus their load addresses.
public enum HexRecords {
    public enum Format: String, Sendable, CaseIterable {
        case intelHex = "Intel HEX", srec = "Motorola S-Record"

        public var fileExtension: String { self == .intelHex ? "hex" : "srec" }

        /// The format a file name ending stands for; nil for other endings.
        public init?(fileExtension ext: String) {
            switch ext.lowercased() {
            case "hex", "ihex", "ihx": self = .intelHex
            case "srec", "s19", "s28", "s37", "mot": self = .srec
            default: return nil
            }
        }

        /// Guess from the text: first non-empty line starts with ':' or 'S'.
        public static func detect(_ text: Substring) -> Format? {
            guard let line = text.split(whereSeparator: \.isNewline).first(where: { !$0.allSatisfy(\.isWhitespace) }) else { return nil }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(":") { return .intelHex }
            if t.hasPrefix("S"), t.count >= 4, let c = t.dropFirst().first, c.isNumber { return .srec }
            return nil
        }
    }

    public struct Segment: Sendable, Equatable {
        public var address: UInt64
        public var data: Data
        public var end: UInt64 { address + UInt64(data.count) }
    }

    public struct Image: Sendable {
        public var segments: [Segment]
        public var startAddress: UInt64?
        /// Intel HEX type 03 start (CS << 16 | IP), kept so it is written
        /// back as 03; `startAddress` holds the linear CS * 16 + IP.
        public var startSegment: UInt32? = nil
        /// S0 header text (S-Record only).
        public var header: String?
        /// Problems that do not stop the import (e.g. a missing end record).
        public var warnings: [String] = []

        /// Lowest address, the address of offset 0 in `flatten`.
        public var base: UInt64 { segments.map(\.address).min() ?? 0 }

        /// One contiguous buffer from the lowest to the highest address;
        /// gaps are filled with `fill` (0xFF = erased flash).
        public func flatten(fill: UInt8 = 0xFF, maxSize: UInt64 = 256 << 20) throws -> Data {
            guard let lo = segments.map(\.address).min(), let hi = segments.map(\.end).max() else { return Data() }
            guard hi - lo <= maxSize else { throw HexRecordError(line: 0, message: L("Address range too large (%@ bytes)", "\(hi - lo)")) }
            var out = Data(repeating: fill, count: Int(hi - lo))
            for s in segments { out.replaceSubrange(Int(s.address - lo) ..< Int(s.end - lo), with: s.data) }
            return out
        }

        /// Address ranges without data (filled by `flatten`).
        public var gaps: [Range<UInt64>] {
            let sorted = segments.sorted { $0.address < $1.address }
            var out: [Range<UInt64>] = []
            var pos = sorted.first?.address ?? 0
            for s in sorted {
                if s.address > pos { out.append(pos ..< s.address) }
                pos = max(pos, s.end)
            }
            return out
        }
    }

    public struct HexRecordError: Error, CustomStringConvertible {
        public let line: Int
        public let message: String
        public var description: String { line > 0 ? L("Line %ld: %@", line, message) : message }
    }

    // MARK: Parsing

    public static func parse(_ text: String) throws -> Image {
        switch Format.detect(text[...]) {
        case .intelHex: try parseIntelHex(text)
        case .srec: try parseSRecord(text)
        case nil: throw HexRecordError(line: 1, message: L("neither Intel HEX nor S-Record"))
        }
    }

    static func bytes(_ hex: Substring, line: Int) throws -> [UInt8] {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { throw HexRecordError(line: line, message: L("odd number of hex digits")) }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        func nib(_ c: UInt8) throws -> UInt8 {
            switch c {
            case 0x30...0x39: c - 0x30
            case 0x41...0x46: c - 0x37
            case 0x61...0x66: c - 0x57
            default: throw HexRecordError(line: line, message: L("invalid character"))
            }
        }
        var i = 0
        while i < chars.count { out.append(try nib(chars[i]) << 4 | nib(chars[i + 1])); i += 2 }
        return out
    }

    /// Consecutive records are merged into one segment.
    static func append(_ segs: inout [Segment], _ addr: UInt64, _ data: [UInt8]) {
        guard !data.isEmpty else { return }
        if var last = segs.last, last.end == addr {
            last.data.append(contentsOf: data)
            segs[segs.count - 1] = last
        } else {
            segs.append(Segment(address: addr, data: Data(data)))
        }
    }

    public static func parseIntelHex(_ text: String) throws -> Image {
        var segs: [Segment] = []
        var upper: UInt64 = 0          // from type 02 (segment << 4) or 04 (linear << 16)
        var start: UInt64?
        var startSegment: UInt32?
        var sawEOF = false
        for (n, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let lineNo = n + 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if sawEOF { throw HexRecordError(line: lineNo, message: L("data after the end record")) }
            guard line.hasPrefix(":") else { throw HexRecordError(line: lineNo, message: L("line does not start with ':'")) }
            let b = try bytes(line.dropFirst()[...], line: lineNo)
            guard b.count >= 5, b.count == Int(b[0]) + 5 else { throw HexRecordError(line: lineNo, message: L("length field does not match")) }
            guard b.reduce(0, &+) == 0 else { throw HexRecordError(line: lineNo, message: L("checksum mismatch")) }
            let addr = UInt64(b[1]) << 8 | UInt64(b[2])
            let data = Array(b[4 ..< 4 + Int(b[0])])
            switch b[3] {
            case 0x00: append(&segs, upper + addr, data)
            case 0x01: sawEOF = true
            case 0x02:
                guard data.count == 2 else { throw HexRecordError(line: lineNo, message: L("type 02 needs 2 bytes")) }
                upper = (UInt64(data[0]) << 8 | UInt64(data[1])) << 4
            case 0x04:
                guard data.count == 2 else { throw HexRecordError(line: lineNo, message: L("type 04 needs 2 bytes")) }
                upper = (UInt64(data[0]) << 8 | UInt64(data[1])) << 16
            case 0x03:
                guard data.count == 4 else { throw HexRecordError(line: lineNo, message: L("type 03 needs 4 bytes")) }
                start = (UInt64(data[0]) << 8 | UInt64(data[1])) << 4 + (UInt64(data[2]) << 8 | UInt64(data[3]))
                startSegment = data.reduce(0) { $0 << 8 | UInt32($1) }
            case 0x05:
                guard data.count == 4 else { throw HexRecordError(line: lineNo, message: L("type 05 needs 4 bytes")) }
                start = data.reduce(0) { $0 << 8 | UInt64($1) }
                startSegment = nil
            default:
                throw HexRecordError(line: lineNo, message: L("unknown record type %@", "\(b[3])"))
            }
        }
        var image = Image(segments: segs, startAddress: start, startSegment: startSegment, header: nil)
        // Without it the file may have been cut off; still importable, but say so.
        if !sawEOF { image.warnings.append(L("no end record (type 01): the file may be truncated")) }
        return image
    }

    public static func parseSRecord(_ text: String) throws -> Image {
        var segs: [Segment] = []
        var start: UInt64?
        var header: String?
        var dataRecords = 0
        for (n, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let lineNo = n + 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard line.hasPrefix("S"), let type = line.dropFirst().first?.wholeNumberValue else {
                throw HexRecordError(line: lineNo, message: L("line does not start with S0–S9"))
            }
            let b = try bytes(line.dropFirst(2)[...], line: lineNo)
            guard b.count >= 3, b.count == Int(b[0]) + 1 else { throw HexRecordError(line: lineNo, message: L("length field does not match")) }
            guard b.dropLast().reduce(0, &+) ^ 0xFF == b.last! else { throw HexRecordError(line: lineNo, message: L("checksum mismatch")) }
            let addrLen: Int
            switch type {
            case 0, 1, 5, 9: addrLen = 2
            case 2, 6, 8: addrLen = 3
            case 3, 7: addrLen = 4
            default: throw HexRecordError(line: lineNo, message: L("unknown record type S%@", "\(type)"))
            }
            guard b.count >= 2 + addrLen else { throw HexRecordError(line: lineNo, message: L("record too short")) }
            let addr = b[1 ..< 1 + addrLen].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let data = Array(b[(1 + addrLen) ..< (b.count - 1)])
            switch type {
            case 0: header = String(decoding: data, as: UTF8.self)
            case 1, 2, 3: append(&segs, addr, data); dataRecords += 1
            case 5, 6:
                guard addr == UInt64(dataRecords) else {
                    throw HexRecordError(line: lineNo, message: L("record count %@, counted %@", "\(addr)", "\(dataRecords)"))
                }
            default: start = addr
            }
        }
        return Image(segments: segs, startAddress: start, header: header)
    }

    // MARK: Writing

    /// Splits a flat buffer back into segments, leaving out former gaps that
    /// still hold only the fill byte (so saving does not invent data).
    public static func segments(_ data: Data, base: UInt64, gaps: [Range<UInt64>], fill: UInt8 = 0xFF) -> [Segment] {
        var holes: [Range<Int>] = []
        for g in gaps {
            let lo = Int(g.lowerBound - base), hi = min(data.count, Int(g.upperBound - base))
            guard lo < hi else { continue }
            if data[data.startIndex + lo ..< data.startIndex + hi].allSatisfy({ $0 == fill }) { holes.append(lo ..< hi) }
        }
        var out: [Segment] = []
        var pos = 0
        for h in holes.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if h.lowerBound > pos { out.append(Segment(address: base + UInt64(pos), data: data[data.startIndex + pos ..< data.startIndex + h.lowerBound])) }
            pos = h.upperBound
        }
        if pos < data.count { out.append(Segment(address: base + UInt64(pos), data: data[(data.startIndex + pos)...])) }
        return out
    }

    /// Both formats address at most 32 bits. Checked up front, with
    /// overflow-checked ends, instead of silently cutting addresses off.
    static func checkAddresses(_ segments: [Segment], start: UInt64?, _ format: Format) throws {
        for s in segments where !s.data.isEmpty {
            let (end, overflow) = s.address.addingReportingOverflow(UInt64(s.data.count))
            guard !overflow, end <= 1 << 32 else {
                throw HexRecordError(line: 0, message: L("Data at 0x%llX reaches past 0xFFFFFFFF, the limit of %@", s.address, format.rawValue))
            }
        }
        if let start, start > 0xFFFF_FFFF {
            throw HexRecordError(line: 0, message: L("Start address 0x%llX does not fit in 32 bits", start))
        }
    }

    /// `startSegment` (CS << 16 | IP) writes a type 03 start record instead
    /// of the type 05 linear `start`.
    public static func intelHex(_ data: Data, base: UInt64 = 0, start: UInt64? = nil, startSegment: UInt32? = nil,
                                recordSize: Int = 16) throws -> String {
        try intelHex([Segment(address: base, data: data)], start: start, startSegment: startSegment, recordSize: recordSize)
    }

    public static func intelHex(_ segments: [Segment], start: UInt64? = nil, startSegment: UInt32? = nil,
                                recordSize: Int = 16) throws -> String {
        try checkAddresses(segments, start: start, .intelHex)
        let recordSize = min(max(recordSize, 1), 0xFF)    // length is one byte
        var lines: [String] = []
        func record(_ type: UInt8, _ addr: UInt16, _ payload: [UInt8]) {
            var b: [UInt8] = [UInt8(payload.count), UInt8(addr >> 8), UInt8(addr & 0xFF), type] + payload
            b.append(0 &- b.reduce(0, &+))
            lines.append(":" + b.map { String(format: "%02X", $0) }.joined())
        }
        var upper: UInt64 = .max
        for seg in segments {
            let data = seg.data
            var i = 0
            while i < data.count {
                let addr = seg.address + UInt64(i)
                if addr >> 16 != upper {
                    upper = addr >> 16
                    record(0x04, 0, [UInt8(upper >> 8 & 0xFF), UInt8(upper & 0xFF)])
                }
                // Records must not cross a 64 KiB boundary.
                let room = Int(0x10000 - (addr & 0xFFFF))
                let n = min(recordSize, data.count - i, room)
                record(0x00, UInt16(addr & 0xFFFF), Array(data[data.startIndex + i ..< data.startIndex + i + n]))
                i += n
            }
        }
        if let startSegment { record(0x03, 0, [24, 16, 8, 0].map { UInt8(startSegment >> UInt32($0) & 0xFF) }) }
        else if let start { record(0x05, 0, [24, 16, 8, 0].map { UInt8(start >> UInt64($0) & 0xFF) }) }
        record(0x01, 0, [])
        return lines.joined(separator: "\n") + "\n"
    }

    public static func srec(_ data: Data, base: UInt64 = 0, start: UInt64? = nil, header: String = "hexwerk",
                            recordSize: Int = 16) throws -> String {
        try srec([Segment(address: base, data: data)], start: start, header: header, recordSize: recordSize)
    }

    public static func srec(_ segments: [Segment], start: UInt64? = nil, header: String = "hexwerk",
                            recordSize: Int = 16) throws -> String {
        try checkAddresses(segments, start: start, .srec)
        let top = segments.map(\.end).max() ?? 0
        let addrLen = max(top, start ?? 0) > 0xFF_FFFF ? 4 : max(top, start ?? 0) > 0xFFFF ? 3 : 2
        // The length byte counts address, data and checksum.
        let recordSize = min(max(recordSize, 1), 0xFF - addrLen - 1)
        var lines: [String] = []
        func record(_ type: Int, _ addr: UInt64, _ alen: Int, _ payload: [UInt8]) {
            var b: [UInt8] = [UInt8(alen + payload.count + 1)]
            for k in stride(from: alen - 1, through: 0, by: -1) { b.append(UInt8(addr >> UInt64(8 * k) & 0xFF)) }
            b += payload
            b.append(b.reduce(0, &+) ^ 0xFF)
            lines.append("S\(type)" + b.map { String(format: "%02X", $0) }.joined())
        }
        record(0, 0, 2, Array(header.utf8.prefix(60)))
        var count = 0
        for seg in segments {
            let data = seg.data
            var i = 0
            while i < data.count {
                let n = min(recordSize, data.count - i)
                record(addrLen - 1, seg.address + UInt64(i), addrLen, Array(data[data.startIndex + i ..< data.startIndex + i + n]))
                i += n
                count += 1
            }
        }
        // The count record is optional; S6 holds at most 24 bits.
        if count <= 0xFFFF { record(5, UInt64(count), 2, []) } else if count <= 0xFF_FFFF { record(6, UInt64(count), 3, []) }
        record(11 - addrLen, start ?? 0, addrLen, [])        // S9 / S8 / S7
        return lines.joined(separator: "\n") + "\n"
    }
}
