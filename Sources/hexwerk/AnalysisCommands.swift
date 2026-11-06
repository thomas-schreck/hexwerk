import ArgumentParser
import Foundation
import HexwerkCore

/// Start/length options shared by entropy and export, resolved to a range.
func resolveRange(_ snap: Snapshot, _ offset: Number?, _ length: Number?) throws -> Range<UInt64> {
    let start = offset?.value ?? 0
    guard start <= snap.count else {
        FileHandle.standardError.write(Data("hexwerk: Offset \(start) liegt hinter dem Dateiende (\(snap.count))\n".utf8))
        throw ExitCode(1)
    }
    return start ..< (length.map { min(snap.count, start + $0.value) } ?? snap.count)
}

struct Entropy: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Entropie und Byte-Verteilung (gesamt und je Block).",
        discussion: "Entropie in Bit pro Byte: um 0 konstant, um 8 komprimiert oder verschlüsselt."
    )

    @Argument(help: "Datei") var file: String
    @Option(help: "Start-Offset (dezimal oder 0x…)") var offset: Number?
    @Option(help: "Anzahl Bytes") var length: Number?
    @Option(help: "Anzahl Blöcke für den Verlauf") var blocks: Int = 64
    @Flag(help: "Ausgabe als JSON (inkl. Histogramm)") var json = false

    func run() throws {
        let snap = try openSnapshot(file)
        let r = try resolveRange(snap, offset, length)
        guard let (stats, profile) = Analysis.analyze(snap, range: r, blocks: blocks) else { return }
        if json {
            try printJSON([
                "offset": r.lowerBound, "length": r.count, "entropy": stats.entropy,
                "distinct": stats.distinct, "zeroRatio": stats.zeroRatio,
                "printableRatio": stats.printableRatio, "highRatio": stats.highRatio,
                "histogram": stats.histogram, "blockSize": profile.blockSize, "blocks": profile.blocks,
            ] as [String: Any])
            return
        }
        print(String(format: "Entropie   %.4f Bit/Byte", stats.entropy))
        print("Bytes      \(stats.count), verschieden \(stats.distinct)")
        print(String(format: "Anteile    0x00 %.1f %%, druckbar %.1f %%, ≥0x80 %.1f %%",
                     stats.zeroRatio * 100, stats.printableRatio * 100, stats.highRatio * 100))
        print("Verlauf    je \(profile.blockSize) Byte:")
        for (i, e) in profile.blocks.enumerated() {
            let b = profile.range(ofBlock: i, total: r.upperBound)
            let bar = String(repeating: "█", count: Int((e / 8 * 40).rounded()))
            let off = String(b.lowerBound, radix: 16, uppercase: true)
            print("  " + String(repeating: "0", count: max(0, 10 - off.count)) + off + String(format: "  %5.2f ", e) + bar)
        }
    }
}

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Bereich als Rohdaten, Hex, C-Array, Python, Swift oder Base64 ausgeben.")

    enum Format: String, ExpressibleByArgument, CaseIterable { case raw, hex, c, python, swift, base64 }

    @Argument(help: "Datei") var file: String
    @Option(help: "Start-Offset (dezimal oder 0x…)") var offset: Number?
    @Option(help: "Anzahl Bytes") var length: Number?
    @Option(help: "Format: \(Format.allCases.map(\.rawValue).joined(separator: ", "))") var format: Format = .hex
    @Option(help: "Variablenname für c/python/swift") var name = "data"
    @Option(name: .shortAndLong, help: "In Datei schreiben statt auf stdout") var output: String?

    func run() throws {
        let snap = try openSnapshot(file)
        let r = try resolveRange(snap, offset, length)
        let bytes = snap.read(r)
        let out: Data = switch format {
        case .raw: bytes
        default: Data((ExportFormat(rawValue: format.rawValue)!.render(bytes, name: name) + "\n").utf8)
        }
        if let output {
            do { try out.write(to: URL(fileURLWithPath: output), options: .atomic) }
            catch {
                FileHandle.standardError.write(Data("hexwerk: \(output): \(error.localizedDescription)\n".utf8))
                throw ExitCode(1)
            }
        } else {
            FileHandle.standardOutput.write(out)
        }
    }
}
