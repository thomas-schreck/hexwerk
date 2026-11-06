import ArgumentParser
import Foundation
import HexwerkCore

struct Find: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Muster suchen und Treffer-Offsets ausgeben.",
        discussion: "Standard ist Hex mit ?? als Platzhalter, z. B. \"4D 5A ?? 00\"."
    )

    enum Mode: String, ExpressibleByArgument, CaseIterable { case hex, text, regex, int8, int16, int32, int64, float32, float64 }

    @Argument(help: "Datei") var file: String
    @Argument(help: "Muster") var pattern: String
    @Option(help: "Art des Musters: \(Mode.allCases.map(\.rawValue).joined(separator: ", "))") var mode: Mode = .hex
    @Option(help: "Kodierung für --mode text: ascii, utf8, utf16le, utf16be") var encoding: String = "utf8"
    @Flag(help: "Groß-/Kleinschreibung ignorieren (nur ASCII-Buchstaben)") var ignoreCase = false
    @Option(help: "Byte-Reihenfolge für Zahlen: little oder big") var endian: EndianArg = .little
    @Flag(help: "Ausgabe als JSON") var json = false

    func run() throws {
        if mode == .regex {
            let hits: [Range<UInt64>]
            do { hits = try RegexSearch.find(pattern, ignoreCase: ignoreCase, in: try openSnapshot(file)) }
            catch let e as ExitCode { throw e }
            catch {
                FileHandle.standardError.write(Data("hexwerk: ungültiger regulärer Ausdruck: \(error.localizedDescription)\n".utf8))
                throw ExitCode(1)
            }
            if json { try printJSON(hits.map { ["offset": $0.lowerBound, "length": $0.count] }) }
            else { for h in hits { print(String(format: "0x%08llx  %llu  (%llu Byte)", h.lowerBound, h.lowerBound, UInt64(h.count))) } }
            return
        }
        let p: SearchPattern?
        switch mode {
        case .hex: p = .hex(pattern)
        case .regex: p = nil
        case .text:
            guard let enc = SearchPattern.TextEncoding(rawValue: encoding) else {
                throw ValidationError("Unbekannte Kodierung \(encoding)")
            }
            p = .text(pattern, encoding: enc, ignoreCase: ignoreCase)
        default:
            p = .number(pattern, kind: SearchPattern.NumberKind(rawValue: mode.rawValue)!, endian: endian.value)
        }
        guard let p else {
            FileHandle.standardError.write(Data("hexwerk: ungültiges Muster \"\(pattern)\" für --mode \(mode.rawValue)\n".utf8))
            throw ExitCode(1)
        }
        let hits = Search.find(p, in: try openSnapshot(file))
        if json {
            try printJSON(hits.map { ["offset": $0.lowerBound, "length": $0.count] })
        } else {
            for h in hits { print(String(format: "0x%08llx  %llu", h.lowerBound, h.lowerBound)) }
        }
        if hits.count >= Search.maxHits {
            FileHandle.standardError.write(Data("hexwerk: abgebrochen nach \(Search.maxHits) Treffern\n".utf8))
        }
    }
}

struct Diff: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Zwei Dateien vergleichen; erkennt eingefügte und gelöschte Bytes.",
        discussion: "Ausgabe je Unterschied: Offset in A, Offset in B, Art. Exit 1 bei Unterschieden."
    )

    @Argument(help: "Erste Datei (A)") var a: String
    @Argument(help: "Zweite Datei (B)") var b: String
    @Flag(help: "Nur an gleichen Offsets vergleichen (ohne Neuausrichtung)") var positional = false
    @Flag(help: "Ausgabe als JSON") var json = false

    func run() throws {
        let sa = try openSnapshot(a), sb = try openSnapshot(b)
        let ops = positional ? AlignedDiff.positional(sa, sb) : AlignedDiff.diff(sa, sb)
        if json {
            try printJSON(ops.map {
                ["kind": $0.kind.rawValue, "aOffset": $0.a.lowerBound, "aLength": $0.a.count,
                 "bOffset": $0.b.lowerBound, "bLength": $0.b.count] as [String: Any]
            })
        } else {
            for o in ops {
                let what = switch o.kind {
                case .replace: "\(o.a.count) → \(o.b.count) Byte ersetzt"
                case .insert: "\(o.b.count) Byte nur in B"
                case .delete: "\(o.a.count) Byte nur in A"
                }
                print(String(format: "A 0x%08llx  B 0x%08llx  ", o.a.lowerBound, o.b.lowerBound) + what)
            }
        }
        // Like cmp/diff: 1 means "files differ", not an error.
        if !ops.isEmpty { throw ExitCode(1) }
    }
}

struct Hash: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Prüfsummen über Datei oder Bereich.",
        discussion: "Algorithmen: " + Checksum.allCases.map(\.cliName).joined(separator: ", ")
    )

    @Argument(help: "Datei") var file: String
    @Option(help: "Algorithmen, durch Komma getrennt; „all“ für alle, „common“ für CRC32/MD5/SHA-1/SHA-256")
    var algo: String = "sha-256"
    @Option(help: "Start-Offset") var offset: Number?
    @Option(help: "Länge") var length: Number?
    @Flag(help: "Ausgabe als JSON") var json = false

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
                    FileHandle.standardError.write(Data("hexwerk: unbekannter Algorithmus \(name) (siehe --help)\n".utf8))
                    throw ExitCode(64)
                }
                algos.append(a)
            }
        }
        let s = try openSnapshot(file)
        let start = offset?.value ?? 0
        let range = start ..< (length.map { start + $0.value } ?? s.count)
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
