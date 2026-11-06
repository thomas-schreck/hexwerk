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
        var data: Data
        var addr = base?.value ?? 0
        var start: UInt64?
        do {
            if inFmt == .bin {
                data = try Data(contentsOf: URL(fileURLWithPath: input))
            } else {
                let image = try HexRecords.parse(try String(contentsOfFile: input, encoding: .ascii))
                guard let f = UInt8(fill, radix: 16) else { throw ValidationError(L("--fill expects a hex byte")) }
                data = try image.flatten(fill: f)
                if base == nil { addr = image.base }
                start = image.startAddress
                FileHandle.standardError.write(Data((L("%ld segment(s) from 0x%llX, %ld bytes, %ld gap(s)", image.segments.count, image.base, data.count, image.gaps.count) + "\n").utf8))
            }
            let out: Data = switch outFmt {
            case .bin: data
            case .ihex: Data(HexRecords.intelHex(data, base: addr, start: start).utf8)
            case .srec: Data(HexRecords.srec(data, base: addr, start: start).utf8)
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
