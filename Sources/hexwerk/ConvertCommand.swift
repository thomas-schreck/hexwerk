import ArgumentParser
import Foundation
import HexwerkCore

struct Convert: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: L("Convert between binary, Intel HEX and Motorola S-Record."),
        discussion: L("Formats are detected by file extension (.hex/.ihex → Intel HEX, .srec/.s19/.s28/.s37/.mot → S-Record, otherwise binary) or set with --from/--to.")
    )

    enum Fmt: String, ExpressibleByArgument, CaseIterable { case bin, ihex, srec }

    @Argument(help: .init(L("Input"))) var input: String
    @Argument(help: .init(L("Output"))) var output: String
    @Option(help: .init(L("Input format"))) var from: Fmt?
    @Option(help: .init(L("Output format"))) var to: Fmt?
    @Option(help: .init(L("Start address when writing HEX/S-Record from binary"))) var base: Number?
    @Option(help: .init(L("Fill byte for gaps when writing binary (hex)"))) var fill: String = "FF"

    static func guess(_ path: String) -> Fmt {
        switch (path as NSString).pathExtension.lowercased() {
        case "hex", "ihex", "ihx": .ihex
        case "srec", "s19", "s28", "s37", "mot", "s": .srec
        default: .bin
        }
    }

    func run() throws {
        let inFmt = from ?? Self.guess(input), outFmt = to ?? Self.guess(output)
        var segments: [HexRecords.Segment]
        var start: UInt64?
        do {
            if inFmt == .bin {
                let data = try Data(contentsOf: URL(fileURLWithPath: input))
                segments = HexRecords.segments(data, base: base?.value ?? 0, gaps: [])
            } else {
                let image = try HexRecords.parse(try String(contentsOfFile: input, encoding: .ascii))
                start = image.startAddress
                FileHandle.standardError.write(Data((L("%ld segment(s) from 0x%llX, %ld bytes, %ld gap(s)", image.segments.count, image.base, image.segments.reduce(0) { $0 + $1.data.count }, image.gaps.count) + "\n").utf8))
                if outFmt == .bin {
                    // Only a flat binary needs the gaps filled.
                    guard let f = UInt8(fill, radix: 16) else { throw ValidationError(L("--fill expects a hex byte")) }
                    try image.flatten(fill: f).write(to: URL(fileURLWithPath: output), options: .atomic)
                    return
                }
                // HEX/S-Record keep the segments: filling gaps would add bytes
                // that were never data (and get flashed), and a gap of hundreds
                // of MiB would be written out in full.
                segments = image.segments
                if let base {
                    for i in segments.indices {
                        let (a, o) = (segments[i].address - image.base).addingReportingOverflow(base.value)
                        guard !o else { throw ValidationError(L("--base moves the data past the end of the address space")) }
                        segments[i].address = a
                    }
                }
            }
            let out: Data = switch outFmt {
            case .bin: segments.first?.data ?? Data()
            case .ihex: Data(try HexRecords.intelHex(segments, start: start).utf8)
            case .srec: Data(try HexRecords.srec(segments, start: start).utf8)
            }
            try out.write(to: URL(fileURLWithPath: output), options: .atomic)
        } catch let e as HexRecords.HexRecordError {
            FileHandle.standardError.write(Data("hexwerk: \(input): \(e)\n".utf8))
            throw ExitCode(2)
        } catch let e as ValidationError {
            throw e
        } catch {
            FileHandle.standardError.write(Data("hexwerk: \(error.localizedDescription)\n".utf8))
            throw ExitCode(1)
        }
    }
}
