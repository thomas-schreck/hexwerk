import ArgumentParser
import Foundation
import HexwerkCore

/// Start/length options shared by entropy, export and hash, resolved to a range.
func resolveRange(_ snap: Snapshot, _ offset: Number?, _ length: Number?) throws -> Range<UInt64> {
    let start = offset?.value ?? 0
    guard start <= snap.count else {
        FileHandle.standardError.write(
            Data(("hexwerk: " + L("Offset %llu is past the end of the file (%llu)", start, snap.count) + "\n").utf8))
        throw ExitCode(1)
    }
    // Clamp the length before adding: start + length can exceed UInt64.max.
    return start ..< (length.map { start + min($0.value, snap.count - start) } ?? snap.count)
}

struct Entropy: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: L("Entropy and byte distribution (overall and per block)."),
        discussion: L("Entropy in bits per byte: near 0 constant, near 8 compressed or encrypted.")
    )

    @Argument(help: .init(L("File"))) var file: String
    @Option(help: .init(L("Start offset (decimal or 0x...)"))) var offset: Number?
    @Option(help: .init(L("Number of bytes"))) var length: Number?
    @Option(help: .init(L("Number of blocks for the profile"))) var blocks: Int = 64
    @Flag(help: .init(L("Output as JSON (including histogram)"))) var json = false

    func run() throws {
        let snap = try openSnapshot(file)
        let r = try resolveRange(snap, offset, length)
        guard let (stats, profile) = Analysis.analyze(snap, range: r, blocks: blocks) else { return }
        if json {
            try printJSON(
                [
                    "offset": r.lowerBound, "length": r.count, "entropy": stats.entropy,
                    "distinct": stats.distinct, "zeroRatio": stats.zeroRatio,
                    "printableRatio": stats.printableRatio, "highRatio": stats.highRatio,
                    "histogram": stats.histogram, "blockSize": profile.blockSize, "blocks": profile.blocks,
                ] as [String: Any])
            return
        }
        print(L("Entropy    %@ bits/byte", String(format: "%.4f", stats.entropy)))
        print(L("Bytes      %llu, distinct %ld", stats.count, stats.distinct))
        print(
            L(
                "Ratios     0x00 %@ %%, printable %@ %%, ≥0x80 %@ %%",
                String(format: "%.1f", stats.zeroRatio * 100), String(format: "%.1f", stats.printableRatio * 100),
                String(format: "%.1f", stats.highRatio * 100)))
        print(L("Profile    per %llu bytes:", profile.blockSize))
        for (i, e) in profile.blocks.enumerated() {
            let b = profile.range(ofBlock: i, total: r.upperBound)
            let bar = String(repeating: "█", count: Int((e / 8 * 40).rounded()))
            let off = String(b.lowerBound, radix: 16, uppercase: true)
            print("  " + String(repeating: "0", count: max(0, 10 - off.count)) + off + String(format: "  %5.2f ", e) + bar)
        }
    }
}

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: L("Output a range as raw data, hex, C array, Python, Swift or Base64."))

    enum Format: String, ExpressibleByArgument, CaseIterable { case raw, hex, c, python, swift, base64 }

    @Argument(help: .init(L("File"))) var file: String
    @Option(help: .init(L("Start offset (decimal or 0x...)"))) var offset: Number?
    @Option(help: .init(L("Number of bytes"))) var length: Number?
    @Option(help: .init(L("Format: %@", Format.allCases.map(\.rawValue).joined(separator: ", ")))) var format: Format = .hex
    @Option(help: .init(L("Variable name for c/python/swift"))) var name = "data"
    @Option(name: .shortAndLong, help: .init(L("Write to a file instead of stdout"))) var output: String?

    func run() throws {
        let snap = try openSnapshot(file)
        let r = try resolveRange(snap, offset, length)
        let bytes = snap.read(r)
        let out: Data =
            switch format {
            case .raw: bytes
            default: Data((ExportFormat(rawValue: format.rawValue)!.render(bytes, name: name) + "\n").utf8)
            }
        if let output {
            do { try out.write(to: URL(fileURLWithPath: output), options: .atomic) } catch {
                FileHandle.standardError.write(Data("hexwerk: \(output): \(error.localizedDescription)\n".utf8))
                throw ExitCode(1)
            }
        } else {
            FileHandle.standardOutput.write(out)
        }
    }
}
