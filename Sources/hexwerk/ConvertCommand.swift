import ArgumentParser
import Foundation
import HexwerkCore

struct Convert: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Zwischen Binärdatei, Intel HEX und Motorola S-Record umwandeln.",
        discussion: "Formate werden an der Endung erkannt (.hex/.ihex → Intel HEX, .srec/.s19/.s28/.s37/.mot → S-Record, sonst binär) oder mit --from/--to gesetzt."
    )

    enum Fmt: String, ExpressibleByArgument, CaseIterable { case bin, ihex, srec }

    @Argument(help: "Eingabe") var input: String
    @Argument(help: "Ausgabe") var output: String
    @Option(help: "Eingabeformat") var from: Fmt?
    @Option(help: "Ausgabeformat") var to: Fmt?
    @Option(help: "Startadresse beim Schreiben von HEX/S-Record aus binär") var base: Number?
    @Option(help: "Füllbyte für Lücken beim Schreiben als binär (hex)") var fill: String = "FF"

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
                guard let f = UInt8(fill, radix: 16) else { throw ValidationError("--fill erwartet ein Hex-Byte") }
                data = try image.flatten(fill: f)
                if base == nil { addr = image.base }
                start = image.startAddress
                FileHandle.standardError.write(Data("\(image.segments.count) Segment(e) ab 0x\(String(image.base, radix: 16, uppercase: true)), \(data.count) Byte, \(image.gaps.count) Lücke(n)\n".utf8))
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
