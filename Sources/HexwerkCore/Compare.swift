import CryptoKit
import Foundation
import zlib

public enum Compare {
    /// Byte-by-byte comparison at equal offsets (no realignment after
    /// inserted bytes). If one side is longer, the extra tail is one range.
    /// Ranges are offsets valid in both files up to the shorter length.
    /// Stops at exactly `maxHits` ranges (`count >= maxHits`: truncated); the
    /// open difference and the tail are then left out, not cut short.
    public static func differences(_ a: Snapshot, _ b: Snapshot, maxHits: Int = Search.maxHits,
                                   progress: (Double) -> Bool = { _ in true }) -> [Range<UInt64>] {
        var out: [Range<UInt64>] = []
        let common = min(a.count, b.count)
        let chunk: UInt64 = 8 << 20
        var start: UInt64? = nil
        var pos: UInt64 = 0
        var full = false
        while pos < common, !full {
            let end = min(common, pos + chunk)
            let da = a.read(pos..<end), db = b.read(pos..<end)
            da.withUnsafeBytes { pa in
                db.withUnsafeBytes { pb in
                    let x = pa.bindMemory(to: UInt8.self), y = pb.bindMemory(to: UInt8.self)
                    var i = 0
                    while i < x.count {
                        // Fast path: equal 8-byte words while not inside a difference.
                        if start == nil, i + 8 <= x.count,
                           memcmp(x.baseAddress! + i, y.baseAddress! + i, 8) == 0 {
                            i += 8
                            continue
                        }
                        let differs = x[i] != y[i]
                        let at = pos + UInt64(i)
                        if differs, start == nil { start = at }
                        if !differs, let s = start {
                            out.append(s..<at); start = nil
                            if out.count >= maxHits { full = true; break }
                        }
                        i += 1
                    }
                }
            }
            pos = end
            if full || !progress(Double(pos) / Double(max(common, 1))) { break }
        }
        if full { return out }
        if let s = start { out.append(s..<common) }
        if a.count != b.count, out.count < maxHits { out.append(common ..< max(a.count, b.count)) }
        return out
    }
}

public enum Checksum: String, CaseIterable, Sendable {
    // Simple
    case sum8 = "Sum 8", sum16 = "Sum 16", sum32 = "Sum 32", sum64 = "Sum 64", xor8 = "XOR 8"
    case adler32 = "Adler-32", fletcher16 = "Fletcher-16", fletcher32 = "Fletcher-32"
    // CRC
    case crc8 = "CRC-8", crc8Maxim = "CRC-8/MAXIM"
    case crc16Arc = "CRC-16/ARC", crc16Modbus = "CRC-16/MODBUS", crc16CcittFalse = "CRC-16/CCITT-FALSE"
    case crc16Xmodem = "CRC-16/XMODEM", crc16Kermit = "CRC-16/KERMIT", crc16X25 = "CRC-16/X-25"
    case crc32 = "CRC32", crc32c = "CRC-32C", crc32Bzip2 = "CRC-32/BZIP2", crc32Mpeg2 = "CRC-32/MPEG-2"
    case crc64Ecma = "CRC-64/ECMA-182", crc64Xz = "CRC-64/XZ"
    // Non-cryptographic
    case fnv1a32 = "FNV-1a 32", fnv1a64 = "FNV-1a 64", murmur3 = "Murmur3 32", xxh32 = "xxHash32", xxh64 = "xxHash64"
    // Cryptographic
    case md2 = "MD2", md4 = "MD4", md5 = "MD5", sha1 = "SHA-1", sha224 = "SHA-224", sha256 = "SHA-256", sha384 = "SHA-384"
    case sha512 = "SHA-512", sha512_224 = "SHA-512/224", sha512_256 = "SHA-512/256"
    case sha3_224 = "SHA3-224", sha3_256 = "SHA3-256", sha3_384 = "SHA3-384", sha3_512 = "SHA3-512"
    case keccak256 = "Keccak-256", blake2s = "BLAKE2s-256", blake2b = "BLAKE2b-512", blake3 = "BLAKE3"
    case ripemd160 = "RIPEMD-160", sm3 = "SM3"

    public enum Group: String, CaseIterable, Sendable {
        case simple = "Sums", crc = "CRC", fast = "Non-cryptographic", crypto = "Cryptographic"

        /// Localized label; `rawValue` stays stable.
        public var title: String {
            switch self {
            case .simple: L("Sums")
            case .crc: "CRC"
            case .fast: L("Non-cryptographic")
            case .crypto: L("Cryptographic")
            }
        }
    }

    /// Localized label; `rawValue` is stored in settings and stays stable.
    public var title: String {
        switch self {
        case .sum8: L("Sum 8")
        case .sum16: L("Sum 16")
        case .sum32: L("Sum 32")
        case .sum64: L("Sum 64")
        default: rawValue
        }
    }

    public var group: Group {
        switch self {
        case .sum8, .sum16, .sum32, .sum64, .xor8, .adler32, .fletcher16, .fletcher32: .simple
        case .crc8, .crc8Maxim, .crc16Arc, .crc16Modbus, .crc16CcittFalse, .crc16Xmodem, .crc16Kermit, .crc16X25,
             .crc32, .crc32c, .crc32Bzip2, .crc32Mpeg2, .crc64Ecma, .crc64Xz: .crc
        case .fnv1a32, .fnv1a64, .murmur3, .xxh32, .xxh64: .fast
        default: .crypto
        }
    }

    /// Short name for the command line (`hexwerk hash --algo sha3-256`).
    public var cliName: String { rawValue.lowercased().replacingOccurrences(of: " ", with: "") }

    /// The defaults shown before the user picks more.
    public static let common: [Checksum] = [.crc32, .md5, .sha1, .sha256]

    func makeHasher() -> StreamingHash {
        func crc(_ w: Int, _ p: UInt64, _ i: UInt64, _ r: Bool, _ x: UInt64) -> StreamingHash {
            CRC(CRCSpec(width: w, poly: p, initial: i, reflected: r, xorOut: x))
        }
        switch self {
        case .sum8: return ByteSum(bits: 8)
        case .sum16: return ByteSum(bits: 16)
        case .sum32: return ByteSum(bits: 32)
        case .sum64: return ByteSum(bits: 64)
        case .xor8: return Xor8()
        case .adler32: return Adler32()
        case .fletcher16: return Fletcher16()
        case .fletcher32: return Fletcher32()
        case .crc8: return crc(8, 0x07, 0, false, 0)
        case .crc8Maxim: return crc(8, 0x31, 0, true, 0)
        case .crc16Arc: return crc(16, 0x8005, 0, true, 0)
        case .crc16Modbus: return crc(16, 0x8005, 0xFFFF, true, 0)
        case .crc16CcittFalse: return crc(16, 0x1021, 0xFFFF, false, 0)
        case .crc16Xmodem: return crc(16, 0x1021, 0, false, 0)
        case .crc16Kermit: return crc(16, 0x1021, 0, true, 0)
        case .crc16X25: return crc(16, 0x1021, 0xFFFF, true, 0xFFFF)
        case .crc32: return ZlibCRC32()
        case .crc32c: return crc(32, 0x1EDC6F41, 0xFFFFFFFF, true, 0xFFFFFFFF)
        case .crc32Bzip2: return crc(32, 0x04C11DB7, 0xFFFFFFFF, false, 0xFFFFFFFF)
        case .crc32Mpeg2: return crc(32, 0x04C11DB7, 0xFFFFFFFF, false, 0)
        case .crc64Ecma: return crc(64, 0x42F0E1EBA9EA3693, 0, false, 0)
        case .crc64Xz: return crc(64, 0x42F0E1EBA9EA3693, .max, true, .max)
        case .fnv1a32: return FNV1a32()
        case .fnv1a64: return FNV1a64()
        case .murmur3: return Murmur3()
        case .xxh32: return XXH32()
        case .xxh64: return XXH64()
        case .md2: return MD2()
        case .md4: return MD4()
        case .md5: return KitHash<Insecure.MD5>()
        case .sha1: return KitHash<Insecure.SHA1>()
        case .sha224: return SHA224()
        case .sha256: return KitHash<SHA256>()
        case .sha384: return KitHash<SHA384>()
        case .sha512: return KitHash<SHA512>()
        case .sha512_224: return SHA512T(bits: 224)
        case .sha512_256: return SHA512T(bits: 256)
        case .sha3_224: return Keccak(bits: 224, sha3: true)
        case .sha3_256: return KitHash<SHA3_256>()
        case .sha3_384: return KitHash<SHA3_384>()
        case .sha3_512: return KitHash<SHA3_512>()
        case .keccak256: return Keccak(bits: 256, sha3: false)
        case .blake2s: return BLAKE2s()
        case .blake2b: return BLAKE2b()
        case .blake3: return BLAKE3()
        case .ripemd160: return RIPEMD160()
        case .sm3: return SM3()
        }
    }

    /// Streams `range` of the snapshot through the hash in chunks.
    public func compute(_ snapshot: Snapshot, range: Range<UInt64>? = nil,
                        progress: (Double) -> Bool = { _ in true }) -> String? {
        Self.compute([self], snapshot, range: range, progress: progress)?[self]
    }

    /// Several algorithms in one pass over the data. Nil if cancelled.
    public static func compute(_ algos: [Checksum], _ snapshot: Snapshot, range: Range<UInt64>? = nil,
                               progress: (Double) -> Bool = { _ in true }) -> [Checksum: String]? {
        let r = (range ?? 0..<snapshot.count).clamped(to: 0..<snapshot.count)
        var hashers = algos.map { $0.makeHasher() }
        let chunk: UInt64 = 4 << 20
        var pos = r.lowerBound
        while pos < r.upperBound {
            let end = min(r.upperBound, pos + chunk)
            snapshot.withContiguousBytes(pos ..< end) { buf in
                // Algorithms are independent: run them on all cores per chunk.
                hashers.withUnsafeMutableBufferPointer { hs in
                    nonisolated(unsafe) let hs = hs
                    DispatchQueue.concurrentPerform(iterations: hs.count) { hs[$0].update(buf) }
                }
            }
            pos = end
            if !progress(Double(pos - r.lowerBound) / Double(max(r.count, 1))) { return nil }
        }
        var out: [Checksum: String] = [:]
        for (a, var h) in zip(algos, hashers) { out[a] = h.finalize() }
        return out
    }

    /// Hash of a small in-memory buffer (tests, calculator).
    public static func compute(_ algo: Checksum, _ data: Data) -> String {
        var h = algo.makeHasher()
        data.withUnsafeBytes { h.update($0) }
        return h.finalize()
    }
}
