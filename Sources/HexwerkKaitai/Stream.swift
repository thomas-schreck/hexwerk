import Foundation
import HexwerkCore
import zlib

/// A Kaitai stream: a window into the file, or bytes produced by `process`.
/// Offsets are relative to the stream; `fileBase` maps them to the file.
final class KStream {
    private enum Source {
        case file(Snapshot)
        case data([UInt8])
    }

    private let source: Source
    /// Start of this stream within the source.
    private let start: UInt64
    let size: UInt64
    /// Absolute file offset of position 0, nil for processed data.
    let fileBase: UInt64?
    let id: Int

    var pos: UInt64 = 0
    private var bits: UInt64 = 0
    private var bitsLeft = 0

    // Small read-ahead cache: most reads are a few bytes.
    private var cacheStart: UInt64 = 0
    private var cache: [UInt8] = []

    init(snapshot: Snapshot, id: Int) {
        source = .file(snapshot)
        start = 0
        size = snapshot.count
        fileBase = 0
        self.id = id
    }

    init(data: [UInt8], id: Int) {
        source = .data(data)
        start = 0
        size = UInt64(data.count)
        fileBase = nil
        self.id = id
    }

    private init(parent: KStream, offset: UInt64, size: UInt64, id: Int) {
        source = parent.source
        start = parent.start + offset
        self.size = size
        fileBase = parent.fileBase.map { $0 + offset }
        self.id = id
    }

    var isEof: Bool { bitsLeft == 0 && pos >= size }

    func seek(_ p: UInt64) throws {
        guard p <= size else { throw KaitaiError("Position \(p) hinter Stream-Ende (\(size))") }
        alignToByte()
        pos = p
    }

    func alignToByte() {
        bits = 0
        bitsLeft = 0
    }

    /// Bytes at [start+from, start+from+n) of the source, without moving.
    private func peek(_ from: UInt64, _ n: Int) -> [UInt8] {
        switch source {
        case .data(let d):
            let a = Int(start + from)
            return Array(d[a..<a + n])
        case .file(let s):
            let abs = start + from
            if abs >= cacheStart, abs + UInt64(n) <= cacheStart + UInt64(cache.count) {
                let o = Int(abs - cacheStart)
                return Array(cache[o..<o + n])
            }
            if n > 4096 { return [UInt8](s.read(abs ..< abs + UInt64(n))) }
            cacheStart = abs
            cache = [UInt8](s.read(abs ..< min(s.count, abs + 65536)))
            return Array(cache[0..<n])
        }
    }

    private func rawRead(_ n: UInt64) throws -> [UInt8] {
        guard n <= size - min(pos, size) else {
            throw KaitaiError("Ende des Streams erreicht: \(n) Byte gewünscht, \(size - min(pos, size)) übrig", offset: fileBase.map { $0 + pos })
        }
        let out = peek(pos, Int(n))
        pos += n
        return out
    }

    func readBytes(_ n: UInt64) throws -> [UInt8] {
        alignToByte()
        return try rawRead(n)
    }

    func readBytesFull() throws -> [UInt8] {
        alignToByte()
        return try rawRead(size - pos)
    }

    /// Bytes up to the terminator (Kaitai semantics for include/consume/eos-error).
    func readBytesTerm(_ term: UInt8, include: Bool, consume: Bool, eosError: Bool) throws -> [UInt8] {
        alignToByte()
        var out: [UInt8] = []
        while true {
            if pos >= size {
                if eosError { throw KaitaiError("Terminator 0x\(String(term, radix: 16)) nicht gefunden", offset: fileBase.map { $0 + pos }) }
                return out
            }
            let b = peek(pos, 1)[0]
            if b == term {
                if include { out.append(b) }
                if consume { pos += 1 }
                return out
            }
            out.append(b)
            pos += 1
        }
    }

    func readUInt(_ n: Int, _ endian: Endian) throws -> UInt64 {
        let b = try readBytes(UInt64(n))
        let ordered = endian == .little ? b : b.reversed()
        return ordered.enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * $1.offset) }
    }

    // Bit reading as in the official Kaitai runtimes.
    func readBitsBE(_ n: Int) throws -> UInt64 {
        var res: UInt64 = 0
        let bitsNeeded = n - bitsLeft
        bitsLeft = ((-bitsNeeded % 8) + 8) % 8
        if bitsNeeded > 0 {
            let bytesNeeded = (bitsNeeded - 1) / 8 + 1
            let buf = try rawRead(UInt64(bytesNeeded))
            for b in buf { res = res << 8 | UInt64(b) }
            let newBits = res
            res = (bitsLeft >= 64 ? 0 : res >> UInt64(bitsLeft)) | (bitsNeeded >= 64 ? 0 : bits << UInt64(bitsNeeded))
            bits = newBits
        } else {
            res = bits >> UInt64(-bitsNeeded)
        }
        bits &= bitsLeft >= 64 ? .max : (1 << UInt64(bitsLeft)) - 1
        return res
    }

    func readBitsLE(_ n: Int) throws -> UInt64 {
        var res: UInt64 = 0
        let bitsNeeded = n - bitsLeft
        if bitsNeeded > 0 {
            let bytesNeeded = (bitsNeeded - 1) / 8 + 1
            let buf = try rawRead(UInt64(bytesNeeded))
            for (i, b) in buf.enumerated() { res |= UInt64(b) << UInt64(i * 8) }
            let newBits = bitsNeeded >= 64 ? 0 : res >> UInt64(bitsNeeded)
            res = (bitsLeft >= 64 ? 0 : res << UInt64(bitsLeft)) | bits
            bits = newBits
        } else {
            res = bits
            bits = n >= 64 ? 0 : bits >> UInt64(n)
        }
        bitsLeft = ((-bitsNeeded % 8) + 8) % 8
        return n >= 64 ? res : res & ((1 << UInt64(n)) - 1)
    }

    /// The next `n` bytes as their own stream; this stream moves past them.
    func substream(_ n: UInt64, id: Int) throws -> KStream {
        alignToByte()
        guard n <= size - min(pos, size) else {
            throw KaitaiError("Größe \(n) überschreitet das Stream-Ende (\(size - min(pos, size)) übrig)", offset: fileBase.map { $0 + pos })
        }
        let s = KStream(parent: self, offset: pos, size: n, id: id)
        pos += n
        return s
    }

    /// Everything from the current position as its own stream.
    func substreamToEnd(id: Int) throws -> KStream { try substream(size - pos, id: id) }
}

enum Process {
    static func zlibInflate(_ input: [UInt8]) throws -> [UInt8] {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw KaitaiError("zlib: Initialisierung fehlgeschlagen")
        }
        defer { inflateEnd(&stream) }
        var out: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var input = input
        let status: Int32 = input.withUnsafeMutableBufferPointer { inBuf in
            stream.next_in = inBuf.baseAddress
            stream.avail_in = uInt(inBuf.count)
            var r: Int32 = Z_OK
            repeat {
                r = chunk.withUnsafeMutableBufferPointer { outBuf in
                    stream.next_out = outBuf.baseAddress
                    stream.avail_out = uInt(outBuf.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunk.count - Int(stream.avail_out)
                out += chunk[0..<produced]
                // Decompression bombs: stop at 256 MiB.
                if out.count > 256 << 20 { return Z_MEM_ERROR }
            } while r == Z_OK
            return r
        }
        guard status == Z_STREAM_END else { throw KaitaiError("zlib: Daten fehlerhaft (Status \(status))") }
        return out
    }

    static func xor(_ data: [UInt8], key: [UInt8]) -> [UInt8] {
        guard !key.isEmpty else { return data }
        return data.enumerated().map { $0.element ^ key[$0.offset % key.count] }
    }

    static func rotate(_ data: [UInt8], left amount: Int) -> [UInt8] {
        let n = ((amount % 8) + 8) % 8
        return data.map { n == 0 ? $0 : ($0 << UInt8(n)) | ($0 >> UInt8(8 - n)) }
    }
}
