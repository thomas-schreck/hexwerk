import CommonCrypto
import CryptoKit
import Foundation
import zlib

/// A hash or checksum fed in chunks. All algorithms of one run share a
/// single pass over the data.
protocol StreamingHash {
    mutating func update(_ buf: UnsafeRawBufferPointer)
    mutating func finalize() -> String
}

func hexString<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
}

@inline(__always) func rotl32(_ x: UInt32, _ n: UInt32) -> UInt32 { x << n | x >> (32 - n) }
@inline(__always) func rotr32(_ x: UInt32, _ n: UInt32) -> UInt32 { x >> n | x << (32 - n) }
@inline(__always) func rotl64(_ x: UInt64, _ n: UInt64) -> UInt64 { x << n | x >> (64 - n) }
@inline(__always) func rotr64(_ x: UInt64, _ n: UInt64) -> UInt64 { x >> n | x << (64 - n) }

/// Collects input into fixed-size blocks for block-based algorithms.
struct BlockBuffer {
    let size: Int
    var pending: [UInt8] = []
    var total: UInt64 = 0

    init(size: Int) { self.size = size; pending.reserveCapacity(size) }

    /// Calls `block` for every complete block; keeps the rest.
    mutating func feed(_ buf: UnsafeRawBufferPointer, _ block: (UnsafeRawBufferPointer) -> Void) {
        total += UInt64(buf.count)
        var i = 0
        if !pending.isEmpty {
            let take = min(size - pending.count, buf.count)
            pending += buf[0 ..< take]
            i = take
            if pending.count == size { pending.withUnsafeBytes(block); pending.removeAll(keepingCapacity: true) }
        }
        while i + size <= buf.count {
            block(UnsafeRawBufferPointer(rebasing: buf[i ..< i + size]))
            i += size
        }
        if i < buf.count { pending += buf[i...] }
    }
}

// MARK: - Simple sums

struct ByteSum: StreamingHash {
    let bits: Int
    var sum: UInt64 = 0
    mutating func update(_ buf: UnsafeRawBufferPointer) { for b in buf { sum &+= UInt64(b) } }
    mutating func finalize() -> String {
        let mask: UInt64 = bits == 64 ? .max : (1 << bits) - 1
        return String(format: "%0\(bits / 4)llx", sum & mask)
    }
}

struct Xor8: StreamingHash {
    var x: UInt8 = 0
    mutating func update(_ buf: UnsafeRawBufferPointer) { for b in buf { x ^= b } }
    mutating func finalize() -> String { String(format: "%02x", x) }
}

struct Adler32: StreamingHash {
    var v = zlib.adler32(0, nil, 0)
    mutating func update(_ buf: UnsafeRawBufferPointer) {
        v = zlib.adler32(v, buf.bindMemory(to: Bytef.self).baseAddress, uInt(buf.count))
    }
    mutating func finalize() -> String { String(format: "%08x", v) }
}

struct Fletcher16: StreamingHash {
    var a: UInt32 = 0, b: UInt32 = 0
    mutating func update(_ buf: UnsafeRawBufferPointer) {
        for x in buf { a = (a + UInt32(x)) % 255; b = (b + a) % 255 }
    }
    mutating func finalize() -> String { String(format: "%04x", b << 8 | a) }
}

/// Fletcher-32 over little-endian 16-bit words; an odd last byte is padded with 0.
struct Fletcher32: StreamingHash {
    var a: UInt64 = 0, b: UInt64 = 0
    var odd: UInt8?
    mutating func update(_ buf: UnsafeRawBufferPointer) {
        for x in buf {
            if let lo = odd {
                a = (a + (UInt64(lo) | UInt64(x) << 8)) % 65535
                b = (b + a) % 65535
                odd = nil
            } else {
                odd = x
            }
        }
    }
    mutating func finalize() -> String {
        if let lo = odd { a = (a + UInt64(lo)) % 65535; b = (b + a) % 65535; odd = nil }
        return String(format: "%08llx", b << 16 | a)
    }
}

// MARK: - CRC (Rocksoft model, table driven)

struct CRCSpec: Sendable {
    let width: Int
    let poly: UInt64
    let initial: UInt64
    let reflected: Bool
    let xorOut: UInt64
}

struct CRC: StreamingHash {
    let spec: CRCSpec
    var crc: UInt64
    let table: [UInt64]
    let mask: UInt64

    init(_ s: CRCSpec) {
        spec = s
        mask = s.width == 64 ? .max : (1 << UInt64(s.width)) - 1
        var t = [UInt64](repeating: 0, count: 256)
        if s.reflected {
            var rpoly: UInt64 = 0
            for i in 0 ..< s.width where s.poly >> UInt64(i) & 1 == 1 { rpoly |= 1 << UInt64(s.width - 1 - i) }
            for n in 0 ..< 256 {
                var c = UInt64(n)
                for _ in 0 ..< 8 { c = c & 1 == 1 ? c >> 1 ^ rpoly : c >> 1 }
                t[n] = c
            }
        } else {
            let top: UInt64 = 1 << UInt64(s.width - 1)
            for n in 0 ..< 256 {
                var c = s.width >= 8 ? UInt64(n) << UInt64(s.width - 8) : UInt64(n)
                for _ in 0 ..< 8 { c = c & top != 0 ? (c << 1) ^ s.poly : c << 1 }
                t[n] = c & (s.width == 64 ? .max : (1 << UInt64(s.width)) - 1)
            }
        }
        table = t
        crc = s.initial
    }

    mutating func update(_ buf: UnsafeRawBufferPointer) {
        var c = crc
        table.withUnsafeBufferPointer { t in
            if spec.reflected {
                for b in buf { c = c >> 8 ^ t[Int((c ^ UInt64(b)) & 0xFF)] }
            } else {
                let shift = UInt64(spec.width - 8)
                for b in buf { c = (c << 8 ^ t[Int((c >> shift ^ UInt64(b)) & 0xFF)]) & mask }
            }
        }
        crc = c
    }

    mutating func finalize() -> String {
        String(format: "%0\(spec.width / 4)llx", (crc ^ spec.xorOut) & mask)
    }
}

// MARK: - Non-cryptographic

/// CRC-32 (ISO-HDLC) via zlib, which is far faster than the generic table.
struct ZlibCRC32: StreamingHash {
    var v = zlib.crc32(0, nil, 0)
    mutating func update(_ buf: UnsafeRawBufferPointer) {
        var p = buf.bindMemory(to: Bytef.self).baseAddress
        var n = buf.count
        while n > 0 {
            let k = min(n, 1 << 30)
            v = zlib.crc32(v, p, uInt(k))
            p = p.map { $0 + k }
            n -= k
        }
    }
    mutating func finalize() -> String { String(format: "%08x", v) }
}

struct FNV1a32: StreamingHash {
    var h: UInt32 = 0x811C9DC5
    mutating func update(_ buf: UnsafeRawBufferPointer) { for b in buf { h = (h ^ UInt32(b)) &* 0x0100_0193 } }
    mutating func finalize() -> String { String(format: "%08x", h) }
}

struct FNV1a64: StreamingHash {
    var h: UInt64 = 0xCBF2_9CE4_8422_2325
    mutating func update(_ buf: UnsafeRawBufferPointer) { for b in buf { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 } }
    mutating func finalize() -> String { String(format: "%016llx", h) }
}

/// MurmurHash3 x86_32, seed 0.
struct Murmur3: StreamingHash {
    var h: UInt32 = 0
    var blocks = BlockBuffer(size: 4)
    static let c1: UInt32 = 0xCC9E_2D51, c2: UInt32 = 0x1B87_3593

    mutating func update(_ buf: UnsafeRawBufferPointer) {
        var h = self.h
        blocks.feed(buf) { b in
            var k = b.loadUnaligned(as: UInt32.self).littleEndian
            k = rotl32(k &* Self.c1, 15) &* Self.c2
            h ^= k
            h = rotl32(h, 13) &* 5 &+ 0xE654_6B64
        }
        self.h = h
    }

    mutating func finalize() -> String {
        var k: UInt32 = 0
        for (i, b) in blocks.pending.enumerated() { k |= UInt32(b) << (8 * UInt32(i)) }
        if !blocks.pending.isEmpty { h ^= rotl32(k &* Self.c1, 15) &* Self.c2 }
        h ^= UInt32(truncatingIfNeeded: blocks.total)
        h ^= h >> 16; h &*= 0x85EB_CA6B; h ^= h >> 13; h &*= 0xC2B2_AE35; h ^= h >> 16
        return String(format: "%08x", h)
    }
}

/// xxHash32, seed 0.
struct XXH32: StreamingHash {
    static let p1: UInt32 = 0x9E37_79B1, p2: UInt32 = 0x85EB_CA77, p3: UInt32 = 0xC2B2_AE3D
    static let p4: UInt32 = 0x27D4_EB2F, p5: UInt32 = 0x1656_67B1
    var v = [p1 &+ p2, p2, 0, 0 &- p1]
    var blocks = BlockBuffer(size: 16)

    static func round(_ acc: UInt32, _ input: UInt32) -> UInt32 { rotl32(acc &+ input &* p2, 13) &* p1 }

    mutating func update(_ buf: UnsafeRawBufferPointer) {
        var v = self.v
        blocks.feed(buf) { b in
            for i in 0 ..< 4 { v[i] = Self.round(v[i], b.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self).littleEndian) }
        }
        self.v = v
    }

    mutating func finalize() -> String {
        var h: UInt32 = blocks.total >= 16
            ? rotl32(v[0], 1) &+ rotl32(v[1], 7) &+ rotl32(v[2], 12) &+ rotl32(v[3], 18)
            : Self.p5
        h &+= UInt32(truncatingIfNeeded: blocks.total)
        let rest = blocks.pending
        var i = 0
        while i + 4 <= rest.count {
            let w = UInt32(rest[i]) | UInt32(rest[i + 1]) << 8 | UInt32(rest[i + 2]) << 16 | UInt32(rest[i + 3]) << 24
            h = rotl32(h &+ w &* Self.p3, 17) &* Self.p4
            i += 4
        }
        while i < rest.count { h = rotl32(h &+ UInt32(rest[i]) &* Self.p5, 11) &* Self.p1; i += 1 }
        h ^= h >> 15; h &*= Self.p2; h ^= h >> 13; h &*= Self.p3; h ^= h >> 16
        return String(format: "%08x", h)
    }
}

/// xxHash64, seed 0.
struct XXH64: StreamingHash {
    static let p1: UInt64 = 0x9E37_79B1_85EB_CA87, p2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
    static let p3: UInt64 = 0x1656_67B1_9E37_79F9, p4: UInt64 = 0x85EB_CA77_C2B2_AE63, p5: UInt64 = 0x27D4_EB2F_1656_67C5
    var v = [p1 &+ p2, p2, 0, 0 &- p1]
    var blocks = BlockBuffer(size: 32)

    static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 { rotl64(acc &+ input &* p2, 31) &* p1 }
    static func merge(_ acc: UInt64, _ val: UInt64) -> UInt64 { (acc ^ round(0, val)) &* p1 &+ p4 }

    mutating func update(_ buf: UnsafeRawBufferPointer) {
        var v = self.v
        blocks.feed(buf) { b in
            for i in 0 ..< 4 { v[i] = Self.round(v[i], b.loadUnaligned(fromByteOffset: 8 * i, as: UInt64.self).littleEndian) }
        }
        self.v = v
    }

    mutating func finalize() -> String {
        var h: UInt64
        if blocks.total >= 32 {
            h = rotl64(v[0], 1) &+ rotl64(v[1], 7) &+ rotl64(v[2], 12) &+ rotl64(v[3], 18)
            for x in v { h = Self.merge(h, x) }
        } else {
            h = Self.p5
        }
        h &+= blocks.total
        let rest = blocks.pending
        var i = 0
        func le(_ n: Int) -> UInt64 { (0 ..< n).reduce(0) { $0 | UInt64(rest[i + $1]) << (8 * UInt64($1)) } }
        while i + 8 <= rest.count { h = rotl64(h ^ Self.round(0, le(8)), 27) &* Self.p1 &+ Self.p4; i += 8 }
        if i + 4 <= rest.count { h = rotl64(h ^ le(4) &* Self.p1, 23) &* Self.p2 &+ Self.p3; i += 4 }
        while i < rest.count { h = rotl64(h ^ UInt64(rest[i]) &* Self.p5, 11) &* Self.p1; i += 1 }
        h ^= h >> 33; h &*= Self.p2; h ^= h >> 29; h &*= Self.p3; h ^= h >> 32
        return String(format: "%016llx", h)
    }
}

// MARK: - System implementations

struct KitHash<H: HashFunction>: StreamingHash {
    var h = H()
    mutating func update(_ buf: UnsafeRawBufferPointer) { h.update(bufferPointer: buf) }
    mutating func finalize() -> String { hexString(h.finalize()) }
}

struct SHA224: StreamingHash {
    var ctx = CC_SHA256_CTX()
    init() { CC_SHA224_Init(&ctx) }
    mutating func update(_ buf: UnsafeRawBufferPointer) {
        var p = buf.baseAddress
        var n = buf.count
        // CC_LONG is 32 bit; feed large buffers in pieces.
        while n > 0 {
            let k = min(n, 1 << 30)
            CC_SHA224_Update(&ctx, p, CC_LONG(k))
            p = p.map { $0 + k }
            n -= k
        }
    }
    mutating func finalize() -> String {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA224_DIGEST_LENGTH))
        CC_SHA224_Final(&out, &ctx)
        return hexString(out)
    }
}

// MARK: - MD4 (RFC 1320)

struct MD4: StreamingHash {
    var s: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476]
    var blocks = BlockBuffer(size: 64)

    static func compress(_ s: inout [UInt32], _ b: UnsafeRawBufferPointer) {
        var x = [UInt32](repeating: 0, count: 16)
        for i in 0 ..< 16 { x[i] = b.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self).littleEndian }
        var a = s[0], bb = s[1], c = s[2], d = s[3]
        func f(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { x & y | ~x & z }
        func g(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { x & y | x & z | y & z }
        func h(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { x ^ y ^ z }
        for i in 0 ..< 16 {
            let r: [UInt32] = [3, 7, 11, 19]
            let t = rotl32(a &+ f(bb, c, d) &+ x[i], r[i % 4])
            (a, bb, c, d) = (d, t, bb, c)
        }
        for i in 0 ..< 16 {
            let k = [0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15][i]
            let r: [UInt32] = [3, 5, 9, 13]
            let t = rotl32(a &+ g(bb, c, d) &+ x[k] &+ 0x5A82_7999, r[i % 4])
            (a, bb, c, d) = (d, t, bb, c)
        }
        for i in 0 ..< 16 {
            let k = [0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15][i]
            let r: [UInt32] = [3, 9, 11, 15]
            let t = rotl32(a &+ h(bb, c, d) &+ x[k] &+ 0x6ED9_EBA1, r[i % 4])
            (a, bb, c, d) = (d, t, bb, c)
        }
        s[0] &+= a; s[1] &+= bb; s[2] &+= c; s[3] &+= d
    }

    mutating func update(_ buf: UnsafeRawBufferPointer) {
        var st = s
        blocks.feed(buf) { Self.compress(&st, $0) }
        s = st
    }

    mutating func finalize() -> String {
        let pad = mdPadding(total: blocks.total, pending: blocks.pending.count, bigEndian: false)
        pad.withUnsafeBytes { update($0) }
        return hexString(s.flatMap { withUnsafeBytes(of: $0.littleEndian, Array.init) })
    }
}

/// MD-style padding: 0x80, zeros, 64-bit bit length.
func mdPadding(total: UInt64, pending: Int, bigEndian: Bool, block: Int = 64, lengthBytes: Int = 8) -> [UInt8] {
    var p: [UInt8] = [0x80]
    let after = (pending + 1) % block
    let zeros = (block - lengthBytes - after + block) % block
    p += [UInt8](repeating: 0, count: zeros)
    let bits = total &* 8
    var len = withUnsafeBytes(of: bigEndian ? bits.bigEndian : bits.littleEndian, Array.init)
    if lengthBytes == 16 { len = bigEndian ? [UInt8](repeating: 0, count: 8) + len : len + [UInt8](repeating: 0, count: 8) }
    return p + len
}

// MARK: - SHA-512/t (FIPS 180-4), own core for the truncated variants

struct SHA512T: StreamingHash {
    static let k: [UInt64] = [
        0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc, 0x3956c25bf348b538,
        0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118, 0xd807aa98a3030242, 0x12835b0145706fbe,
        0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2, 0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235,
        0xc19bf174cf692694, 0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65,
        0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5, 0x983e5152ee66dfab,
        0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4, 0xc6e00bf33da88fc2, 0xd5a79147930aa725,
        0x06ca6351e003826f, 0x142929670a0e6e70, 0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed,
        0x53380d139d95b3df, 0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b,
        0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30, 0xd192e819d6ef5218,
        0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8, 0x19a4c116b8d2d0c8, 0x1e376c085141ab53,
        0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8, 0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373,
        0x682e6ff3d6b2b8a3, 0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
        0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b, 0xca273eceea26619c,
        0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178, 0x06f067aa72176fba, 0x0a637dc5a2c898a6,
        0x113f9804bef90dae, 0x1b710b35131c471b, 0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc,
        0x431d67c49c100d4c, 0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817,
    ]
    static let iv224: [UInt64] = [0x8C3D37C819544DA2, 0x73E1996689DCD4D6, 0x1DFAB7AE32FF9C82, 0x679DD514582F9FCF,
                                  0x0F6D2B697BD44DA8, 0x77E36F7304C48942, 0x3F9D85A86A1D36C8, 0x1112E6AD91D692A1]
    static let iv256: [UInt64] = [0x22312194FC2BF72C, 0x9F555FA3C84C64C2, 0x2393B86B6F53B151, 0x963877195940EABD,
                                  0x96283EE2A88EFFE3, 0xBE5E1E2553863992, 0x2B0199FC2C85B8AA, 0x0EB72DDC81C52CA2]
    var h: [UInt64]
    let bits: Int
    var blocks = BlockBuffer(size: 128)

    init(bits: Int) {
        self.bits = bits
        h = bits == 224 ? Self.iv224 : Self.iv256
    }

    static func compress(_ h: inout [UInt64], _ b: UnsafeRawBufferPointer) {
        var w = [UInt64](repeating: 0, count: 80)
        for i in 0 ..< 16 { w[i] = b.loadUnaligned(fromByteOffset: 8 * i, as: UInt64.self).bigEndian }
        for i in 16 ..< 80 {
            let s0 = rotr64(w[i - 15], 1) ^ rotr64(w[i - 15], 8) ^ w[i - 15] >> 7
            let s1 = rotr64(w[i - 2], 19) ^ rotr64(w[i - 2], 61) ^ w[i - 2] >> 6
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = h[0], bb = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
        for i in 0 ..< 80 {
            let s1 = rotr64(e, 14) ^ rotr64(e, 18) ^ rotr64(e, 41)
            let ch = e & f ^ ~e & g
            let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
            let s0 = rotr64(a, 28) ^ rotr64(a, 34) ^ rotr64(a, 39)
            let maj = a & bb ^ a & c ^ bb & c
            let t2 = s0 &+ maj
            hh = g; g = f; f = e; e = d &+ t1; d = c; c = bb; bb = a; a = t1 &+ t2
        }
        h[0] &+= a; h[1] &+= bb; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
    }

    mutating func update(_ buf: UnsafeRawBufferPointer) {
        var st = h
        blocks.feed(buf) { Self.compress(&st, $0) }
        h = st
    }

    mutating func finalize() -> String {
        let pad = mdPadding(total: blocks.total, pending: blocks.pending.count, bigEndian: true, block: 128, lengthBytes: 16)
        pad.withUnsafeBytes { update($0) }
        let all = h.flatMap { withUnsafeBytes(of: $0.bigEndian, Array.init) }
        return hexString(all.prefix(bits / 8))
    }
}

// MARK: - Keccak (SHA3-224, Keccak-256)

struct Keccak: StreamingHash {
    static let rc: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000, 0x000000000000808B,
        0x0000000080000001, 0x8000000080008081, 0x8000000000008009, 0x000000000000008A, 0x0000000000000088,
        0x0000000080008009, 0x000000008000000A, 0x000000008000808B, 0x800000000000008B, 0x8000000000008089,
        0x8000000000008003, 0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    ]
    static let rotations: [UInt64] = [0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56, 14]

    var a = [UInt64](repeating: 0, count: 25)
    let rate: Int
    let outBytes: Int
    let suffix: UInt8           // 0x06 for SHA-3, 0x01 for original Keccak
    var blocks: BlockBuffer

    init(bits: Int, sha3: Bool) {
        outBytes = bits / 8
        rate = 200 - 2 * outBytes
        suffix = sha3 ? 0x06 : 0x01
        blocks = BlockBuffer(size: rate)
    }

    static func permute(_ a: inout [UInt64]) {
        var c = [UInt64](repeating: 0, count: 5), b = [UInt64](repeating: 0, count: 25)
        for round in 0 ..< 24 {
            for x in 0 ..< 5 { c[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20] }
            for x in 0 ..< 5 {
                let d = c[(x + 4) % 5] ^ rotl64(c[(x + 1) % 5], 1)
                for y in stride(from: 0, to: 25, by: 5) { a[y + x] ^= d }
            }
            for x in 0 ..< 5 {
                for y in 0 ..< 5 {
                    let r = rotations[x + 5 * y]
                    b[y + 5 * ((2 * x + 3 * y) % 5)] = r == 0 ? a[x + 5 * y] : rotl64(a[x + 5 * y], r)
                }
            }
            for y in stride(from: 0, to: 25, by: 5) {
                for x in 0 ..< 5 { a[y + x] = b[y + x] ^ ~b[y + (x + 1) % 5] & b[y + (x + 2) % 5] }
            }
            a[0] ^= rc[round]
        }
    }

    static func absorb(_ a: inout [UInt64], _ b: UnsafeRawBufferPointer) {
        for i in 0 ..< b.count / 8 { a[i] ^= b.loadUnaligned(fromByteOffset: 8 * i, as: UInt64.self).littleEndian }
        permute(&a)
    }

    mutating func update(_ buf: UnsafeRawBufferPointer) {
        var st = a
        blocks.feed(buf) { Self.absorb(&st, $0) }
        a = st
    }

    mutating func finalize() -> String {
        var last = blocks.pending + [UInt8](repeating: 0, count: rate - blocks.pending.count)
        last[blocks.pending.count] ^= suffix
        last[rate - 1] ^= 0x80
        last.withUnsafeBytes { Self.absorb(&a, $0) }
        let out = a.flatMap { withUnsafeBytes(of: $0.littleEndian, Array.init) }
        return hexString(out.prefix(outBytes))
    }
}

// MARK: - BLAKE2 (RFC 7693)

struct BLAKE2b: StreamingHash {
    static let iv: [UInt64] = [0x6A09E667F3BCC908, 0xBB67AE8584CAA73B, 0x3C6EF372FE94F82B, 0xA54FF53A5F1D36F1,
                               0x510E527FADE682D1, 0x9B05688C2B3E6C1F, 0x1F83D9ABFB41BD6B, 0x5BE0CD19137E2179]
    static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15], [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4], [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13], [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11], [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5], [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    ]
    var h: [UInt64]
    var t: UInt64 = 0
    var buf: [UInt8] = []
    let outLen = 64

    init() {
        h = Self.iv
        h[0] ^= 0x0101_0000 ^ UInt64(outLen)
    }

    static func compress(_ h: inout [UInt64], _ block: [UInt8], _ t: UInt64, last: Bool) {
        var m = [UInt64](repeating: 0, count: 16)
        block.withUnsafeBytes { b in for i in 0 ..< 16 { m[i] = b.loadUnaligned(fromByteOffset: 8 * i, as: UInt64.self).littleEndian } }
        var v = h + iv
        v[12] ^= t
        if last { v[14] = ~v[14] }
        func g(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
            v[a] = v[a] &+ v[b] &+ x; v[d] = rotr64(v[d] ^ v[a], 32)
            v[c] = v[c] &+ v[d]; v[b] = rotr64(v[b] ^ v[c], 24)
            v[a] = v[a] &+ v[b] &+ y; v[d] = rotr64(v[d] ^ v[a], 16)
            v[c] = v[c] &+ v[d]; v[b] = rotr64(v[b] ^ v[c], 63)
        }
        for r in 0 ..< 12 {
            let s = sigma[r % 10]
            g(0, 4, 8, 12, m[s[0]], m[s[1]]); g(1, 5, 9, 13, m[s[2]], m[s[3]])
            g(2, 6, 10, 14, m[s[4]], m[s[5]]); g(3, 7, 11, 15, m[s[6]], m[s[7]])
            g(0, 5, 10, 15, m[s[8]], m[s[9]]); g(1, 6, 11, 12, m[s[10]], m[s[11]])
            g(2, 7, 8, 13, m[s[12]], m[s[13]]); g(3, 4, 9, 14, m[s[14]], m[s[15]])
        }
        for i in 0 ..< 8 { h[i] ^= v[i] ^ v[i + 8] }
    }

    // The last block is compressed with the final flag, so a full block is
    // only processed once more data follows.
    mutating func update(_ data: UnsafeRawBufferPointer) {
        var i = 0
        while i < data.count {
            if buf.count == 128 {
                t &+= 128
                Self.compress(&h, buf, t, last: false)
                buf.removeAll(keepingCapacity: true)
            }
            let take = min(128 - buf.count, data.count - i)
            buf += data[i ..< i + take]
            i += take
        }
    }

    mutating func finalize() -> String {
        t &+= UInt64(buf.count)
        Self.compress(&h, buf + [UInt8](repeating: 0, count: 128 - buf.count), t, last: true)
        return hexString(h.flatMap { withUnsafeBytes(of: $0.littleEndian, Array.init) }.prefix(outLen))
    }
}

struct BLAKE2s: StreamingHash {
    static let iv: [UInt32] = [0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19]
    var h: [UInt32]
    var t: UInt64 = 0
    var buf: [UInt8] = []
    let outLen = 32

    init() {
        h = Self.iv
        h[0] ^= 0x0101_0000 ^ UInt32(outLen)
    }

    static func compress(_ h: inout [UInt32], _ block: [UInt8], _ t: UInt64, last: Bool) {
        var m = [UInt32](repeating: 0, count: 16)
        block.withUnsafeBytes { b in for i in 0 ..< 16 { m[i] = b.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self).littleEndian } }
        var v = h + iv
        v[12] ^= UInt32(truncatingIfNeeded: t)
        v[13] ^= UInt32(truncatingIfNeeded: t >> 32)
        if last { v[14] = ~v[14] }
        func g(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt32, _ y: UInt32) {
            v[a] = v[a] &+ v[b] &+ x; v[d] = rotr32(v[d] ^ v[a], 16)
            v[c] = v[c] &+ v[d]; v[b] = rotr32(v[b] ^ v[c], 12)
            v[a] = v[a] &+ v[b] &+ y; v[d] = rotr32(v[d] ^ v[a], 8)
            v[c] = v[c] &+ v[d]; v[b] = rotr32(v[b] ^ v[c], 7)
        }
        for r in 0 ..< 10 {
            let s = BLAKE2b.sigma[r]
            g(0, 4, 8, 12, m[s[0]], m[s[1]]); g(1, 5, 9, 13, m[s[2]], m[s[3]])
            g(2, 6, 10, 14, m[s[4]], m[s[5]]); g(3, 7, 11, 15, m[s[6]], m[s[7]])
            g(0, 5, 10, 15, m[s[8]], m[s[9]]); g(1, 6, 11, 12, m[s[10]], m[s[11]])
            g(2, 7, 8, 13, m[s[12]], m[s[13]]); g(3, 4, 9, 14, m[s[14]], m[s[15]])
        }
        for i in 0 ..< 8 { h[i] ^= v[i] ^ v[i + 8] }
    }

    mutating func update(_ data: UnsafeRawBufferPointer) {
        var i = 0
        while i < data.count {
            if buf.count == 64 {
                t &+= 64
                Self.compress(&h, buf, t, last: false)
                buf.removeAll(keepingCapacity: true)
            }
            let take = min(64 - buf.count, data.count - i)
            buf += data[i ..< i + take]
            i += take
        }
    }

    mutating func finalize() -> String {
        t &+= UInt64(buf.count)
        Self.compress(&h, buf + [UInt8](repeating: 0, count: 64 - buf.count), t, last: true)
        return hexString(h.flatMap { withUnsafeBytes(of: $0.littleEndian, Array.init) }.prefix(outLen))
    }
}

// MARK: - BLAKE3 (256-bit output, no key)

struct BLAKE3: StreamingHash {
    static let iv = SIMD8<UInt32>(0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19)
    static let chunkStart: UInt32 = 1, chunkEnd: UInt32 = 2, parent: UInt32 = 4, root: UInt32 = 8

    /// Full 16-word output: words 0–7 are the chaining value. Scalar with
    /// local variables: faster in Swift than lane shuffles.
    static func compress(_ cv: SIMD8<UInt32>, _ m: SIMD16<UInt32>, _ counter: UInt64, _ len: UInt32, _ flags: UInt32) -> SIMD16<UInt32> {
        var v0 = cv[0], v1 = cv[1], v2 = cv[2], v3 = cv[3], v4 = cv[4], v5 = cv[5], v6 = cv[6], v7 = cv[7]
        var v8 = iv[0], v9 = iv[1], v10 = iv[2], v11 = iv[3]
        var v12 = UInt32(truncatingIfNeeded: counter), v13 = UInt32(truncatingIfNeeded: counter >> 32), v14 = len, v15 = flags
        var m0 = m[0], m1 = m[1], m2 = m[2], m3 = m[3], m4 = m[4], m5 = m[5], m6 = m[6], m7 = m[7]
        var m8 = m[8], m9 = m[9], m10 = m[10], m11 = m[11], m12 = m[12], m13 = m[13], m14 = m[14], m15 = m[15]
        @inline(__always) func g(_ a: inout UInt32, _ b: inout UInt32, _ c: inout UInt32, _ d: inout UInt32, _ x: UInt32, _ y: UInt32) {
            a = a &+ b &+ x; d = rotr32(d ^ a, 16); c = c &+ d; b = rotr32(b ^ c, 12)
            a = a &+ b &+ y; d = rotr32(d ^ a, 8); c = c &+ d; b = rotr32(b ^ c, 7)
        }
        for r in 0 ..< 7 {
            g(&v0, &v4, &v8, &v12, m0, m1); g(&v1, &v5, &v9, &v13, m2, m3)
            g(&v2, &v6, &v10, &v14, m4, m5); g(&v3, &v7, &v11, &v15, m6, m7)
            g(&v0, &v5, &v10, &v15, m8, m9); g(&v1, &v6, &v11, &v12, m10, m11)
            g(&v2, &v7, &v8, &v13, m12, m13); g(&v3, &v4, &v9, &v14, m14, m15)
            if r < 6 {
                // Message permutation: 2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8.
                (m0, m1, m2, m3, m4, m5, m6, m7, m8, m9, m10, m11, m12, m13, m14, m15)
                    = (m2, m6, m3, m10, m7, m0, m4, m13, m1, m11, m12, m5, m9, m14, m15, m8)
            }
        }
        return SIMD16(v0 ^ v8, v1 ^ v9, v2 ^ v10, v3 ^ v11, v4 ^ v12, v5 ^ v13, v6 ^ v14, v7 ^ v15,
                      v8 ^ cv[0], v9 ^ cv[1], v10 ^ cv[2], v11 ^ cv[3], v12 ^ cv[4], v13 ^ cv[5], v14 ^ cv[6], v15 ^ cv[7])
    }

    static func words(_ p: UnsafeRawBufferPointer) -> SIMD16<UInt32> {
        // Apple platforms are little-endian: one load for all 16 words.
        p.loadUnaligned(as: SIMD16<UInt32>.self)
    }

    // Chunk state.
    var cv = iv
    var chunkCounter: UInt64 = 0
    var block = [UInt8]()
    var blocksCompressed = 0
    /// Chaining values of completed subtrees, merged like a binary counter.
    var stack: [SIMD8<UInt32>] = []

    struct Output {
        let cv: SIMD8<UInt32>, m: SIMD16<UInt32>, counter: UInt64, len: UInt32, flags: UInt32
        func chaining() -> SIMD8<UInt32> { BLAKE3.compress(cv, m, counter, len, flags).lowHalf }
        func rootBytes() -> [UInt8] {
            let o = BLAKE3.compress(cv, m, 0, len, flags | BLAKE3.root).lowHalf
            return (0 ..< 8).flatMap { withUnsafeBytes(of: o[$0].littleEndian, Array.init) }
        }
    }

    func chunkOutput() -> Output {
        let flags = (blocksCompressed == 0 ? Self.chunkStart : 0) | Self.chunkEnd
        let padded = block + [UInt8](repeating: 0, count: 64 - block.count)
        return Output(cv: cv, m: padded.withUnsafeBytes(Self.words), counter: chunkCounter, len: UInt32(block.count), flags: flags)
    }

    static func parentOutput(_ l: SIMD8<UInt32>, _ r: SIMD8<UInt32>) -> Output {
        Output(cv: iv, m: SIMD16(lowHalf: l, highHalf: r), counter: 0, len: 64, flags: parent)
    }

    mutating func addChunkCV(_ newCV: SIMD8<UInt32>, total: UInt64) {
        var cv = newCV, t = total
        while t & 1 == 0 {
            cv = Self.parentOutput(stack.removeLast(), cv).chaining()
            t >>= 1
        }
        stack.append(cv)
    }

    /// Compresses one full 64-byte block known not to be the chunk's last.
    @inline(__always) mutating func absorb(_ p: UnsafeRawBufferPointer) {
        let flags = blocksCompressed == 0 ? Self.chunkStart : 0
        cv = Self.compress(cv, Self.words(p), chunkCounter, 64, flags).lowHalf
        blocksCompressed += 1
    }

    /// The pending full block was the chunk's 16th: finish the chunk.
    mutating func finishChunkIfFull() {
        guard block.count == 64 else { return }
        if blocksCompressed == 15 {
            addChunkCV(chunkOutput().chaining(), total: chunkCounter + 1)
            chunkCounter += 1
            cv = Self.iv
            blocksCompressed = 0
        } else {
            block.withUnsafeBytes { absorb($0) }
        }
        block.removeAll(keepingCapacity: true)
    }

    mutating func update(_ data: UnsafeRawBufferPointer) {
        var i = 0
        while i < data.count {
            // A full pending block is only processed once more input
            // arrives: the last block of the input gets the end flags.
            finishChunkIfFull()
            // Fast path: whole blocks straight from the input, as long as
            // more data follows and the block is not a chunk's last.
            while block.isEmpty, blocksCompressed < 15, data.count - i > 64 {
                absorb(UnsafeRawBufferPointer(rebasing: data[i ..< i + 64]))
                i += 64
            }
            let take = min(64 - block.count, data.count - i)
            block += data[i ..< i + take]
            i += take
        }
    }

    mutating func finalize() -> String {
        var out = chunkOutput()
        for left in stack.reversed() { out = Self.parentOutput(left, out.chaining()) }
        return hexString(out.rootBytes())
    }
}

// MARK: - RIPEMD-160

struct RIPEMD160: StreamingHash {
    var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
    var blocks = BlockBuffer(size: 64)

    static let rl = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8,
                     3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12, 1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2,
                     4, 0, 5, 9, 7, 12, 2, 10, 14, 1, 3, 8, 11, 6, 15, 13]
    static let rr = [5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12, 6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2,
                     15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13, 8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14,
                     12, 15, 10, 4, 1, 5, 8, 7, 6, 2, 13, 14, 0, 3, 9, 11]
    static let sl: [UInt32] = [11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8, 7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12,
                               11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5, 11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12,
                               9, 15, 5, 11, 6, 8, 13, 12, 5, 12, 13, 14, 11, 8, 5, 6]
    static let sr: [UInt32] = [8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6, 9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11,
                               9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5, 15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8,
                               8, 5, 12, 9, 12, 5, 14, 6, 8, 13, 6, 5, 15, 13, 11, 11]
    static let kl: [UInt32] = [0x00000000, 0x5A827999, 0x6ED9EBA1, 0x8F1BBCDC, 0xA953FD4E]
    static let kr: [UInt32] = [0x50A28BE6, 0x5C4DD124, 0x6D703EF3, 0x7A6D76E9, 0x00000000]

    static func f(_ j: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        switch j / 16 {
        case 0: x ^ y ^ z
        case 1: x & y | ~x & z
        case 2: (x | ~y) ^ z
        case 3: x & z | y & ~z
        default: x ^ (y | ~z)
        }
    }

    static func compress(_ h: inout [UInt32], _ b: UnsafeRawBufferPointer) {
        var x = [UInt32](repeating: 0, count: 16)
        for i in 0 ..< 16 { x[i] = b.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self).littleEndian }
        var al = h[0], bl = h[1], cl = h[2], dl = h[3], el = h[4]
        var ar = h[0], br = h[1], cr = h[2], dr = h[3], er = h[4]
        for j in 0 ..< 80 {
            var t = rotl32(al &+ f(j, bl, cl, dl) &+ x[rl[j]] &+ kl[j / 16], sl[j]) &+ el
            al = el; el = dl; dl = rotl32(cl, 10); cl = bl; bl = t
            t = rotl32(ar &+ f(79 - j, br, cr, dr) &+ x[rr[j]] &+ kr[j / 16], sr[j]) &+ er
            ar = er; er = dr; dr = rotl32(cr, 10); cr = br; br = t
        }
        let t = h[1] &+ cl &+ dr
        h[1] = h[2] &+ dl &+ er; h[2] = h[3] &+ el &+ ar; h[3] = h[4] &+ al &+ br; h[4] = h[0] &+ bl &+ cr; h[0] = t
    }

    mutating func update(_ buf: UnsafeRawBufferPointer) {
        var st = h
        blocks.feed(buf) { Self.compress(&st, $0) }
        h = st
    }

    mutating func finalize() -> String {
        let pad = mdPadding(total: blocks.total, pending: blocks.pending.count, bigEndian: false)
        pad.withUnsafeBytes { update($0) }
        return hexString(h.flatMap { withUnsafeBytes(of: $0.littleEndian, Array.init) })
    }
}

// MARK: - SM3 (GB/T 32905-2016)

struct SM3: StreamingHash {
    var v: [UInt32] = [0x7380166F, 0x4914B2B9, 0x172442D7, 0xDA8A0600, 0xA96F30BC, 0x163138AA, 0xE38DEE4D, 0xB0FB0E4E]
    var blocks = BlockBuffer(size: 64)

    static func compress(_ v: inout [UInt32], _ b: UnsafeRawBufferPointer) {
        var w = [UInt32](repeating: 0, count: 68)
        for i in 0 ..< 16 { w[i] = b.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self).bigEndian }
        func p1(_ x: UInt32) -> UInt32 { x ^ rotl32(x, 15) ^ rotl32(x, 23) }
        func p0(_ x: UInt32) -> UInt32 { x ^ rotl32(x, 9) ^ rotl32(x, 17) }
        for j in 16 ..< 68 { w[j] = p1(w[j - 16] ^ w[j - 9] ^ rotl32(w[j - 3], 15)) ^ rotl32(w[j - 13], 7) ^ w[j - 6] }
        var a = v[0], bb = v[1], c = v[2], d = v[3], e = v[4], f = v[5], g = v[6], h = v[7]
        for j in 0 ..< 64 {
            let t: UInt32 = j < 16 ? 0x79CC4519 : 0x7A879D8A
            let ss1 = rotl32(rotl32(a, 12) &+ e &+ rotl32(t, UInt32(j % 32)), 7)
            let ss2 = ss1 ^ rotl32(a, 12)
            let ff = j < 16 ? a ^ bb ^ c : a & bb | a & c | bb & c
            let gg = j < 16 ? e ^ f ^ g : e & f | ~e & g
            let tt1 = ff &+ d &+ ss2 &+ (w[j] ^ w[j + 4])
            let tt2 = gg &+ h &+ ss1 &+ w[j]
            d = c; c = rotl32(bb, 9); bb = a; a = tt1
            h = g; g = rotl32(f, 19); f = e; e = p0(tt2)
        }
        v[0] ^= a; v[1] ^= bb; v[2] ^= c; v[3] ^= d; v[4] ^= e; v[5] ^= f; v[6] ^= g; v[7] ^= h
    }

    mutating func update(_ buf: UnsafeRawBufferPointer) {
        var st = v
        blocks.feed(buf) { Self.compress(&st, $0) }
        v = st
    }

    mutating func finalize() -> String {
        let pad = mdPadding(total: blocks.total, pending: blocks.pending.count, bigEndian: true)
        pad.withUnsafeBytes { update($0) }
        return hexString(v.flatMap { withUnsafeBytes(of: $0.bigEndian, Array.init) })
    }
}

// MARK: - MD2 (RFC 1319)

struct MD2: StreamingHash {
    /// PI_SUBST from RFC 1319 (permutation of 0–255 from the digits of pi).
    static let s: [UInt8] = [
        41, 46, 67, 201, 162, 216, 124, 1, 61, 54, 84, 161, 236, 240, 6, 19,
        98, 167, 5, 243, 192, 199, 115, 140, 152, 147, 43, 217, 188, 76, 130, 202,
        30, 155, 87, 60, 253, 212, 224, 22, 103, 66, 111, 24, 138, 23, 229, 18,
        190, 78, 196, 214, 218, 158, 222, 73, 160, 251, 245, 142, 187, 47, 238, 122,
        169, 104, 121, 145, 21, 178, 7, 63, 148, 194, 16, 137, 11, 34, 95, 33,
        128, 127, 93, 154, 90, 144, 50, 39, 53, 62, 204, 231, 191, 247, 151, 3,
        255, 25, 48, 179, 72, 165, 181, 209, 215, 94, 146, 42, 172, 86, 170, 198,
        79, 184, 56, 210, 150, 164, 125, 182, 118, 252, 107, 226, 156, 116, 4, 241,
        69, 157, 112, 89, 100, 113, 135, 32, 134, 91, 207, 101, 230, 45, 168, 2,
        27, 96, 37, 173, 174, 176, 185, 246, 28, 70, 97, 105, 52, 64, 126, 15,
        85, 71, 163, 35, 221, 81, 175, 58, 195, 92, 249, 206, 186, 197, 234, 38,
        44, 83, 13, 110, 133, 40, 132, 9, 211, 223, 205, 244, 65, 129, 77, 82,
        106, 220, 55, 200, 108, 193, 171, 250, 36, 225, 123, 8, 12, 189, 177, 74,
        120, 136, 149, 139, 227, 99, 232, 109, 233, 203, 213, 254, 59, 0, 29, 57,
        242, 239, 183, 14, 102, 88, 208, 228, 166, 119, 114, 248, 235, 117, 75, 10,
        49, 68, 80, 180, 143, 237, 31, 26, 219, 153, 141, 51, 159, 17, 131, 20,
    ]
    var state = [UInt8](repeating: 0, count: 48)
    var checksum = [UInt8](repeating: 0, count: 16)
    var blocks = BlockBuffer(size: 16)

    static func compress(_ xa: inout [UInt8], _ ca: inout [UInt8], _ b: UnsafeRawBufferPointer) {
        // Unchecked pointers: MD2 does 18×48 table lookups per 16-byte block.
        s.withUnsafeBufferPointer { s in
            xa.withUnsafeMutableBufferPointer { x in
                ca.withUnsafeMutableBufferPointer { c in
                    var l = c[15]
                    for i in 0 ..< 16 {
                        x[16 + i] = b[i]
                        x[32 + i] = b[i] ^ x[i]
                        c[i] ^= s[Int(b[i] ^ l)]
                        l = c[i]
                    }
                    var t: UInt8 = 0
                    for j in 0 ..< 18 {
                        for k in 0 ..< 48 { x[k] ^= s[Int(t)]; t = x[k] }
                        t = t &+ UInt8(j)
                    }
                }
            }
        }
    }

    mutating func update(_ buf: UnsafeRawBufferPointer) {
        var x = state, c = checksum
        blocks.feed(buf) { Self.compress(&x, &c, $0) }
        state = x; checksum = c
    }

    mutating func finalize() -> String {
        let n = 16 - blocks.pending.count
        [UInt8](repeating: UInt8(n), count: n).withUnsafeBytes { update($0) }
        let c = checksum
        c.withUnsafeBytes { update($0) }
        return hexString(state.prefix(16))
    }
}
