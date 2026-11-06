import Foundation
import Testing
@testable import HexwerkCore
@testable import HexwerkKaitai
import HexwerkScript

// Mutation-based fuzz tests for the hostile-input surfaces.
//
// Apple's toolchains ship no libFuzzer runtime, so these are plain Swift
// Testing tests with a seeded generator. A thrown error is fine (that is how
// hostile input is supposed to be rejected); a trap, a crash or a hang is a
// failure.
//
//   HEXWERK_FUZZ_ITERATIONS  iterations per target (default: small, so a normal
//                            `swift test` stays fast)
//   HEXWERK_FUZZ_SCALE       multiplies each target's default instead (targets
//                            differ a lot in speed); used by the nightly run
//   HEXWERK_FUZZ_SEED        base seed (decimal, 0x hex or "random"); iteration i
//                            uses seed base + i
//   HEXWERK_FUZZ_VERBOSE     print why each rejected input was rejected
//   HEXWERK_FUZZ_TIMEOUT     seconds one iteration may take before it counts as
//                            a hang (default 30)
//
// Reproduce a reported case with the seed and one iteration, e.g.
//   HEXWERK_FUZZ_SEED=1234 HEXWERK_FUZZ_ITERATIONS=1 swift test --filter FuzzTests/hexRecords

/// SplitMix64: tiny, fast and identical on every platform.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension SplitMix64 {
    mutating func int(_ range: Range<Int>) -> Int { Int.random(in: range, using: &self) }
    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &self) }
    mutating func chance(_ p: Double) -> Bool { Double.random(in: 0 ..< 1, using: &self) < p }
    mutating func pick<T>(_ a: [T]) -> T { a[int(0 ..< a.count)] }
    mutating func bytes(_ n: Int) -> [UInt8] { (0 ..< n).map { _ in UInt8.random(in: 0 ... 255, using: &self) } }
}

/// What is running right now, as a C string, for the crash handler.
nonisolated(unsafe) private let fuzzCurrent = UnsafeMutablePointer<CChar>.allocate(capacity: 512)

enum Fuzz {
    static let env = ProcessInfo.processInfo.environment

    static let iterationsOverride: Int? = env["HEXWERK_FUZZ_ITERATIONS"].flatMap { Int($0) }
    static let scale: Int = env["HEXWERK_FUZZ_SCALE"].flatMap { Int($0) } ?? 1

    static let baseSeed: UInt64 = {
        switch env["HEXWERK_FUZZ_SEED"] {
        case "random"?: return UInt64.random(in: 0 ... UInt64.max >> 1)
        case let s? where s.hasPrefix("0x"): return UInt64(s.dropFirst(2), radix: 16) ?? 0x4845_5857
        case let s?: return UInt64(s) ?? 0x4845_5857
        case nil: return 0x4845_5857  // "HEXW": fixed, so plain `swift test` is deterministic
        }
    }()

    /// HEXWERK_FUZZ_VERBOSE=1 prints every rejection (to tune the generators).
    static let verbose = env["HEXWERK_FUZZ_VERBOSE"] != nil

    static let timeout: Double = env["HEXWERK_FUZZ_TIMEOUT"].flatMap { Double($0) } ?? 30

    /// Installs handlers once that print the running case before the process
    /// dies on a trap or fault, then hand over to the previous handler (ASan's,
    /// or the default one).
    static let installCrashHandler: Void = {
        fuzzCurrent[0] = 0
        for sig in [SIGTRAP, SIGILL, SIGSEGV, SIGBUS, SIGABRT, SIGFPE] {
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = { sig, _, _ in
                let prefix = "\n*** hexwerk fuzz: crash while running: "
                _ = prefix.withCString { write(2, $0, strlen($0)) }
                _ = write(2, fuzzCurrent, strlen(fuzzCurrent))
                _ = write(2, "\n", 1)
                fuzzPrevious(sig)
            }
            action.sa_flags = SA_SIGINFO | SA_ONSTACK
            sigemptyset(&action.sa_mask)
            var old = sigaction()
            sigaction(sig, &action, &old)
            fuzzOld[Int(sig)] = old
        }
    }()

    /// Runs `body` `iterations` times (or HEXWERK_FUZZ_ITERATIONS), each with
    /// its own seeded generator, on a large-stack thread with a time limit.
    static func run(
        _ target: String, iterations: Int,
        _ body: @escaping (inout SplitMix64) throws -> Void
    ) {
        _ = installCrashHandler
        let n = iterationsOverride ?? iterations * scale
        let started = Date()
        var rejected = 0
        for i in 0 ..< n {
            let seed = baseSeed &+ UInt64(i)
            let repro = "target \(target), HEXWERK_FUZZ_SEED=\(seed) HEXWERK_FUZZ_ITERATIONS=1 swift test --filter FuzzTests/\(target)"
            _ = repro.withCString { strlcpy(fuzzCurrent, $0, 512) }
            guard let threw = runOne(seed: seed, body) else {
                Issue.record("hang (> \(timeout) s) in \(repro)")
                return  // the stuck thread cannot be stopped; leave it
            }
            if threw { rejected += 1 }
        }
        fuzzCurrent[0] = 0
        print(
            "fuzz \(target): \(n) iterations (\(rejected) rejected with an error) from seed \(baseSeed) in "
                + String(format: "%.1f s", Date().timeIntervalSince(started)))
    }

    private final class Job: @unchecked Sendable {
        let body: (inout SplitMix64) throws -> Void
        let seed: UInt64
        let done = DispatchSemaphore(value: 0)
        var threw = false
        init(_ seed: UInt64, _ body: @escaping (inout SplitMix64) throws -> Void) { self.seed = seed; self.body = body }
    }

    /// Whether the iteration threw; nil if it did not finish within `timeout`.
    private static func runOne(seed: UInt64, _ body: @escaping (inout SplitMix64) throws -> Void) -> Bool? {
        let job = Job(seed, body)
        let thread = Thread {
            // A signal stack, so a stack overflow still reaches the handler.
            // Only if the thread has none: ASan installs its own and unmaps
            // whatever is current when the thread exits.
            var current = stack_t()
            sigaltstack(nil, &current)
            let own = current.ss_flags & SS_DISABLE != 0 ? malloc(1 << 16) : nil
            if let own {
                var alt = stack_t(ss_sp: own, ss_size: 1 << 16, ss_flags: 0)
                sigaltstack(&alt, nil)
            }
            defer {
                if let own {
                    var off = stack_t(ss_sp: nil, ss_size: 0, ss_flags: SS_DISABLE)
                    sigaltstack(&off, nil)
                    free(own)
                }
            }
            var rng = SplitMix64(seed: job.seed)
            do { try job.body(&rng) } catch {
                job.threw = true
                if verbose { print("  seed \(job.seed): \(error)") }
            }
            job.done.signal()
        }
        thread.stackSize = 64 << 20
        thread.start()
        guard job.done.wait(timeout: .now() + timeout) == .success else { return nil }
        return job.threw
    }

    // MARK: Mutators

    static let interestingInts: [UInt64] = [
        0, 1, 2, 0x7F, 0x80, 0xFF, 0x100, 0x7FFF, 0x8000, 0xFFFF, 0x10000, 0x7FFF_FFFF, 0x8000_0000,
        0xFFFF_FFFF, 0x1_0000_0000, 0x7FFF_FFFF_FFFF_FFFF, 0x8000_0000_0000_0000, .max, .max - 1,
    ]

    /// 1–8 random byte-level mutations (bit flips, interesting values,
    /// inserts, deletes, duplicated chunks).
    static func mutate(_ input: [UInt8], _ r: inout SplitMix64, maxSize: Int = 1 << 16) -> [UInt8] {
        var d = input
        for _ in 0 ..< r.int(1 ... 8) {
            switch r.int(0 ..< 8) {
            case 0 where !d.isEmpty:
                let i = r.int(0 ..< d.count); d[i] ^= 1 << UInt8(r.int(0 ..< 8))
            case 1 where !d.isEmpty:
                d[r.int(0 ..< d.count)] = r.pick([0, 0xFF, 0x7F, 0x80, 0x01, 0x20, 0x0A])
            case 2 where !d.isEmpty:
                let width = r.pick([1, 2, 4, 8])
                let at = r.int(0 ..< d.count)
                let v = r.pick(interestingInts)
                let big = r.chance(0.5)
                for k in 0 ..< width where at + k < d.count {
                    let shift = UInt64(8 * (big ? width - 1 - k : k))
                    d[at + k] = UInt8(truncatingIfNeeded: v >> shift)
                }
            case 3 where d.count < maxSize:
                d.insert(contentsOf: r.bytes(r.int(1 ... 16)), at: r.int(0 ... d.count))
            case 4 where !d.isEmpty:
                let a = r.int(0 ..< d.count), len = min(r.int(1 ... 64), d.count - a)
                d.removeSubrange(a ..< a + len)
            case 5 where !d.isEmpty && d.count < maxSize:
                let a = r.int(0 ..< d.count), len = min(r.int(1 ... 256), d.count - a)
                d.insert(contentsOf: d[a ..< a + len], at: r.int(0 ... d.count))
            case 6 where !d.isEmpty:
                d.removeSubrange(r.int(0 ..< d.count)...)  // truncate
            default:
                d[d.count / 2 ..< d.count / 2].append(contentsOf: r.bytes(r.int(0 ... 8)))
            }
        }
        return d.count > maxSize ? Array(d.prefix(maxSize)) : d
    }

    /// Text mutations that keep it mostly YAML-shaped: line edits, number
    /// and word replacements, YAML syntax fragments, raw byte mutations.
    static func mutateText(_ text: String, _ r: inout SplitMix64) -> String {
        var lines = text.components(separatedBy: "\n")
        let words = Array(Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).map(String.init)))
        // Mostly structure-preserving edits (numbers, words), so many mutants
        // still load and reach the interpreter; sometimes structural damage.
        for _ in 0 ..< r.int(1 ... 3) {
            guard !lines.isEmpty else { lines = [""]; continue }
            let i = r.int(0 ..< lines.count)
            switch r.int(0 ..< 20) {
            case 0 ..< 7:  // replace numbers on a line that has some
                var j = i
                for _ in 0 ..< 8 where !lines[j].contains(where: \.isNumber) { j = r.int(0 ..< lines.count) }
                lines[j] = lines[j].replacingOccurrences(of: #"\b\d+\b"#, with: r.pick(numbers), options: .regularExpression)
            case 7 ..< 13 where !words.isEmpty:  // replace a word with another one from the file or a keyword
                let w = r.pick(words)
                lines[i] = lines[i].replacingOccurrences(of: w, with: r.pick(words + keywords))
            case 13: lines.remove(at: i)
            case 14: lines.insert(lines[i], at: r.int(0 ... lines.count))
            case 15: lines.swapAt(i, r.int(0 ..< lines.count))
            case 16: lines.insert(String(repeating: " ", count: r.int(0 ... 8)) + r.pick(yamlFragments), at: i)
            case 17: lines[i] = String(repeating: " ", count: r.int(0 ... 12)) + lines[i].trimmingCharacters(in: .whitespaces)
            case 18: lines[i] += r.pick(yamlFragments)
            default:
                let mutated = mutate(Array(lines[i].utf8), &r, maxSize: 4096)
                lines[i] = String(decoding: mutated, as: UTF8.self)
            }
        }
        return lines.joined(separator: "\n")
    }

    static let numbers = [
        "0", "-1", "1", "255", "65536", "2147483648", "4294967296", "9223372036854775807",
        "9223372036854775808", "18446744073709551616", "-9223372036854775808", "1e308",
        "0x7fffffffffffffff", "0xffffffffffffffff", "99999999999999999999999",
    ]

    static let keywords = [
        "meta", "id", "seq", "types", "instances", "enums", "type", "size", "repeat", "repeat-expr",
        "repeat-until", "eos", "expr", "until", "pos", "io", "value", "if", "contents", "process",
        "encoding", "terminator", "consume", "include", "eos-error", "pad-right", "endian",
        "switch-on", "cases", "imports", "valid", "enum", "u1", "u2", "u4", "u8", "s1", "s2",
        "s4", "s8", "f4", "f8", "b1", "b7", "b64", "str", "strz", "u4be", "s8le", "bits",
        "_io", "_root", "_parent", "_index", "_", "size-eos", "doc", "xor(0xff)", "zlib",
        "rotate_left(3)", "UTF-8", "UTF-16LE", "ASCII", "be", "le", "true", "false", "null",
    ]

    static let yamlFragments = [
        "- ", ": ", "&a ", "*a", "[", "]", "{", "}", "!!binary aGV4", "!!int", "? ", "|",
        ">-", "\t", "#", "'", "\"", "\\", "- id: x", "  type: u4", "size: -1", "repeat: eos",
        "<<: *a", "...", "---", "%YAML 1.1", "\u{0}", "\u{FEFF}", "~", ".inf", ".nan",
        "type: x", "types: {x: {seq: [{id: y, type: x}]}}", "instances: {i: {value: i}}",
        "size: _io.size * 1000000", "pos: -1", "repeat-expr: 1000000000",
    ]
}

nonisolated(unsafe) private var fuzzOld = Array(repeating: Darwin.sigaction(), count: 64)

/// Restores the previous handler and lets it see the signal.
private func fuzzPrevious(_ sig: Int32) {
    var old = fuzzOld[Int(sig)]
    sigaction(sig, &old, nil)
    // Faults re-execute the faulting instruction and land in the old handler;
    // SIGABRT/explicit raises need raising again.
    if sig == SIGABRT { raise(sig) }
}

// MARK: - Shared inputs

/// .ksy fixtures, loaded once (the loader resolves imports via ksyRoot).
private let fuzzKsyURLs: [URL] = {
    let e = FileManager.default.enumerator(at: ksyRoot, includingPropertiesForKeys: nil)
    return (e?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "ksy" }.sorted { $0.path < $1.path }
}()

/// Plausible starts of files for each fixture format, so mutations reach
/// past the magic checks.
private func seedInput(for id: String, _ r: inout SplitMix64) -> [UInt8] {
    var tail = r.bytes(r.int(0 ... 512))
    func put(_ at: Int, _ v: [UInt8]) {
        if tail.count < at + v.count { tail += [UInt8](repeating: 0, count: at + v.count - tail.count) }
        tail.replaceSubrange(at ..< at + v.count, with: v)
    }
    switch id {
    case "elf": put(0, [0x7F, 0x45, 0x4C, 0x46, UInt8(r.int(1 ... 2)), UInt8(r.int(1 ... 2)), 1, 0])
    case "microsoft_pe":
        put(0, Array("MZ".utf8)); put(0x3C, [0x80, 0, 0, 0]); put(0x80, Array("PE\0\0".utf8))
        put(0x84, [0x64, 0x86, 1, 0]); put(0x94, [0xF0, 0, 0x22, 0]); put(0x98, [0x0B, 2])
    case "zip": put(0, [0x50, 0x4B, 3, 4, 20, 0])
    case "gzip": put(0, [0x1F, 0x8B, 8, UInt8(r.int(0 ... 31))])
    case "png": tail = Array(image(.png, width: r.int(1 ... 8), height: r.int(1 ... 8)))
    case "gif": tail = Array(image(.gif, width: r.int(1 ... 8), height: r.int(1 ... 8)))
    case "bmp": tail = Array(image(.bmp, width: r.int(1 ... 8), height: r.int(1 ... 8)))
    case "wav", "riff": put(0, Array("RIFF".utf8) + [0xFF, 0, 0, 0] + Array("WAVEfmt ".utf8) + [16, 0, 0, 0, 1, 0, 2, 0])
    case "pcap": put(0, [0xD4, 0xC3, 0xB2, 0xA1, 2, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0, 0, 1, 0, 0, 0])
    case "ext2": put(1024 + 56, [0x53, 0xEF])
    case "ipv4_packet": put(0, [0x45, 0, 0, 40])
    case "ipv6_packet": put(0, [0x60, 0, 0, 0, 0, 20, 6, 64])
    case "exif": put(0, Array("II*\0".utf8) + [8, 0, 0, 0, 2, 0])
    default: break
    }
    return tail
}

private let fuzzLimits: ParseLimits = {
    var l = ParseLimits()
    l.maxSeconds = 5
    l.maxNodes = 200_000
    return l
}()

/// A throwaway file with `bytes`, parsed as a snapshot.
private func withSnapshot<R>(_ bytes: [UInt8], _ body: (Snapshot) throws -> R) throws -> R {
    let url = try tempFile(Data(bytes))
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(try Document(url: url, readOnly: true).snapshot())
}

private func writeTempKsy(_ text: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hexwerk-fuzz-\(UUID().uuidString).ksy")
    try Data(text.utf8).write(to: url)
    return url
}

/// Walks the whole tree, including lazy arrays (the views do the same).
private func touch(_ n: ParseNode, depth: Int = 0) {
    _ = n.value
    guard depth < 64 else { return }
    for i in 0 ..< min(n.childCount, 256) { touch(n.child(i), depth: depth + 1) }
}

// MARK: - Targets

@Suite(.serialized) struct FuzzTests {
    /// Mutated fixture .ksy files; schemas that still load parse random data.
    @Test func ksyLoading() throws {
        let texts = try fuzzKsyURLs.map { try String(contentsOf: $0, encoding: .utf8) }
        try #require(!texts.isEmpty)
        Fuzz.run("ksyLoading", iterations: 40) { r in
            let text = Fuzz.mutateText(r.pick(texts), &r)
            let url = try writeTempKsy(text)
            defer { try? FileManager.default.removeItem(at: url) }
            let file = try KsyLoader(libraryRoots: [ksyRoot]).load(url)
            let result = try withSnapshot(r.bytes(r.int(0 ... 2048))) {
                KaitaiInterpreter.parse($0, file: file, limits: fuzzLimits)
            }
            touch(result.root)
        }
    }

    /// Random YAML built from Kaitai keys and hostile values.
    @Test func randomYAML() {
        Fuzz.run("randomYAML", iterations: 60) { r in
            func value(_ depth: Int) -> String {
                if depth > 3 || r.chance(0.5) {
                    return r.pick(
                        Fuzz.keywords + Fuzz.numbers + [
                            "\"\"", "'x'", "[]", "{}", "~", "_io.size - 1",
                            "a.b.c", "(1", "x ? y : z", "-", "[1, [2, [3]]]",
                        ])
                }
                if r.chance(0.5) {
                    return "[" + (0 ..< r.int(0 ... 3)).map { _ in value(depth + 1) }.joined(separator: ", ") + "]"
                }
                return "{"
                    + (0 ..< r.int(0 ... 4)).map { _ in "\(r.pick(Fuzz.keywords)): \(value(depth + 1))" }
                    .joined(separator: ", ") + "}"
            }
            var yaml = "meta: {id: fz, endian: \(r.pick(["le", "be", "x", "{switch-on: a, cases: {}}"]))}\n"
            for key in ["seq", "types", "instances", "enums"] where r.chance(0.7) {
                if key == "seq" {
                    yaml +=
                        "seq:\n"
                        + (0 ..< r.int(0 ... 4)).map { _ in
                            "  - "
                                + (0 ..< r.int(1 ... 4)).map { _ in "\(r.pick(Fuzz.keywords)): \(value(1))" }
                                .joined(separator: "\n    ")
                        }.joined(separator: "\n") + "\n"
                } else {
                    yaml += "\(key): \(value(0))\n"
                }
            }
            if r.chance(0.2) { yaml = Fuzz.mutateText(yaml, &r) }
            let url = try writeTempKsy(yaml)
            defer { try? FileManager.default.removeItem(at: url) }
            let file = try KsyLoader().load(url)
            touch(
                try withSnapshot(r.bytes(r.int(0 ... 256))) {
                    KaitaiInterpreter.parse($0, file: file, limits: fuzzLimits)
                }.root)
        }
    }

    static let exprTokens = [
        "_io", "_root", "_parent", "_index", "_io.size", "_io.pos", "_io.eof", "a", "b", "s", "arr", "x", "y",
        "e::one", "e::two", "size", "length", "to_s", "to_i", "reverse", "substring", "first", "last", "min",
        "max", "as<u4>", "as<str>", "sizeof<u8>", "bitsizeof<b3>", "sizeof", "true", "false", "not", "and", "or",
        "0", "1", "-1", "7", "0x7fffffffffffffff", "0xffffffffffffffff", "9223372036854775808", "-9223372036854775808",
        "0b1011", "0o777", "1.5", "1e308", "-0.0", "'str'", "\"a\\x00\"", "\"\\u0041\"", "'", "\"", "[1, 2, 255]",
        "+", "-", "*", "/", "%", "<<", ">>", "&", "|", "^", "~", "!", "==", "!=", "<", "<=", ">", ">=",
        "?", ":", ".", "::", "[", "]", "(", ")", ",", "64", "63", "65", "-64", "1 << 63", "(1 << 62) * 4",
    ]

    /// A random, mostly well-formed Kaitai expression.
    static func genExpr(_ r: inout SplitMix64, _ depth: Int = 0) -> String {
        if depth > 3 || r.chance(0.4) {
            return r.pick([
                "a", "b", "s", "arr", "x", "y", "_io.size", "_io.pos", "_io.eof", "_index", "_root.a",
                "_parent", "e::one", "e::two", "true", "false", "'str'", "\"a\\x00\"", "[1, 2, 255]", "[]",
                "0", "1", "-1", "7", "8", "63", "64", "65", "255", "0x7fffffffffffffff", "0xffffffffffffffff",
                "-9223372036854775808", "0b1011", "0o777", "1.5", "1e308", "-0.0", "sizeof<u8>",
                "a.as<u4>", "arr.size",
            ])
        }
        func e() -> String { genExpr(&r, depth + 1) }
        switch r.int(0 ..< 7) {
        case 0: return r.chance(0.3) ? "(not \(e()))" : r.pick(["-", "~"]) + e()
        case 1, 2:
            return
                "(\(e()) \(r.pick(["+", "-", "*", "/", "%", "<<", ">>", "&", "|", "^", "==", "!=", "<", "<=", ">", ">=", "and", "or"])) \(e()))"
        case 3: return "(\(e()) ? \(e()) : \(e()))"
        case 4: return "\(e()).\(r.pick(["to_s", "to_i", "length", "size", "reverse", "first", "last", "min", "max", "as<u2>", "as<str>"]))"
        case 5: return "\(e())[\(e())]"
        default: return "\(e()).substring(\(e()), \(e()))"
        }
    }

    /// Random expressions (grammar-based, token soup, and mutated) through
    /// the expression parser.
    @Test func expressionParsing() {
        Fuzz.run("expressionParsing", iterations: 3000) { r in
            var text: String
            if r.chance(0.3) {
                text = (0 ..< r.int(1 ... 24)).map { _ in r.pick(Self.exprTokens) }.joined(separator: r.pick([" ", ""]))
            } else {
                text = Self.genExpr(&r)
                if r.chance(0.3) { text = String(decoding: Fuzz.mutate(Array(text.utf8), &r, maxSize: 4096), as: UTF8.self) }
            }
            _ = try Expr.parse(text)
        }
    }

    /// Random expressions evaluated by the interpreter (size, if, pos, value).
    @Test func expressionEvaluation() {
        Fuzz.run("expressionEvaluation", iterations: 150) { r in
            func expr() -> String { Self.genExpr(&r) }
            func block(_ e: String) -> String { "|-\n      " + e }
            let yaml = """
                meta:
                  id: fz
                  endian: \(r.pick(["le", "be"]))
                seq:
                  - id: a
                    type: u1
                  - id: b
                    type: u4
                  - id: s
                    size: 4
                  - id: arr
                    type: u2
                    repeat: expr
                    repeat-expr: 3
                  - id: c
                    size: \(block(expr()))
                    if: \(block(expr()))
                enums:
                  e:
                    1: one
                    2: two
                instances:
                  x:
                    value: \(block(expr()))
                  y:
                    pos: \(block(expr()))
                    type: u1
                  z:
                    value: \(block(expr()))
                """
            let url = try writeTempKsy(yaml)
            defer { try? FileManager.default.removeItem(at: url) }
            let file = try KsyLoader().load(url)
            touch(
                try withSnapshot(r.bytes(r.int(0 ... 64))) {
                    KaitaiInterpreter.parse($0, file: file, limits: fuzzLimits)
                }.root)
        }
    }

    /// Fixture formats against mutated plausible inputs.
    @Test func kaitaiParsing() throws {
        let loader = KsyLoader(libraryRoots: [ksyRoot])
        let files = try fuzzKsyURLs.map { try loader.load($0) }
        Fuzz.run("kaitaiParsing", iterations: 150) { r in
            let file = r.pick(files)
            let input = r.chance(0.1) ? r.bytes(r.int(0 ... 4096)) : Fuzz.mutate(seedInput(for: file.id, &r), &r)
            touch(try withSnapshot(input) { KaitaiInterpreter.parse($0, file: file, limits: fuzzLimits) }.root)
        }
    }

    /// Intel HEX and S-Records with valid checksums, then mutated text.
    @Test func hexRecords() {
        Fuzz.run("hexRecords", iterations: 1500) { r in
            func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }
            var lines: [String] = []
            let intel = r.chance(0.5)
            for _ in 0 ..< r.int(0 ... 12) {
                var data = r.bytes(r.int(0 ... 20))
                if intel {
                    let type = UInt8(r.pick([0, 0, 0, 1, 2, 3, 4, 5, r.int(0 ... 255)]))
                    if [2, 4].contains(type), r.chance(0.8) { data = r.bytes(2) }
                    if [3, 5].contains(type), r.chance(0.8) { data = r.bytes(4) }
                    var b = [UInt8(truncatingIfNeeded: data.count)] + r.bytes(2) + [type] + data
                    b.append(0 &- b.reduce(0, &+))
                    lines.append(":" + hex(b))
                } else {
                    let type = r.pick([0, 1, 2, 3, 5, 6, 7, 8, 9, r.int(0 ... 9)])
                    let addrLen = [0: 2, 1: 2, 5: 2, 9: 2, 2: 3, 6: 3, 8: 3, 3: 4, 7: 4][type] ?? 2
                    var b = [UInt8(truncatingIfNeeded: addrLen + data.count + 1)] + r.bytes(addrLen) + data
                    b.append(b.reduce(0, &+) ^ 0xFF)
                    lines.append("S\(type)" + hex(b))
                }
            }
            var text = lines.joined(separator: r.pick(["\n", "\r\n", "\r", "\u{2028}"]))
            if r.chance(0.5) { text = String(decoding: Fuzz.mutate(Array(text.utf8), &r), as: UTF8.self) }
            let image = try HexRecords.parse(text)
            _ = image.gaps
            _ = image.base
            _ = try image.flatten(maxSize: 1 << 20)
        }
    }

    /// Every inspector row with hostile strings.
    @Test func inspectorEncode() {
        let rows = Inspector.values(Data(repeating: 0, count: Inspector.window), endian: .little).map(\.name)
        let pieces = [
            "-", "+", "0x", "0b", "0o", "1", "9", "F", "e", "E", ".", ":", "T", "Z", "{", "}", "\"", "'",
            " ", "\u{0}", "ü", "😀", "\u{301}", "nan", "inf", "-0", "9223372036854775808", "18446744073709551616",
            "-9223372036854775809", "1e400", "-1e-400", "0x8000000000000000", "9999-12-31T23:59:59Z",
            "0000-01-01T00:00:00Z", "-292277026596-12-04T15:30:08Z", "2026-11-06 09:30:42", "24:60:61",
            "1980-00-00 00:00:00", "{01234567-89AB-CDEF-0123-456789ABCDEF}", "01234567-89AB", "\\",
            String(repeating: "9", count: 400), String(repeating: "1", count: 70), "-" + String(repeating: "0", count: 100),
        ]
        Fuzz.run("inspectorEncode", iterations: 3000) { r in
            let name = r.pick(rows)
            let text = (0 ..< r.int(0 ... 6)).map { _ in r.pick(pieces) }.joined()
            let endian = r.pick(Endian.allCases)
            _ = Inspector.unquoteForEdit(text, name: name)
            _ = Inspector.values(Data(r.bytes(r.int(0 ... Inspector.window))), endian: endian)
            let bytes = try Inspector.encode(name, text, endian: endian)
            _ = Inspector.values(bytes, endian: endian)
        }
    }

    static let jsValues = [
        "0", "-1", "-0", "1", "NaN", "Infinity", "-Infinity", "1e308", "2**31", "2**32", "2**53", "2**53+2", "2**63",
        "2**64", "-(2**63)", "0.5", "-0.5", "'0'", "'abc'", "''", "null", "undefined", "{}", "[]", "[1,2,300]", "[-1]",
        "[NaN]", "[0.5]", "['a']", "[,,1]", "new Uint8Array(4)", "new Uint8Array(70000)", "new Float64Array([1e300])",
        "'x'.repeat(5000)", "true", "123n", "-1n", "2n**64n", "Symbol()", "({valueOf(){throw 1}})",
        "({valueOf(){return 1e20}})", "({length: 1e9})", "({length: -1})", "({length: 2**32})", "hw.size()",
        "hw.size()-1", "hw.size()+1", "'?? ?? ??'", "'DE AD ?'", "'ZZ'", "' '", "'\\u0000'", "'??'", "'0x'",
        "new Proxy({}, {get(){throw 1}})", "new Proxy([], {get(t, k){return k === 'length' ? 3 : 1e9}})",
        "Array(70000).fill(255)", "function(){}", "Object.create(null)", "new Date()", "/x/",
    ]
    static let jsFunctions = [
        "size", "read", "write", "insert", "remove", "u8", "u16", "u32", "u64", "i8", "i16",
        "i32", "i64", "f32", "f64", "str", "hex", "find", "findText", "select", "goto",
    ]

    /// Script API calls with hostile arguments (JS errors are fine).
    @Test func scriptAPI() throws {
        Fuzz.run("scriptAPI", iterations: 40) { r in
            let calls = (0 ..< r.int(1 ... 20)).map { _ in
                let args = (0 ..< r.int(0 ... 4)).map { _ in r.pick(Self.jsValues) }.joined(separator: ", ")
                return "try { print(hw.\(r.pick(Self.jsFunctions))(\(args))) } catch (e) {}"
            }
            let extra = r.pick([
                "", "print(hw.cursor, hw.selection, hw.fileName)", "hw.cursor = -1; hw.fileName = {}",
                "console.log(...Array(100).fill(hw))", "print(Symbol())",
            ])
            let url = try tempFile(Data(r.bytes(r.int(0 ... 64))))
            defer { try? FileManager.default.removeItem(at: url) }
            let doc = try Document(url: url)
            let size = doc.count
            let cursor = UInt64(r.int(0 ... Int(size) + 2))
            let selection: Range<UInt64>? = r.chance(0.5) ? nil : min(cursor, size) ..< size
            let result = ScriptRunner.run(
                (calls + [extra]).joined(separator: "\n"), document: doc,
                context: ScriptContext(cursor: cursor, selection: selection, fileName: "f\u{0}.bin"),
                timeout: 10)
            #expect(result.error?.isTimeout != true, "script hit the time limit")
            _ = doc.read(0 ..< doc.count)
        }
    }

    /// Signature detection and embedded scan on random data and on random
    /// data with real magics planted in it.
    @Test func fileSignatures() {
        Fuzz.run("fileSignatures", iterations: 300) { r in
            var bytes = r.bytes(r.int(0 ... 4096))
            for _ in 0 ..< r.int(0 ... 6) {
                let sig = r.pick(FileSignatures.all)
                let magic = sig.magic.map { $0 ?? UInt8.random(in: 0 ... 255, using: &r) }
                let at = r.chance(0.3) ? sig.offset : r.int(0 ... bytes.count)
                if bytes.count < at + magic.count { bytes += [UInt8](repeating: 0, count: at + magic.count - bytes.count) }
                bytes.replaceSubrange(at ..< at + magic.count, with: magic)
            }
            if r.chance(0.5) { bytes = Fuzz.mutate(bytes, &r) }
            let maxHits = r.int(1 ... 50)
            try withSnapshot(bytes) { snap in
                _ = FileSignatures.detect(snap)
                let lo = UInt64(r.int(0 ... bytes.count)), hi = UInt64(r.int(0 ... bytes.count + 16))
                let hits = FileSignatures.scanEmbedded(snap, range: min(lo, hi) ..< max(lo, hi), maxHits: maxHits)
                #expect(hits.count <= maxHits)
            }
        }
    }
}
