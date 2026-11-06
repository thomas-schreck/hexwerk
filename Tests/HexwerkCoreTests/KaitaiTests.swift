import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HexwerkCore
@testable import HexwerkKaitai

/// Reference .ksy files (copied from kaitai_struct_formats, see Fixtures/ksy/README.md).
let ksyRoot = Bundle.module.url(forResource: "Fixtures/ksy", withExtension: nil)!

func parse(_ data: Data, ksy: String) throws -> ParseResult {
    let url = try tempFile(data)
    defer { try? FileManager.default.removeItem(at: url) }
    return try parse(url: url, ksy: ksy)
}

func parse(url: URL, ksy: String) throws -> ParseResult {
    let schema = try KsyLoader(libraryRoots: [ksyRoot]).load(ksyRoot.appendingPathComponent(ksy))
    return KaitaiInterpreter.parse(try Document(url: url, readOnly: true).snapshot(), file: schema)
}

/// Inline .ksy for small language tests.
func parse(_ data: Data, yaml: String) throws -> ParseResult {
    let ksy = FileManager.default.temporaryDirectory.appendingPathComponent("hexwerk-\(UUID().uuidString).ksy")
    try yaml.write(to: ksy, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: ksy) }
    let url = try tempFile(data)
    defer { try? FileManager.default.removeItem(at: url) }
    let schema = try KsyLoader().load(ksy)
    return KaitaiInterpreter.parse(try Document(url: url, readOnly: true).snapshot(), file: schema)
}

extension ParseNode {
    /// Child by dotted path, e.g. "ihdr.width" or "chunks.[2].type".
    func at(_ path: String) -> ParseNode? {
        var n: ParseNode? = self
        for part in path.split(separator: ".") { n = n?.children.first { $0.name == part } }
        return n
    }
}

func image(_ type: UTType, width: Int, height: Int) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
func be<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }

func run(_ tool: String, _ args: [String], cwd: URL) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.currentDirectoryURL = cwd
    try p.run()
    p.waitUntilExit()
}

/// TC-3.1: reference formats parse completely and give the values the
/// files were made with.
@Suite struct KaitaiFormatTests {
    @Test func png() throws {
        let r = try parse(image(.png, width: 53, height: 37), ksy: "image/png.ksy")
        #expect(r.error == nil)
        #expect(r.root.at("ihdr.width")?.number == 53)
        #expect(r.root.at("ihdr.height")?.number == 37)
        #expect(r.root.at("chunks")?.children.last?.at("type")?.value == "\"IEND\"")
        #expect(r.root.at("ihdr.width")?.range == 16..<20)
    }

    @Test func gif() throws {
        let r = try parse(image(.gif, width: 20, height: 10), ksy: "image/gif.ksy")
        #expect(r.error == nil)
        #expect(r.root.at("logical_screen_descriptor.screen_width")?.number == 20)
        #expect(r.root.at("logical_screen_descriptor.screen_height")?.number == 10)
    }

    @Test func bmp() throws {
        let r = try parse(image(.bmp, width: 31, height: 7), ksy: "image/bmp.ksy")
        #expect(r.error == nil)
        let header = r.root.at("dib_info.header")
        #expect(header?.at("image_width")?.number == 31)
        #expect(header?.at("image_height")?.number == 7)
    }

    @Test func zip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hexwerk-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(String(repeating: "Hallo Welt\n", count: 50).utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("b.bin"))
        // -X: no extra attributes, see `zipInfoZipTimestamps` for those.
        try run("/usr/bin/zip", ["-q", "-X", "t.zip", "a.txt", "b.bin"], cwd: dir)
        let r = try parse(url: dir.appendingPathComponent("t.zip"), ksy: "archive/zip.ksy")
        #expect(r.error == nil)
        let first = r.root.at("sections.[0].body.header")
        #expect(first?.at("file_name")?.value == "\"a.txt\"")
        #expect(first?.at("len_body_uncompressed")?.number == 550)
        #expect(r.root.at("sections")?.children.count == 5)   // 2 local, 2 central, end
    }

    /// Info-ZIP writes the access-time flag in the central directory but only
    /// stores the modification time there. The .ksy follows the spec, so the
    /// official runtimes stop here too; we keep the tree up to that point.
    @Test func zipInfoZipTimestamps() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hexwerk-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try run("/usr/bin/zip", ["-q", "t.zip", "a.txt"], cwd: dir)
        let r = try parse(url: dir.appendingPathComponent("t.zip"), ksy: "archive/zip.ksy")
        #expect(r.error?.path.hasSuffix("access_time") == true)
        #expect(r.root.at("sections.[0].body.header.file_name")?.value == "\"a.txt\"")
    }

    @Test func gzip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hexwerk-gz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(String(repeating: "Hallo Welt\n", count: 50).utf8).write(to: dir.appendingPathComponent("a.txt"))
        try run("/usr/bin/gzip", ["a.txt"], cwd: dir)
        let r = try parse(url: dir.appendingPathComponent("a.txt.gz"), ksy: "archive/gzip.ksy")
        #expect(r.error == nil)
        #expect(r.root.at("len_uncompressed")?.number == 550)
        #expect(r.root.at("flags.has_name")?.value == "true")
        #expect(r.root.at("name")?.value == "61 2E 74 78 74")   // "a.txt"
    }

    @Test func wav() throws {
        let samples = 100
        var d: [UInt8] = Array("RIFF".utf8) + le(UInt32(36 + samples * 2)) + Array("WAVE".utf8)
        d += Array("fmt ".utf8) + le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1)) + le(UInt32(8000))
            + le(UInt32(16000)) + le(UInt16(2)) + le(UInt16(16))
        d += Array("data".utf8) + le(UInt32(samples * 2)) + [UInt8](repeating: 0, count: samples * 2)
        let r = try parse(Data(d), ksy: "media/wav.ksy")
        #expect(r.error == nil)
        let fmt = r.root.at("subchunks.[0].chunk_data")
        #expect(fmt?.at("n_samples_per_sec")?.number == 8000)
        #expect(fmt?.at("n_channels")?.number == 1)
        #expect(fmt?.at("w_bits_per_sample")?.number == 16)
    }

    @Test func pcap() throws {
        var d: [UInt8] = le(UInt32(0xA1B2_C3D4)) + le(UInt16(2)) + le(UInt16(4)) + le(Int32(0))
            + le(UInt32(0)) + le(UInt32(65535)) + le(UInt32(1))
        for (i, payload) in ["hello", "world!!"].enumerated() {
            let p = Array(payload.utf8)
            let udp = be(UInt16(1234)) + be(UInt16(53)) + be(UInt16(8 + p.count)) + be(UInt16(0)) + p
            let ip: [UInt8] = [0x45, 0] + be(UInt16(20 + udp.count)) + be(UInt16(1)) + be(UInt16(0)) + [64, 17]
                + be(UInt16(0)) + [10, 0, 0, 1, 10, 0, 0, 2] + udp
            let frame: [UInt8] = [0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 8, 0] + ip
            d += le(UInt32(i + 1)) + le(UInt32(0)) + le(UInt32(frame.count)) + le(UInt32(frame.count)) + frame
        }
        let r = try parse(Data(d), ksy: "network/pcap.ksy")
        #expect(r.error == nil)
        #expect(r.root.at("packets")?.children.count == 2)
        #expect(r.root.at("packets.[1].body.body.body.body.dst_port")?.number == 53)
    }

    @Test func elf() throws {
        var d: [UInt8] = [0x7F] + Array("ELF".utf8) + [2, 1, 1, 0] + [UInt8](repeating: 0, count: 8)
        d += le(UInt16(2)) + le(UInt16(0x3E)) + le(UInt32(1)) + le(UInt64(0x401000)) + le(UInt64(64))
            + le(UInt64(0)) + le(UInt32(0)) + le(UInt16(64)) + le(UInt16(56)) + le(UInt16(1))
            + le(UInt16(64)) + le(UInt16(0)) + le(UInt16(0))
        d += le(UInt32(1)) + le(UInt32(5)) + le(UInt64(0)) + le(UInt64(0x400000)) + le(UInt64(0x400000))
            + le(UInt64(0x80)) + le(UInt64(0x80)) + le(UInt64(0x1000))
        d += [UInt8](repeating: 0, count: 0x80 - d.count)
        let r = try parse(Data(d), ksy: "executable/elf.ksy")
        #expect(r.error == nil)
        #expect(r.root.at("header.entry_point")?.number == 0x401000)
        #expect(r.root.at("header.machine")?.value?.hasPrefix("x86_64") == true)
        #expect(r.root.at("header.program_headers")?.children.count == 1)
    }

    /// TC-3.6: a cut-off file keeps the tree read so far and says where.
    @Test func truncatedPNG() throws {
        let full = image(.png, width: 53, height: 37)
        let r = try parse(full.prefix(40), ksy: "image/png.ksy")
        #expect(r.error != nil)
        #expect(r.error?.offset != nil)
        #expect(r.root.at("ihdr.width")?.number == 53)
    }
}

@Suite struct KaitaiLanguageTests {
    func value(_ expr: String) throws -> String? {
        let r = try parse(Data([0]), yaml: """
            meta: {id: t}
            instances:
              v: {value: '\(expr)'}
            """)
        if let e = r.error { throw e }
        return r.root.at("v")?.value ?? r.root.at("v")?.error
    }

    @Test func expressions() throws {
        #expect(try value("1 + 2 * 3") == "7")
        #expect(try value("(1 + 2) * 3") == "9")
        #expect(try value("-7 / 2") == "-4")            // floor division like Python
        #expect(try value("-7 % 3") == "2")
        #expect(try value("1 << 4 | 1") == "17 (0x11)")
        #expect(try value("3 > 2 and not false") == "true")
        #expect(try value("5 > 3 ? 10 : 20") == "10 (0xA)")
        #expect(try value("\"ab\" + \"cd\"") == "\"abcd\"")
        #expect(try value("\"hello\".substring(1, 3)") == "\"el\"")
        #expect(try value("\"ff\".to_i(16)") == "255 (0xFF)")
        #expect(try value("[1, 2, 3].size") == "3")
        #expect(try value("0x10 + 0b11 + 1_000") == "1019 (0x3FB)")
        #expect(try value("1.5 * 2") == "3.0")
    }

    /// Hostile expressions must give an error, never trap (#6).
    @Test func arithmeticEdgeCasesDoNotTrap() throws {
        for expr in ["-9223372036854775807 - 1 / -1", "(-9223372036854775807 - 1) / -1",
                     "1 >> -1", "1 << -1", "(0.0 / 0.0).to_i", "(1.0 / 0.0).to_i", "1e300.to_i",
                     "\"12\".to_i(99)", "\"12\".to_i(1)", "\"abc\".substring", "\"abc\".substring(1)"] {
            _ = try value(expr)          // an error value is fine; a crash is not
        }
        #expect(try value("(-9223372036854775807 - 1) % -1") == "0")
        #expect(try value("2.9.to_i") == "2")
        #expect(try value("-2.9.to_i") == "-2")
        // repeat-expr with a float that does not fit reports an error.
        let r = try parse(Data([0, 0]), yaml: """
            meta: {id: t}
            seq:
              - {id: a, type: u1, repeat: expr, repeat-expr: 1e300}
            """)
        #expect(r.error != nil || r.root.at("a")?.error != nil)
    }

    /// Overflow in the number-array fast path, sizeof, ror and literals (#7).
    @Test func sizeAndLiteralOverflowsDoNotTrap() throws {
        let huge = try parse(Data(repeating: 0, count: 16), yaml: """
            meta: {id: t}
            seq:
              - {id: a, type: u8, repeat: expr, repeat-expr: 0x7fffffffffffffff}
            """)
        #expect(huge.error != nil || huge.root.at("a")?.error != nil)

        let sz = try parse(Data([0]), yaml: """
            meta: {id: t}
            types:
              big:
                seq:
                  - {id: a, size: 0x2000000000000000}
              many:
                seq:
                  - {id: b, type: u8, repeat: expr, repeat-expr: 0x2000000000000000}
            instances:
              s1: {value: sizeof<big>}
              s2: {value: sizeof<many>}
            """)
        #expect(sz.root.at("s1")?.error != nil)
        #expect(sz.root.at("s2")?.error != nil)

        let rot = try parse(Data([0x81]), yaml: """
            meta: {id: t}
            seq:
              - {id: a, size: 1, process: ror(-9223372036854775807 - 1)}
            """)
        #expect(rot.error == nil)

        #expect(Expr.parseIntLiteral("-0x8000000000000000") == .min)
        #expect(Expr.parseIntLiteral("-0x8000000000000001") == nil)
        #expect(Expr.parseIntLiteral("0xffffffffffffffff") == -1)
    }

    /// An instance that parses its own type again must stop at the depth
    /// limit instead of overflowing the stack (#8).
    @Test func selfReferencingInstanceStops() throws {
        let r = try parse(Data(repeating: 1, count: 64), yaml: """
            meta: {id: t}
            seq:
              - {id: a, size: me.a.length}
            instances:
              me: {pos: 0, type: t}
            """)
        // Reaching here without a crash is the point; the chain ends in an error.
        #expect(r.error != nil || r.root.at("a")?.error != nil)
    }

    /// sizeof of a type that contains itself is an error, not a stack overflow (#9).
    @Test func sizeofRecursiveTypeStops() throws {
        let r = try parse(Data([0]), yaml: """
            meta: {id: t}
            types:
              x:
                seq:
                  - {id: a, type: x}
            instances:
              s: {value: sizeof<x>}
            """)
        #expect(r.root.at("s")?.error != nil)
    }

    @Test func enumsAndSwitch() throws {
        let r = try parse(Data([2, 0xAA, 0xBB]), yaml: """
            meta: {id: t, endian: be}
            seq:
              - {id: kind, type: u1, enum: kinds}
              - id: body
                type:
                  switch-on: kind
                  cases:
                    'kinds::short': u1
                    'kinds::long': u2
            instances:
              is_long: {value: 'kind == kinds::long'}
            enums:
              kinds: {1: short, 2: long}
            """)
        #expect(r.error == nil)
        #expect(r.root.at("kind")?.value == "long (0x2)")
        #expect(r.root.at("body")?.number == 0xAABB)
        #expect(r.root.at("is_long")?.value == "true")
    }

    /// TC-3.5
    @Test func bitFields() throws {
        let r = try parse(Data([0b1011_0010, 0b1100_0000]), yaml: """
            meta: {id: t}
            seq:
              - {id: a, type: b1}
              - {id: b, type: b3}
              - {id: c, type: b6}
              - {id: d, type: b6}
            """)
        #expect(r.error == nil)
        #expect(r.root.at("a")?.value == "true")
        #expect(r.root.at("b")?.number == 0b011)
        #expect(r.root.at("c")?.number == 0b0010_11)
        #expect(r.root.at("d")?.number == 0)
    }

    /// TC-3.3: repeat eos / expr / until, instances with pos, size-limited subtypes.
    @Test func repeatsAndInstances() throws {
        let r = try parse(Data([3, 1, 2, 3, 7, 8, 0, 0x42]), yaml: """
            meta: {id: t}
            seq:
              - {id: n, type: u1}
              - {id: items, type: u1, repeat: expr, repeat-expr: n}
              - {id: until_zero, type: u1, repeat: until, repeat-until: _ == 0}
              - {id: rest, type: u1, repeat: eos}
            instances:
              at_last: {pos: 7, type: u1}
            """)
        #expect(r.error == nil)
        #expect(r.root.at("items")?.children.map(\.number) == [1, 2, 3])
        #expect(r.root.at("until_zero")?.children.map(\.number) == [7, 8, 0])
        #expect(r.root.at("rest")?.children.count == 1)
        #expect(r.root.at("at_last")?.number == 0x42)
        #expect(r.root.at("at_last")?.range == 7..<8)
    }

    /// TC-3.4: process routines produce a sub-stream.
    @Test func processRoutines() throws {
        let plain = Array("geheim".utf8)
        let xored = plain.map { $0 ^ 0x5A }
        let rolled = plain.map { ($0 << 3) | ($0 >> 5) }      // rol 3 when writing → ror 3 to read
        let r = try parse(Data([UInt8(xored.count)] + xored + [UInt8(rolled.count)] + rolled), yaml: """
            meta: {id: t}
            seq:
              - {id: len_a, type: u1}
              - {id: a, size: len_a, type: str, encoding: ASCII, process: xor(0x5a)}
              - {id: len_b, type: u1}
              - {id: b, size: len_b, type: str, encoding: ASCII, process: ror(3)}
            """)
        #expect(r.error == nil)
        #expect(r.root.at("a")?.value == "\"geheim\"")
        #expect(r.root.at("b")?.value == "\"geheim\"")
    }

    @Test func validationFails() throws {
        let r = try parse(Data([1, 2]), yaml: """
            meta: {id: t}
            seq:
              - {id: magic, type: u1, valid: 0x7f}
            """)
        #expect(r.error?.message == L("Validation: expected %@, found %@", "127 (0x7F)", "1"))
        #expect(r.error?.path == "magic")
    }

    /// TC-3.7: self-recursive type is stopped by the depth limit, no crash.
    @Test func recursionLimit() throws {
        let r = try parse(Data(count: 2000), yaml: """
            meta: {id: t}
            seq:
              - {id: x, type: u1}
              - {id: next, type: t}
            """)
        #expect(r.error != nil)
    }

    /// TC-3.10: a million plain numbers parse fast and stay out of the tree
    /// until shown (FR-6.13).
    @Test func lazyMillionElementArray() throws {
        var d = Data(le(UInt32(1_000_000)))
        d.reserveCapacity(4 + 2_000_000 + 4096)
        for i in 0 ..< 1_000_000 { d += le(UInt16(truncatingIfNeeded: i * 7)) }
        d += Data((0 ..< 4096).map { UInt8($0 & 0xFF) })        // eos tail of u4be
        let yaml = """
        meta: { id: big, endian: le }
        seq:
          - { id: count, type: u4 }
          - { id: values, type: u2, repeat: expr, repeat-expr: count }
          - { id: tail, type: u4be, repeat: eos }
        instances:
          probe: { value: 'values[123456] + values.size' }
        """
        let start = Date()
        let r = try parse(d, yaml: yaml)
        #expect(Date().timeIntervalSince(start) < 60)   // hang guard only; CI under load is slow
        #expect(r.error == nil)
        #expect(r.nodeCount < 100)
        #expect(r.lazyElementCount == 1_000_000 + 1024)     // #39: values and tail, shown next to the node count
        let values = try #require(r.root.at("values"))
        #expect(values.childCount == 1_000_000 && values.children.isEmpty && values.lazy != nil)
        let e = values.child(123456)
        #expect(e.number == Int64(UInt16(truncatingIfNeeded: 123456 * 7)))
        #expect(e.range == UInt64(4 + 2 * 123456) ..< UInt64(4 + 2 * 123456 + 2))
        #expect(values.lazy?.index(of: 4 + 2 * 999_999 + 1) == 999_999)
        #expect(r.root.at("probe")?.number == Int64(UInt16(truncatingIfNeeded: 123456 * 7)) + 1_000_000)
        let tail = try #require(r.root.at("tail"))
        #expect(tail.childCount == 1024 && tail.child(0).number == 0x00010203)
        // Ids stay unique across lazy elements and later nodes.
        #expect(Set([e.id, tail.id, tail.child(5).id, values.child(0).id]).count == 4)
    }

    @Test func smallAndSpecialArraysStayEager() throws {
        let yaml = """
        meta: { id: small, endian: le }
        seq:
          - { id: few, type: u1, repeat: expr, repeat-expr: 10 }
          - { id: kinds, type: u1, enum: k, repeat: expr, repeat-expr: 2000 }
        enums:
          k: { 0: zero }
        """
        let r = try parse(Data(repeating: 0, count: 2010), yaml: yaml)
        #expect(r.root.at("few")?.lazy == nil && r.root.at("few")?.children.count == 10)
        #expect(r.root.at("kinds")?.lazy == nil && r.root.at("kinds")?.children.count == 2000)
        #expect(r.lazyElementCount == 0)
    }

    /// Nested aliases used to expand to gigabytes in Yams.load (#11).
    @Test func yamlAliasBombIsRejected() throws {
        var yaml = "meta: {id: t}\nx0: &a0 [lol, lol, lol, lol, lol, lol, lol, lol, lol, lol]\n"
        for i in 1 ... 9 {
            yaml += "x\(i): &a\(i) [" + Array(repeating: "*a\(i - 1)", count: 10).joined(separator: ", ") + "]\n"
        }
        let start = Date()
        #expect(throws: KaitaiError.self) { try parse(Data(), yaml: yaml) }
        #expect(Date().timeIntervalSince(start) < 60)   // hang guard only; CI under load is slow
        // Ordinary aliases still work.
        let r = try parse(Data([1, 2]), yaml: """
            meta: {id: t}
            seq:
              - {id: a, type: &t u1}
              - {id: b, type: *t}
            """)
        #expect(r.error == nil && r.root.at("b")?.number == 2)
    }

    /// Deep nesting overflowed the stack, long operator chains took seconds
    /// to lex and overflowed it during evaluation (#10). Runs on a test task
    /// thread (512 KiB stack), like the app's loader used to.
    @Test func hostileExpressionsAreRejectedQuickly() throws {
        let start = Date()
        for text in [String(repeating: "(", count: 1500) + "1" + String(repeating: ")", count: 1500),
                     String(repeating: "(", count: 20_000) + "1" + String(repeating: ")", count: 20_000),
                     String(repeating: "-", count: 20_000) + "1",
                     String(repeating: "not ", count: 20_000) + "true",
                     Array(repeating: "1", count: 30_000).joined(separator: "+")] {
            #expect(throws: KaitaiError.self) { try Expr.parse(text) }
        }
        #expect(Date().timeIntervalSince(start) < 60)   // hang guard only; CI under load is slow
        // Moderate nesting and chains just below the limit still work.
        let ok = String(repeating: "(", count: 20) + "1" + String(repeating: ")", count: 20) + "+"
            + Array(repeating: "2", count: 1899).joined(separator: "+")
        #expect(try value(ok) == "3799 (0xED7)")
    }

    /// Terminator scanning is blockwise now (#29): semantics across the
    /// 64 KiB read-ahead blocks and in processed (in-memory) streams.
    @Test func terminatorSemantics() throws {
        var d = Data(repeating: 0x78, count: 70_000) + [0]            // a: strz across blocks
        d += Data("xyA".utf8) + Data("B".utf8)                         // c, d (not consumed), e
        d += Data([5, 0x10, 0x13, 0x21, 0x99, 0x98])                   // g: xor'ed 5 "12" 0 …
        d += Data("tail".utf8)                                         // f: no 0x7f until eos
        let r = try parse(d, yaml: """
            meta: {id: t}
            seq:
              - {id: a, type: strz, encoding: ASCII}
              - {id: c, terminator: 0x41, include: true}
              - {id: d, terminator: 0x42, consume: false}
              - {id: e, type: u1}
              - {id: g, size: 6, process: xor(0x21), type: inner}
              - {id: f, terminator: 0x7f, eos-error: false}
            types:
              inner:
                seq:
                  - {id: n, type: u1}
                  - {id: s, type: strz, encoding: ASCII}
                  - {id: rest, terminator: 0xff, eos-error: false}
            """)
        #expect(r.error == nil)
        #expect(r.root.at("a")?.range == 0 ..< 70_001)
        #expect(r.root.at("c")?.range == 70_001 ..< 70_004)
        #expect(r.root.at("d")?.range?.isEmpty == true)
        #expect(r.root.at("e")?.number == 0x42)
        #expect(r.root.at("g.n")?.number == 0x24)                   // 5 ^ 0x21
        #expect(r.root.at("g.s")?.value == "\"12\"")
        #expect(r.root.at("g.rest")?.value == "B8 B9")
        #expect(r.root.at("f")?.range == UInt64(d.count - 4) ..< UInt64(d.count))
        let bad = try parse(Data(repeating: 1, count: 100_000), yaml: """
            meta: {id: t}
            seq:
              - {id: s, type: strz, encoding: ASCII}
            """)
        #expect(bad.error?.message == L("Terminator 0x%@ not found", "0"))
    }

    /// A huge file without the terminator: fast, and cancel/deadline apply
    /// during the scan (#29). Before, the scan ran per byte and never checked.
    @Test func terminatorScanIsFastAndCancellable() throws {
        let url = try tempFile(Data(repeating: 0x41, count: 50 << 20) + [0])
        defer { try? FileManager.default.removeItem(at: url) }
        let ksy = FileManager.default.temporaryDirectory.appendingPathComponent("hexwerk-\(UUID().uuidString).ksy")
        try "meta: {id: t}\nseq:\n  - {id: s, type: strz, encoding: ASCII}\n".write(to: ksy, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: ksy) }
        let schema = try KsyLoader().load(ksy)
        let snap = try Document(url: url, readOnly: true).snapshot()

        let cancelled = KaitaiInterpreter.parse(snap, file: schema) { false }
        #expect(cancelled.error?.message == L("Cancelled"))
        var limits = ParseLimits()
        limits.maxSeconds = 0
        let late = KaitaiInterpreter.parse(snap, file: schema, limits: limits)
        #expect(late.error?.message == L("Time limit of %ld s exceeded", 0))

        let start = Date()
        let r = KaitaiInterpreter.parse(snap, file: schema)
        #expect(r.error == nil && r.root.at("s")?.range == 0 ..< UInt64(50 << 20) + 1)
        #expect(Date().timeIntervalSince(start) < 60)   // hang guard only; CI under load is slow
    }

    @Test func nodeLimit() throws {
        let schema = """
            meta: {id: t}
            seq:
              - {id: items, type: item, repeat: eos}
            types:
              item:
                seq:
                  - {id: b, type: u1}
            """
        let ksy = FileManager.default.temporaryDirectory.appendingPathComponent("hexwerk-\(UUID().uuidString).ksy")
        try schema.write(to: ksy, atomically: true, encoding: .utf8)
        let url = try tempFile(Data(count: 5000))
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: ksy) }
        var limits = ParseLimits()
        limits.maxNodes = 1000
        let r = KaitaiInterpreter.parse(try Document(url: url, readOnly: true).snapshot(),
                                        file: try KsyLoader().load(ksy), limits: limits)
        #expect(r.error?.message == L("More than %@ nodes, aborted", "1000"))
        #expect(r.root.at("items")?.children.count == 500)      // 2 nodes per item
    }
}

@Suite struct CatalogTests {
    @Test func indexesFormats() {
        let c = FormatCatalog(root: ksyRoot)
        #expect(c.url(forID: "png") != nil)
        #expect(c.matching(fileExtension: "PNG").map(\.id) == ["png"])
        #expect(c.matching(fileExtension: "gz").map(\.id).contains("gzip"))
    }
}
