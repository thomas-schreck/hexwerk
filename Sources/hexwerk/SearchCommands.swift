import ArgumentParser
import Foundation
import HexwerkCore

struct Find: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: L("Search for a pattern and print the offsets of hits."),
        discussion: L("Default is hex with ?? as wildcard, e.g. \"4D 5A ?? 00\".")
    )

    enum Mode: String, ExpressibleByArgument, CaseIterable { case hex, text, regex, int8, int16, int32, int64, float32, float64 }

    @Argument(help: .init(L("File"))) var file: String
    @Argument(help: .init(L("Pattern"))) var pattern: String
    @Option(help: .init(L("Pattern type: %@", Mode.allCases.map(\.rawValue).joined(separator: ", ")))) var mode: Mode = .hex
    @Option(help: .init(L("Encoding for --mode text: ascii, utf8, utf16le, utf16be"))) var encoding: String = "utf8"
    @Flag(help: .init(L("Ignore case (ASCII letters only)"))) var ignoreCase = false
    @Option(help: .init(L("Byte order for numbers: little or big"))) var endian: EndianArg = .little
    @Flag(help: .init(L("Output as JSON"))) var json = false

    func run() throws {
        if mode == .regex {
            let hits: [Range<UInt64>]
            do { hits = try RegexSearch.find(pattern, ignoreCase: ignoreCase, in: try openSnapshot(file)) }
            catch let e as ExitCode { throw e }
            catch {
                FileHandle.standardError.write(Data(("hexwerk: " + L("invalid regular expression: %@", error.localizedDescription) + "\n").utf8))
                throw ExitCode(1)
            }
            if json { try printJSON(hits.map { ["offset": $0.lowerBound, "length": $0.count] }) }
            else { for h in hits { print(String(format: "0x%08llx  %llu  (", h.lowerBound, h.lowerBound) + L("%@ bytes", String(h.count)) + ")") } }
            if hits.count >= Search.maxHits { reportStopped(Search.maxHits) }
            return
        }
        let p: SearchPattern?
        switch mode {
        case .hex: p = .hex(pattern)
        case .regex: p = nil
        case .text:
            guard let enc = SearchPattern.TextEncoding(rawValue: encoding) else {
                throw ValidationError(L("Unknown encoding %@", encoding))
            }
            p = .text(pattern, encoding: enc, ignoreCase: ignoreCase)
        default:
            p = .number(pattern, kind: SearchPattern.NumberKind(rawValue: mode.rawValue)!, endian: endian.value)
        }
        guard let p else {
            FileHandle.standardError.write(Data(("hexwerk: " + L("invalid pattern \"%@\" for --mode %@", pattern, mode.rawValue) + "\n").utf8))
            throw ExitCode(1)
        }
        let hits = Search.find(p, in: try openSnapshot(file))
        if json {
            try printJSON(hits.map { ["offset": $0.lowerBound, "length": $0.count] })
        } else {
            for h in hits { print(String(format: "0x%08llx  %llu", h.lowerBound, h.lowerBound)) }
        }
        if hits.count >= Search.maxHits { reportStopped(Search.maxHits) }
    }
}

/// Results were cut off at a hit limit: say so on stderr, keep stdout clean.
func reportStopped(_ limit: Int) {
    FileHandle.standardError.write(Data(("hexwerk: " + L("stopped after %ld hits", limit) + "\n").utf8))
}

struct Diff: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: L("Compare two files; detects inserted and deleted bytes."),
        discussion: L("Output per difference: offset in A, offset in B, kind. Exit 0 if the files are equal, 1 if they differ, 2 on errors.")
    )

    @Argument(help: .init(L("First file (A)"))) var a: String
    @Argument(help: .init(L("Second file (B)"))) var b: String
    @Flag(help: .init(L("Compare at the same offsets only (no realignment)"))) var positional = false
    @Flag(help: .init(L("Output as JSON"))) var json = false

    func run() throws {
        // Like cmp/diff: 1 only means "files differ", trouble is 2.
        let sa = try openSnapshot(a, failure: 2), sb = try openSnapshot(b, failure: 2)
        let ops = positional ? AlignedDiff.positional(sa, sb) : AlignedDiff.diff(sa, sb)
        if json {
            try printJSON(ops.map {
                ["kind": $0.kind.rawValue, "aOffset": $0.a.lowerBound, "aLength": $0.a.count,
                 "bOffset": $0.b.lowerBound, "bLength": $0.b.count] as [String: Any]
            })
        } else {
            for o in ops {
                let what = switch o.kind {
                case .replace: L("%ld → %ld bytes replaced", o.a.count, o.b.count)
                case .insert: L("%ld bytes only in B", o.b.count)
                case .delete: L("%ld bytes only in A", o.a.count)
                }
                print(String(format: "A 0x%08llx  B 0x%08llx  ", o.a.lowerBound, o.b.lowerBound) + what)
            }
        }
        if AlignedDiff.isTruncated(ops, sa, sb, positional: positional) { reportStopped(Search.maxHits) }
        if !ops.isEmpty { throw ExitCode(1) }
    }
}

struct Hash: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: L("Checksums over a file or range."),
        discussion: L("Algorithms: %@", Checksum.allCases.map(\.cliName).joined(separator: ", "))
    )

    @Argument(help: .init(L("File"))) var file: String
    @Option(help: .init(L("Algorithms, comma-separated; “all” for all, “common” for CRC32/MD5/SHA-1/SHA-256")))
    var algo: String = "sha-256"
    @Option(help: .init(L("Start offset"))) var offset: Number?
    @Option(help: .init(L("Length"))) var length: Number?
    @Flag(help: .init(L("Output as JSON"))) var json = false

    func run() throws {
        var algos: [Checksum] = []
        for name in algo.lowercased().split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespaces) }) {
            switch name {
            case "all": algos += Checksum.allCases
            case "common": algos += Checksum.common
            default:
                let key = name.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "/", with: "")
                guard let a = Checksum.allCases.first(where: {
                    $0.cliName == name || $0.cliName.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "/", with: "") == key
                }) else {
                    FileHandle.standardError.write(Data(("hexwerk: " + L("unknown algorithm %@ (see --help)", name) + "\n").utf8))
                    throw ExitCode(64)
                }
                algos.append(a)
            }
        }
        let s = try openSnapshot(file)
        let range = try resolveRange(s, offset, length)
        let result = Checksum.compute(algos, s, range: range) ?? [:]
        if json {
            try printJSON(Dictionary(uniqueKeysWithValues: algos.map { ($0.cliName, result[$0] ?? "") }))
            return
        }
        let w = algos.map(\.rawValue.count).max() ?? 0
        for a in algos {
            let value = result[a] ?? "?"
            print(algos.count == 1 ? "\(value)  \(file)" : a.rawValue.padding(toLength: w, withPad: " ", startingAt: 0) + "  " + value)
        }
    }
}
