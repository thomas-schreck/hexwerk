// hexwerk-bench: timings of the core operations on a large generated file.
//
//   swift run -c release hexwerk-bench [--size-mib 256] [--runs 3]
//       [--json out.json] [--baseline Benchmarks/baseline.json] [--tolerance 3] [--slack 0.5]
//
// Each benchmark runs `--runs` times; the fastest run counts (least runner
// noise). With `--baseline` the exit status is 1 if a benchmark took more
// than `tolerance` times its baseline and more than `slack` seconds longer:
// only gross regressions fail, not runner jitter. `make bench` runs it.
import Foundation
import HexwerkCore
import HexwerkKaitai

struct Results: Codable {
    var sizeMiB: Int
    var seconds: [String: Double]
}

// MARK: Options

var sizeMiB = Int(ProcessInfo.processInfo.environment["HEXWERK_BENCH_MIB"] ?? "") ?? 256
var runs = 3
var jsonOut: String?
var baselinePath: String?
var tolerance = 3.0
var slack = 0.5
var args = CommandLine.arguments.dropFirst()
@MainActor func value(_ name: String) -> String {
    guard let v = args.popFirst() else { fatalError("\(name) needs a value") }
    return v
}
while let a = args.popFirst() {
    switch a {
    case "--size-mib": sizeMiB = Int(value(a))!
    case "--runs": runs = Int(value(a))!
    case "--json": jsonOut = value(a)
    case "--baseline": baselinePath = value(a)
    case "--tolerance": tolerance = Double(value(a))!
    case "--slack": slack = Double(value(a))!
    default:
        FileHandle.standardError.write(Data("unknown option \(a)\n".utf8))
        exit(2)
    }
}

// MARK: Test data

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hexwerk-bench-\(getpid())")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
/// Removes the test files; `exit` skips top-level `defer`.
func finish(_ status: Int32) -> Never {
    try? FileManager.default.removeItem(at: dir)
    exit(status)
}
let source = dir.appendingPathComponent("big.bin")
let size = UInt64(sizeMiB) << 20
let hexNeedle: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11]
let textNeedle = Array("HXW1234".utf8)

/// Pseudo-random bytes (xorshift, fixed seed) with both needles planted
/// once per MiB, so searches find a known number of hits.
func generate() throws {
    FileManager.default.createFile(atPath: source.path, contents: nil)
    let h = try FileHandle(forWritingTo: source)
    defer { try? h.close() }
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    let chunk = 8 << 20
    var buf = [UInt8](repeating: 0, count: chunk)
    var written: UInt64 = 0
    while written < size {
        buf.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt64.self)
            for i in words.indices {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                words[i] = state
            }
        }
        for mib in stride(from: 0, to: chunk, by: 1 << 20) {
            buf.replaceSubrange(mib + 100 ..< mib + 100 + hexNeedle.count, with: hexNeedle)
            buf.replaceSubrange(mib + 500 ..< mib + 500 + textNeedle.count, with: textNeedle)
        }
        let n = Int(min(UInt64(chunk), size - written))
        try h.write(contentsOf: buf[0 ..< n])
        written += UInt64(n)
    }
}

/// A fresh copy for benchmarks that modify the file.
func scratchCopy() throws -> URL {
    let url = dir.appendingPathComponent("work.bin")
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.copyItem(at: source, to: url)
    return url
}

func writeKsy(_ name: String, _ yaml: String) throws -> KsyFile {
    let url = dir.appendingPathComponent(name)
    try yaml.write(to: url, atomically: true, encoding: .utf8)
    return try KsyLoader().load(url)
}

// MARK: Benchmarks

struct Bench {
    let name: String
    /// Reads the whole file, so MiB/s is meaningful.
    var wholeFile = true
    /// Untimed preparation; returns the timed work.
    let setup: () throws -> () throws -> Void
}

func check(_ ok: Bool, _ what: @autoclosure () -> String) throws {
    if !ok { throw NSError(domain: "hexwerk-bench", code: 1, userInfo: [NSLocalizedDescriptionKey: what()]) }
}

let mib = Int(sizeMiB)
let records = 150_000
let benches: [Bench] = [
    Bench(name: "open", wholeFile: false) {
        { _ = try Document(url: source, readOnly: true).snapshot() }
    },
    Bench(name: "search hex") {
        let snap = try Document(url: source, readOnly: true).snapshot()
        let pattern = SearchPattern.hex("DE AD BE EF 00 11")!
        return {
            let hits = Search.find(pattern, in: snap)
            try check(hits.count >= mib, "search hex: \(hits.count) hits")
        }
    },
    Bench(name: "search regex") {
        let snap = try Document(url: source, readOnly: true).snapshot()
        return {
            let hits = try RegexSearch.find("HXW[0-9]{4}", in: snap)
            try check(hits.count >= mib, "search regex: \(hits.count) hits")
        }
    },
    Bench(name: "save in place", wholeFile: false) {
        let doc = try Document(url: try scratchCopy())
        for i in 0 ..< 64 { try doc.overwrite(at: UInt64(i) * (size / 64), with: Data([0x42, 0x43])) }
        return { try doc.save(mode: .inPlace) }
    },
    Bench(name: "save length change") {
        let doc = try Document(url: try scratchCopy())
        try doc.insert(Data("inserted".utf8), at: size / 2)
        try doc.delete(0 ..< 16)
        return { try doc.save() }
    },
    Bench(name: "kaitai u4 array") {
        let file = try writeKsy(
            "u4.ksy",
            """
            meta: {id: bench_u4, endian: le}
            seq:
              - id: words
                type: u4
                repeat: eos
            """)
        let snap = try Document(url: source, readOnly: true).snapshot()
        return {
            let r = KaitaiInterpreter.parse(snap, file: file)
            try check(r.error == nil && r.lazyElementCount == Int(size / 4), "kaitai u4: \(r.error?.description ?? "count")")
        }
    },
    Bench(name: "kaitai \(records / 1000)k structs", wholeFile: false) {
        let file = try writeKsy(
            "rec.ksy",
            """
            meta: {id: bench_rec, endian: le}
            seq:
              - id: recs
                type: rec
                repeat: expr
                repeat-expr: \(records)
            types:
              rec:
                seq:
                  - {id: a, type: u4}
                  - {id: b, type: u2}
                  - {id: c, type: u1}
                  - {id: d, type: u1}
            """)
        let snap = try Document(url: source, readOnly: true).snapshot()
        var limits = ParseLimits()
        limits.maxNodes = 10 * records
        limits.maxSeconds = 600
        return {
            let r = KaitaiInterpreter.parse(snap, file: file, limits: limits)
            try check(r.error == nil, "kaitai structs: \(r.error?.description ?? "")")
        }
    },
    Bench(name: "hash sha256+crc32") {
        let snap = try Document(url: source, readOnly: true).snapshot()
        return { _ = Checksum.compute([.sha256, .crc32], snap) }
    },
    Bench(name: "hash xxh64") {
        let snap = try Document(url: source, readOnly: true).snapshot()
        return { _ = Checksum.compute([.xxh64], snap) }
    },
]

// MARK: Run

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

// Read before the long run so a broken file fails fast.
var baseline: Results?
if let baselinePath {
    let b = try JSONDecoder().decode(Results.self, from: Data(contentsOf: URL(fileURLWithPath: baselinePath)))
    if b.sizeMiB == sizeMiB {
        baseline = b
    } else {
        FileHandle.standardError.write(Data("baseline is for \(b.sizeMiB) MiB, not \(sizeMiB) MiB: not compared\n".utf8))
    }
}

FileHandle.standardError.write(Data("generating \(sizeMiB) MiB test file …\n".utf8))
var results = Results(sizeMiB: sizeMiB, seconds: [:])
do {
    try generate()
    for b in benches {
        var best = Double.infinity
        for _ in 0 ..< runs {
            let work = try b.setup()
            let t0 = now()
            try work()
            best = min(best, now() - t0)
        }
        results.seconds[b.name] = best
        FileHandle.standardError.write(Data(String(format: "%@: %.3f s\n", b.name, best).utf8))
    }
} catch {
    FileHandle.standardError.write(Data("benchmark failed: \(error)\n".utf8))
    finish(1)
}

// Markdown table on stdout (CI appends it to the job summary).
var failed = false
print("hexwerk benchmarks, \(sizeMiB) MiB file, best of \(runs) runs\n")
print(
    baseline == nil
        ? "| Benchmark | Seconds | MiB/s |\n|---|---:|---:|"
        : "| Benchmark | Seconds | MiB/s | Baseline | Ratio | |\n|---|---:|---:|---:|---:|---|")
for b in benches {
    let t = results.seconds[b.name]!
    let rate = b.wholeFile ? String(format: "%.0f", Double(sizeMiB) / t) : ""
    var row = String(format: "| %@ | %.3f | %@ |", b.name, t, rate)
    if let base = baseline?.seconds[b.name] {
        let bad = t > base * tolerance && t - base > slack
        failed = failed || bad
        row += String(format: " %.3f | %.2f× | %@ |", base, t / base, bad ? "REGRESSION" : "ok")
    } else if baseline != nil {
        row += " – | – | new |"
    }
    print(row)
}
if baseline != nil {
    print(String(format: "\nFails if slower than %.1f× baseline and more than %.2f s slower.", tolerance, slack))
}

if let jsonOut {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try (enc.encode(results) + Data("\n".utf8)).write(to: URL(fileURLWithPath: jsonOut))
}
finish(failed ? 1 : 0)
