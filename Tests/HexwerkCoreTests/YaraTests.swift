import Foundation
import Testing
import HexwerkCore
@testable import HexwerkYARA

/// Compiling runs in process. Scanning does not: wasmtime (inside YARA-X)
/// sets Mach exception ports per thread, which the Apple-signed test runner
/// forbids (EXC_GUARD). Scans therefore go through the built `hexwerk` CLI,
/// which uses the same `YaraRules.scan`.
@Suite struct YaraTests {
    static let rules = """
        rule magic : test { meta: author = "ts" score = 7 strings: $a = "HEXWERK" $b = { DE AD BE EF } condition: $a and $b }
        rule only_condition { condition: uint32be(0) == 0x7F454C46 }
        rule xored { strings: $x = "secret" xor(1-255) condition: $x }
        """

    /// 64 bytes: "HEXWERK" at 10, DEADBEEF at 40, "secret" xor 0x20 at 50.
    static let sample: Data = {
        var d = Data(repeating: 0, count: 64)
        d.replaceSubrange(10 ..< 17, with: Data("HEXWERK".utf8))
        d.replaceSubrange(40 ..< 44, with: Data([0xDE, 0xAD, 0xBE, 0xEF]))
        d.replaceSubrange(50 ..< 56, with: Data("secret".utf8.map { $0 ^ 0x20 }))
        return d
    }()

    @Test func compileReportsErrorsWithLine() throws {
        let src = "rule ok { condition: true }\n\nrule broken {\n  condition: $missing\n}\n"
        let e = try #require(throws: YaraCompileError.self) {
            try YaraRules.compile([YaraSource(origin: "test.yar", text: src)])
        }
        let d = try #require(e.diagnostics.first)
        #expect(d.file == "test.yar")
        #expect(d.line == 4)
        #expect(d.column == 14)
        #expect(!d.report.isEmpty)
        #expect(try YaraRules.compile([YaraSource(origin: "x", text: Self.rules)]).count == 3)
    }

    @Test func lineColumnCountsCharactersNotBytes() {
        #expect(YaraRules.lineColumn("äö\nxü$", byteOffset: 8) == (2, 3))
    }

    @Test func scanFindsPatternsTagsAndMetadata() throws {
        let hits = try scan(Self.sample)
        #expect(hits.map(\.rule).sorted() == ["magic", "xored"])
        let magic = try #require(hits.first { $0.rule == "magic" })
        #expect(magic.namespace == "default")
        #expect(magic.tags == ["test"])
        #expect(magic.metadata == [YaraMeta(key: "author", value: "ts"), YaraMeta(key: "score", value: "7")])
        #expect(magic.matches.map { [$0.pattern, "\($0.offset)", "\($0.length)"] } == [["$a", "10", "7"], ["$b", "40", "4"]])
        let x = try #require(hits.first { $0.rule == "xored" }?.matches.first)
        #expect(x.offset == 50 && x.xorKey == 0x20)
    }

    @Test func conditionOnlyRuleHasNoMatches() throws {
        var d = Self.sample
        d.replaceSubrange(0 ..< 4, with: Data([0x7F, 0x45, 0x4C, 0x46]))
        let hits = try scan(d)
        #expect(hits.contains { $0.rule == "only_condition" && $0.matches.isEmpty })
    }

    // a selection scan reports file offsets.
    @Test func selectionOffsetsAreShifted() throws {
        let hits = try scan(Self.sample, extra: ["--offset", "30", "--length", "34"])
        #expect(hits.map(\.rule) == ["xored"])
        #expect(hits.first?.matches.first?.offset == 50)
        #expect(try scan(Self.sample, extra: ["--offset", "0", "--length", "20"]).isEmpty)
    }

    @Test func timeoutExitsWith3() throws {
        let slow = """
            rule slow { condition: for all i in (0..filesize) : (for all j in (0..filesize) : (uint8(i) != uint8(j) or true)) }
            """
        let start = Date()
        let r = try cli(rules: slow, data: Data(repeating: 1, count: 1 << 20), extra: ["--timeout", "1"])
        #expect(r.status == 3)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func compileErrorExitsWith2() throws {
        let r = try cli(rules: "rule x { condition: $nope }", data: Self.sample, extra: [])
        #expect(r.status == 2)
    }

    // Snapshots hand the scanner the edited content.
    @Test func zeroCopyAndMaterializedAgree() throws {
        let url = try tempFile(Self.sample)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = try Document(url: url)
        let a = doc.snapshot().withContiguousBytes(5 ..< 45) { Data($0) }
        #expect(a == Self.sample[5 ..< 45])
        try doc.overwrite(at: 10, with: Data("hexwerk".utf8))  // splits pieces: copy path
        let b = doc.snapshot().withContiguousBytes(5 ..< 45) { Data($0) }
        var expected = Self.sample
        expected.replaceSubrange(10 ..< 17, with: Data("hexwerk".utf8))
        #expect(b == expected[5 ..< 45])
        #expect(doc.snapshot().withContiguousBytes(64 ..< 64) { $0.count } == 0)
    }

    // MARK: CLI helpers

    private func scan(_ data: Data, extra: [String] = []) throws -> [YaraRuleMatch] {
        let r = try cli(rules: Self.rules, data: data, extra: extra + ["--json"])
        try #require(r.status == 0, "exit \(r.status)")
        return try JSONDecoder().decode([YaraRuleMatch].self, from: r.stdout)
    }

    /// The CLI compiles in its sandboxed child (#129): absolute includes
    /// still resolve, and included files are named as YARA-X names them in
    /// place (relative to the working folder), byte for byte as before.
    @Test func cliIncludesResolveAsInPlace() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let exe = root.appendingPathComponent(".build/debug/hexwerk")
        try #require(FileManager.default.isExecutableFile(atPath: exe.path), "swift build --product hexwerk missing")
        // The real path: YARA-X names included files by it.
        let tmp = try #require(YaraRuleBundle.realPath(FileManager.default.temporaryDirectory.path))
        let dir = URL(fileURLWithPath: tmp).appendingPathComponent("hexwerk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("rules"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("abs/sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ name: String, _ text: String) throws {
            try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try write("abs/sub/x.yar", "rule inc_abs { strings: $h = \"HW\" condition: $h }\n")
        try write("main.yar", "include \"\(dir.path)/abs/sub/x.yar\"\nrule a { condition: true }\n")
        try write("rules/main.yar", "include \"inc.yar\"\nrule r { condition: true }\n")
        try write("rules/inc.yar", "rule bad {\n")
        try write("hw.bin", "HW")
        func run(_ args: [String]) throws -> (Int32, String, String) {
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            p.currentDirectoryURL = dir
            p.environment = ProcessInfo.processInfo.environment.merging(["HEXWERK_LANG": "en"]) { $1 }
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            try p.run()
            let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            return (p.terminationStatus, o, e)
        }
        let (s1, o1, _) = try run(["yara", "main.yar", "hw.bin"])
        #expect(s1 == 0 && o1 == "inc_abs hw.bin\na hw.bin\n")
        let (s2, _, e2) = try run(["yara", "rules", "hw.bin"])
        #expect(s2 == 2)
        // The rule file as named, the same file as an include relative to the working folder.
        #expect(e2.contains(" --> \(dir.path)/rules/inc.yar:2:1\n") && e2.contains(" --> rules/inc.yar:2:1\n"))
        #expect(!e2.contains("yara-"))
    }

    /// "/a/b.yar" is spelled with the same length, so report columns hold.
    @Test func absoluteIncludeSpelling() {
        #expect(YaraRuleBundle.relativeSpelling("/a/b/c.yar") == "a//b/c.yar")
        #expect(YaraRuleBundle.relativeSpelling("/a/b/c.yar").count == "/a/b/c.yar".count)
        #expect(YaraRuleBundle.relativeSpelling("/c.yar") == "c.yar")
        #expect(YaraRuleBundle.relative("/x/y/z", to: "/x") == "y/z")
        #expect(YaraRuleBundle.relative("/x/y/z", to: "/") == "x/y/z")
        #expect(YaraRuleBundle.relative("/xy/z", to: "/x") == "/xy/z")
        #expect(YaraRuleBundle.relative("/x/y", to: nil) == "/x/y")
    }

    private func cli(rules: String, data: Data, extra: [String]) throws -> (status: Int32, stdout: Data) {
        // Tests/HexwerkCoreTests/YaraTests.swift → package root → .build/debug/hexwerk
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let exe = root.appendingPathComponent(".build/debug/hexwerk")
        try #require(FileManager.default.isExecutableFile(atPath: exe.path), "swift build --product hexwerk missing")
        let ruleURL = try tempFile(Data(rules.utf8))
        let dataURL = try tempFile(data)
        defer {
            try? FileManager.default.removeItem(at: ruleURL)
            try? FileManager.default.removeItem(at: dataURL)
        }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["yara", ruleURL.path, dataURL.path] + extra
        p.environment = ProcessInfo.processInfo.environment.merging(["HEXWERK_LANG": "en"]) { $1 }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, stdout)
    }
}
