import Foundation
import Testing
@testable import HexwerkCore
@testable import HexwerkKaitai
import HexwerkScript
@testable import HexwerkYARA

/// Wire formats for the sandboxed helper (#102): what crosses the process
/// boundary must round-trip exactly, and what comes back from a possibly
/// compromised helper must be checked instead of trusted.
@Suite struct WireTests {
    let sample = Data((0 ..< 4096).map { UInt8(truncatingIfNeeded: $0 &* 7) })

    private func document(_ data: Data? = nil) throws -> (Document, URL) {
        let url = try tempFile(data ?? sample)
        return (try Document(url: url), url)
    }

    /// The helper's view of a snapshot: descriptor + wire, as over XPC.
    private func helperSide(_ snap: Snapshot) throws -> (Snapshot, SnapshotWire, AddedMap) {
        let (wire, map) = snap.wire()
        let fh = try #require(snap.fileHandle())
        let source = try ByteSource(fileDescriptor: fh.fileDescriptor, url: snap.fileURL)
        return (try Snapshot(wire: wire, original: source), wire, map)
    }

    // MARK: Wire

    @Test func wireReaderRejectsMalformedInput() throws {
        var w = WireWriter()
        w.int(-5); w.uint(UInt64.max); w.string("hexwerk"); w.range(10 ..< 20); w.double(1.5)
        var r = WireReader(w.data)
        #expect(try r.int() == -5 && r.uint() == UInt64.max && r.string() == "hexwerk")
        #expect(try r.range() == 10 ..< 20 && r.double() == 1.5)
        try r.expectEnd()

        // Every truncation fails cleanly.
        for n in 0 ..< w.data.count {
            var t = WireReader(w.data.prefix(n))
            #expect(throws: WireError.self) {
                _ = try t.int(); _ = try t.uint(); _ = try t.string(); _ = try t.range(); _ = try t.double()
            }
        }
        // Over-long varints, counts the data cannot hold, overflowing ranges.
        var v = WireReader(Data(repeating: 0xFF, count: 11) + [0])
        #expect(throws: WireError.self) { _ = try v.uint() }
        var c = WireReader(Data([0xFF, 0xFF, 0xFF, 0xFF, 0x0F, 1, 2]))
        #expect(throws: WireError.self) { _ = try c.array { try $0.u8() } }
        var o = WireWriter(); o.uint(UInt64.max); o.uint(2)
        var or = WireReader(o.data)
        #expect(throws: WireError.self) { _ = try or.range() }
    }

    // MARK: Snapshot hand-over

    @Test func snapshotWireSendsOnlyReferencedEdits() throws {
        let (doc, url) = try document()
        defer { try? FileManager.default.removeItem(at: url) }
        try doc.overwrite(at: 10, with: Data(repeating: 0xAA, count: 1000))
        doc.undo()  // stays in the added buffer
        try doc.insert(Data("abc".utf8), at: 100)
        try doc.delete(200 ..< 300)
        let (remote, wire, _) = try helperSide(doc.snapshot())
        #expect(wire.added == Data("abc".utf8))
        #expect(remote.count == doc.count)
        #expect(remote.read(0 ..< remote.count) == doc.read(0 ..< doc.count))
        remote.withContiguousBytes(0 ..< 50) { #expect(Data($0) == sample.prefix(50)) }
    }

    @Test func snapshotWireChecksPieces() throws {
        let (doc, url) = try document()
        defer { try? FileManager.default.removeItem(at: url) }
        let snap = doc.snapshot()
        let fh = try #require(snap.fileHandle())
        let source = try ByteSource(fileDescriptor: fh.fileDescriptor, url: url)
        var wire = snap.wire().0
        wire.pieces = [.init(added: false, start: 4000, length: 200)]  // past the file
        wire.count = 200
        #expect(throws: SnapshotWireError.self) { try Snapshot(wire: wire, original: source) }
        wire.pieces = [.init(added: true, start: 0, length: 1)]  // no added bytes
        wire.count = 1
        #expect(throws: SnapshotWireError.self) { try Snapshot(wire: wire, original: source) }
        wire.pieces = [.init(added: false, start: UInt64.max, length: 2)]  // overflow
        wire.count = 2
        #expect(throws: SnapshotWireError.self) { try Snapshot(wire: wire, original: source) }
        wire.pieces = [.init(added: false, start: 0, length: 10)]  // size mismatch
        wire.count = 11
        #expect(throws: SnapshotWireError.self) { try Snapshot(wire: wire, original: source) }
    }

    /// A script's edits made on the helper's copy are adopted as one undo
    /// step and give the same bytes as editing in place.
    @Test func editedContentIsAdoptedLikeTheWorkingCopy() throws {
        let (doc, url) = try document()
        defer { try? FileManager.default.removeItem(at: url) }
        try doc.overwrite(at: 5, with: Data("12345".utf8))
        try doc.insert(Data("xyz".utf8), at: 50)
        let before = doc.read(0 ..< doc.count)
        let base = doc.snapshot()
        let (remote, wire, map) = try helperSide(base)

        let copy = Document(editing: remote)
        let edits = { (d: Document) in
            try d.overwrite(at: 7, with: Data("AB".utf8))  // inside an edited piece
            try d.delete(51 ..< 52)  // splits the inserted piece
            try d.insert(Data("new".utf8), at: 0)
            try d.overwrite(at: 3000, with: Data([1, 2, 3]))
        }
        try copy.grouped { try edits(copy) }
        let edited = copy.editedContent(sentAddedCount: wire.added.count)
        #expect(edited.newBytes == Data("ABnew".utf8) + Data([1, 2, 3]))

        let expected = Document(editing: base)
        try expected.grouped { try edits(expected) }
        try doc.adopt(edited, map: map, base: base)
        #expect(doc.read(0 ..< doc.count) == expected.read(0 ..< expected.count))
        doc.undo()
        #expect(doc.read(0 ..< doc.count) == before)

        // The helper's answer is checked, not trusted.
        let bad = EditedContent(pieces: [.init(added: true, start: 0, length: 1000)], newBytes: Data())
        #expect(throws: SnapshotWireError.self) { try doc.adopt(bad, map: map, base: base) }
        // And the document must not have changed meanwhile.
        try doc.insert(Data([0]), at: 0)
        #expect(throws: DocumentError.self) { try doc.adopt(edited, map: map, base: base) }
    }

    // MARK: Results

    static let ksy = """
        meta:
          id: wiretest
          endian: le
        seq:
          - id: magic
            contents: [0x48, 0x57]
          - id: n
            type: u2
          - id: recs
            type: rec
            repeat: expr
            repeat-expr: n
          - id: ints
            type: u4
            repeat: expr
            repeat-expr: 1100
          - id: floats
            type: f4
            repeat: expr
            repeat-expr: 1100
          - id: tail
            type: u4
        types:
          rec:
            seq:
              - id: a
                type: u1
              - id: s
                type: str
                size: 3
                encoding: ASCII
        """

    static var ksyData: Data {
        var d = Data([0x48, 0x57, 3, 0])
        for i in 0 ..< 3 { d += [UInt8(i)] + Data("ab\(i)".utf8) }
        for i in 0 ..< 1100 { withUnsafeBytes(of: UInt32(i * 1000).littleEndian) { d += $0 } }
        for i in 0 ..< 1100 { withUnsafeBytes(of: Float(i).bitPattern.littleEndian) { d += $0 } }
        return d + [1, 2]  // tail is cut short: an error
    }

    static func lines(_ r: ParseResult) -> [String] {
        var out = ["\(r.nodeCount) \(r.lazyElementCount) \(r.error?.description ?? "-")"]
        func add(_ n: ParseNode, _ depth: Int) {
            out.append(
                "\(depth) \(n.id) \(n.name) \(n.typeName) \(n.value ?? "-") \(String(describing: n.range)) \(n.error ?? "-") \(String(describing: n.number))"
            )
            for c in n.allChildren { add(c, depth + 1) }
        }
        add(r.root, 0)
        return out
    }

    @Test func parseResultRoundTrips() throws {
        let r = try parse(Self.ksyData, yaml: Self.ksy)
        #expect(r.error != nil && r.lazyElementCount == 2200)
        let data = r.encoded()
        let back = try onLargeStack { Result { try ParseResult(encoded: data) } }.get()
        #expect(Self.lines(back) == Self.lines(r))
        #expect(back.root.children.first { $0.name == "ints" }?.lazy?.index(of: 16 + 8) == 2)
        // Truncated or corrupted replies throw.
        for n in stride(from: 0, to: data.count, by: max(1, data.count / 300)) {
            #expect(throws: (any Error).self) { try onLargeStack { Result { try ParseResult(encoded: data.prefix(n)) } }.get() }
        }
    }

    @Test func scanOutcomeRoundTrips() throws {
        let d = YaraDiagnostic(file: "/r.yar", line: 3, column: 4, code: "E1", message: "m", report: "rep")
        let hits = [
            YaraRuleMatch(
                rule: "r", namespace: "default", tags: ["t"], metadata: [YaraMeta(key: "k", value: "v")],
                matches: [
                    YaraPatternMatch(pattern: "$a", offset: 1 << 40, length: 4, xorKey: 3),
                    YaraPatternMatch(pattern: "$b", offset: 7, length: 0, xorKey: nil),
                ])
        ]
        guard case .hits(let h, let w) = try YaraScanOutcome(encoded: YaraScanOutcome.hits(hits, warnings: [d]).encoded()) else {
            Issue.record("wrong case"); return
        }
        #expect(h == hits && w.map(\.report) == ["rep"] && w.first?.line == 3)
        guard case .failed(let m, _) = try YaraScanOutcome(encoded: YaraScanOutcome.failed("boom", warnings: []).encoded()) else {
            Issue.record("wrong case"); return
        }
        #expect(m == "boom")
        #expect(throws: WireError.self) { try YaraScanOutcome(encoded: Data([9])) }
    }

    /// Include statements are followed by the app, and compiling from the
    /// helper's private copy reports the original paths.
    @Test func ruleBundleResolvesIncludes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hexwerk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("lib"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"include "lib/common.yar""#.appending("\nrule main { condition: common }\n")
            .write(to: dir.appendingPathComponent("main.yar"), atomically: true, encoding: .utf8)
        try "rule common { condition: true }\n".write(to: dir.appendingPathComponent("lib/common.yar"), atomically: true, encoding: .utf8)
        let bundle = try YaraRuleBundle.collect(files: [dir.appendingPathComponent("main.yar")])
        #expect(bundle.includes.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["common.yar"])
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hexwerk-\(UUID().uuidString)")
        #expect(try bundle.compile(materializingIn: tmp).count == 2)
        #expect(!FileManager.default.fileExists(atPath: tmp.path))

        try "rule broken { condition: $x }\n".write(to: dir.appendingPathComponent("lib/common.yar"), atomically: true, encoding: .utf8)
        let broken = try YaraRuleBundle.collect(files: [dir.appendingPathComponent("main.yar")])
        let e = try #require(throws: YaraCompileError.self) { try broken.compile(materializingIn: tmp) }
        #expect(e.diagnostics.contains { $0.file?.hasSuffix("/lib/common.yar") == true && !$0.file!.contains(tmp.lastPathComponent) })
    }
}
