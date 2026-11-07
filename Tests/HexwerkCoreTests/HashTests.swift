import Foundation
import Testing
@testable import HexwerkCore

@Suite struct HashTests {
    let check = Data("123456789".utf8)

    /// Check values from the CRC catalogue (reveng) for "123456789".
    @Test func crcCheckValues() {
        let expected: [Checksum: String] = [
            .crc8: "f4", .crc8Maxim: "a1",
            .crc16Arc: "bb3d", .crc16Modbus: "4b37", .crc16CcittFalse: "29b1",
            .crc16Xmodem: "31c3", .crc16Kermit: "2189", .crc16X25: "906e",
            .crc32: "cbf43926", .crc32c: "e3069283", .crc32Bzip2: "fc891918", .crc32Mpeg2: "0376e6e7",
            .crc64Ecma: "6c40df5f0b497347", .crc64Xz: "995dc9bbdf1939fa",
        ]
        for (a, v) in expected { #expect(Checksum.compute(a, check) == v, "\(a.rawValue)") }
    }

    @Test func knownVectors() {
        let abc = Data("abc".utf8), empty = Data(), abcde = Data("abcde".utf8)
        #expect(Checksum.compute(.adler32, Data("Wikipedia".utf8)) == "11e60398")
        #expect(Checksum.compute(.fletcher16, abcde) == "c8f0")
        #expect(Checksum.compute(.fletcher32, abcde) == "f04fc729")
        #expect(Checksum.compute(.fletcher32, Data("abcdef".utf8)) == "56502d2a")
        #expect(Checksum.compute(.sum8, check) == "dd")
        #expect(Checksum.compute(.xor8, check) == "31")
        #expect(Checksum.compute(.fnv1a32, abc) == "1a47e90b")
        #expect(Checksum.compute(.fnv1a64, abc) == "e71fa2190541574b")
        #expect(Checksum.compute(.murmur3, Data("hello".utf8)) == "248bfa47")
        #expect(Checksum.compute(.murmur3, empty) == "00000000")
        #expect(Checksum.compute(.xxh32, empty) == "02cc5d05")
        #expect(Checksum.compute(.xxh32, abc) == "32d153ff")
        #expect(Checksum.compute(.xxh64, empty) == "ef46db3751d8e999")
        #expect(Checksum.compute(.xxh64, abc) == "44bc2cf5ad770999")
        #expect(Checksum.compute(.md4, empty) == "31d6cfe0d16ae931b73c59d7e0c089c0")
        #expect(Checksum.compute(.md4, abc) == "a448017aaf21d8525fc10ae87aa6729d")
        #expect(Checksum.compute(.keccak256, empty) == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        #expect(Checksum.compute(.blake3, empty) == "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262")
        #expect(Checksum.compute(.blake3, abc) == "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85")
    }

    /// RFC 1319 test suite.
    @Test func md2Vectors() {
        let v: [(String, String)] = [
            ("", "8350e5a3e24c153df2275c9f80692773"),
            ("a", "32ec01ec4a6dac72c0ab96fb34c0b5d1"),
            ("abc", "da853b0d3f88d99b30283a69e6ded6bb"),
            ("message digest", "ab4f496bfb2a530b219ff33031fe06b0"),
            ("abcdefghijklmnopqrstuvwxyz", "4e8ddff3650292ab5a4108c3aa47940b"),
            ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789", "da33def2a42df13975352846c30338cd"),
            ("12345678901234567890123456789012345678901234567890123456789012345678901234567890", "d5976f79d83d3a0dc9806c3c66f3efd8"),
        ]
        for (m, h) in v { #expect(Checksum.compute(.md2, Data(m.utf8)) == h, "MD2(\(m))") }
    }

    /// BLAKE3 official test vectors: input byte i = i % 251.
    @Test func blake3TreeVectors() {
        func input(_ n: Int) -> Data { Data((0 ..< n).map { UInt8($0 % 251) }) }
        let v: [Int: String] = [
            1023: "10108970eeda3eb932baac1428c7a2163b0e924c9a9e25b35bba72b28f70bd11",
            1024: "42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7",
            1025: "d00278ae47eb27b34faecf67b4fe263f82d5412916c1ffd97c8cb7fb814b8444",
            2048: "e776b6028c7cd22a4d0ba182a8bf62205d2ef576467e838ed6f2529b85fba24a",
            2049: "5f4d72f40d7a5f82b15ca2b2e44b1de3c2ef86c426c95c1af0b6879522563030",
            3072: "b98cb0ff3623be03326b373de6b9095218513e64f1ee2edd2525c7ad1e5cffd2",
            31744: "62b6960e1a44bcc1eb1a611a8d6235b6b4b78f32e7abc4fb4c6cdcce94895c47",
        ]
        for (n, h) in v { #expect(Checksum.compute(.blake3, input(n)) == h, "BLAKE3 \(n)") }
    }

    /// Cryptographic hashes against Python's hashlib (OpenSSL) for lengths
    /// around every block boundary, fed in odd-sized pieces.
    @Test func cryptoAgainstPython() throws {
        let algos: [(Checksum, String)] = [
            (.sha224, "sha224"), (.sha512_224, "sha512_224"), (.sha512_256, "sha512_256"),
            (.sha3_224, "sha3_224"), (.sha3_256, "sha3_256"), (.blake2b, "blake2b"), (.blake2s, "blake2s"),
            (.ripemd160, "ripemd160"), (.sm3, "sm3"), (.md5, "md5"), (.sha1, "sha1"), (.sha512, "sha512"),
        ]
        let lengths = [0, 1, 55, 56, 63, 64, 65, 111, 112, 127, 128, 129, 135, 136, 137, 1000, 4097]
        var rng = SplitMix(seed: 99)
        let full = Data((0 ..< 4097).map { _ in UInt8.random(in: 0 ... 255, using: &rng) })
        let url = try tempFile(full)
        defer { try? FileManager.default.removeItem(at: url) }
        let script = """
            import hashlib, sys
            d = open(sys.argv[1], 'rb').read()
            for n in \(lengths):
                print(' '.join(hashlib.new(a, d[:n]).hexdigest() for a in \(algos.map(\.1))))
            """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-I", "-c", script, url.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let rows = text.split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
        try #require(rows.count == lengths.count)
        for (row, n) in zip(rows, lengths) {
            let data = full.prefix(n)
            for (i, (a, _)) in algos.enumerated() {
                // Feed in uneven pieces to exercise block buffering.
                var h = a.makeHasher()
                var k = 0, step = 1
                while k < data.count {
                    let e = min(data.count, k + step)
                    data[data.startIndex + k ..< data.startIndex + e].withUnsafeBytes { h.update($0) }
                    k = e
                    step = step * 3 % 97 + 1
                }
                #expect(h.finalize() == row[i], "\(a.rawValue) n=\(n)")
            }
        }
    }

    @Test func onePassOverSnapshotMatchesSingle() throws {
        var rng = SplitMix(seed: 5)
        let d = Data((0 ..< 300_000).map { _ in UInt8.random(in: 0 ... 255, using: &rng) })
        let url = try tempFile(d)
        defer { try? FileManager.default.removeItem(at: url) }
        let snap = try Document(url: url).snapshot()
        let all = try #require(Checksum.compute(Checksum.allCases, snap, range: 10 ..< 299_000))
        for a in Checksum.allCases { #expect(all[a] == Checksum.compute(a, d[10 ..< 299_000]), "\(a.rawValue)") }
    }

    /// The app cancels a running checksum through the progress callback.
    @Test func cancelStopsAfterFirstChunk() throws {
        let url = try tempFile(Data(count: 9 << 20))
        defer { try? FileManager.default.removeItem(at: url) }
        let snap = try Document(url: url).snapshot()
        var calls = 0
        let r = Checksum.compute([.sha256], snap) { _ in
            calls += 1; return false
        }
        #expect(r == nil)
        #expect(calls == 1)
    }
}
