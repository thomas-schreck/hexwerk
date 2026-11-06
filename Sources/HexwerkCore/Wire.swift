import Foundation

/// Compact binary encoding for results that cross the process boundary to
/// the sandboxed helper (#102): parse trees with a million nodes, YARA scans
/// with hundreds of thousands of hits. Codable through a property list or
/// JSON costs seconds for those; this costs milliseconds.
///
/// The app decodes what the helper sends, and a helper that parsed a hostile
/// file may be compromised: `WireReader` therefore never traps and never
/// allocates more than the input can describe.
public struct WireWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func bool(_ v: Bool) { u8(v ? 1 : 0) }

    /// LEB128: most numbers in a parse tree are small.
    public mutating func uint(_ v: UInt64) {
        var v = v
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    public mutating func int(_ v: Int64) { uint(UInt64(bitPattern: (v << 1) ^ (v >> 63))) }   // zigzag
    public mutating func int(_ v: Int) { int(Int64(v)) }
    public mutating func double(_ v: Double) { fixed64(v.bitPattern) }

    public mutating func fixed64(_ v: UInt64) {
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }

    public mutating func bytes(_ v: Data) {
        uint(UInt64(v.count))
        data.append(v)
    }

    public mutating func string(_ v: String) { bytes(Data(v.utf8)) }

    /// Bytes without a length (the reader must know it).
    public mutating func raw(_ v: UnsafeRawBufferPointer) { data.append(contentsOf: v) }

    public mutating func optional<T>(_ v: T?, _ write: (inout WireWriter, T) -> Void) {
        bool(v != nil)
        if let v { write(&self, v) }
    }

    public mutating func range(_ r: Range<UInt64>) {
        uint(r.lowerBound)
        uint(r.upperBound - r.lowerBound)
    }

    public mutating func array<T>(_ items: [T], _ write: (inout WireWriter, T) -> Void) {
        uint(UInt64(items.count))
        for i in items { write(&self, i) }
    }
}

public struct WireError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { L("Invalid reply from the helper: %@", message) }
}

public struct WireReader {
    private let data: Data
    private var pos: Int

    public init(_ data: Data) {
        // Re-base so indices start at 0 whatever slice was passed.
        self.data = Data(data)
        pos = 0
    }

    public var isAtEnd: Bool { pos == data.count }
    public var remaining: Int { data.count - pos }

    public mutating func u8() throws -> UInt8 {
        guard pos < data.count else { throw WireError("truncated") }
        defer { pos += 1 }
        return data[pos]
    }

    public mutating func bool() throws -> Bool {
        switch try u8() {
        case 0: return false
        case 1: return true
        default: throw WireError("bad bool")
        }
    }

    public mutating func uint() throws -> UInt64 {
        var v: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let b = try u8()
            guard shift < 64, shift < 63 || b <= 1 else { throw WireError("varint overflow") }
            v |= UInt64(b & 0x7F) << shift
            if b < 0x80 { return v }
            shift += 7
        }
    }

    public mutating func int64() throws -> Int64 {
        let u = try uint()
        return Int64(bitPattern: (u >> 1) ^ (0 &- (u & 1)))
    }

    public mutating func int() throws -> Int {
        let v = try int64()
        guard let i = Int(exactly: v) else { throw WireError("int out of range") }
        return i
    }

    public mutating func fixed64() throws -> UInt64 {
        guard remaining >= 8 else { throw WireError("truncated") }
        var v: UInt64 = 0
        for i in 0 ..< 8 { v |= UInt64(data[pos + i]) << (8 * UInt64(i)) }
        pos += 8
        return v
    }

    public mutating func double() throws -> Double { Double(bitPattern: try fixed64()) }

    /// A count of items that each take at least `minSize` bytes: rejecting
    /// counts the input cannot hold keeps `reserveCapacity` honest.
    public mutating func count(minSize: Int = 1) throws -> Int {
        let n = try uint()
        guard n <= UInt64(remaining / max(1, minSize)) else { throw WireError("count \(n) exceeds data") }
        return Int(n)
    }

    public mutating func bytes() throws -> Data {
        let n = try count()
        defer { pos += n }
        return data.subdata(in: pos ..< pos + n)
    }

    public mutating func raw(_ n: Int) throws -> Data {
        guard n >= 0, n <= remaining else { throw WireError("truncated") }
        defer { pos += n }
        return data.subdata(in: pos ..< pos + n)
    }

    public mutating func string() throws -> String {
        String(decoding: try bytes(), as: UTF8.self)
    }

    public mutating func optional<T>(_ read: (inout WireReader) throws -> T) throws -> T? {
        try bool() ? try read(&self) : nil
    }

    public mutating func range() throws -> Range<UInt64> {
        let lower = try uint(), length = try uint()
        let (upper, overflow) = lower.addingReportingOverflow(length)
        guard !overflow else { throw WireError("range overflow") }
        return lower ..< upper
    }

    public mutating func array<T>(minSize: Int = 1, _ read: (inout WireReader) throws -> T) throws -> [T] {
        let n = try count(minSize: minSize)
        var out: [T] = []
        out.reserveCapacity(n)
        for _ in 0 ..< n { out.append(try read(&self)) }
        return out
    }

    public func expectEnd() throws {
        guard isAtEnd else { throw WireError("\(remaining) trailing bytes") }
    }
}
