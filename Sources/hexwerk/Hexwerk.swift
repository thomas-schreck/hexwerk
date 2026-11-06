import ArgumentParser
import Foundation
import HexwerkCore

@main
struct Hexwerk: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Hex-Werkzeug: Dateien ansehen, untersuchen, parsen.",
        subcommands: [Dump.self, Inspect.self, Find.self, Diff.self, Hash.self, Parse.self, Yara.self, Entropy.self, Export.self, Script.self, FileType.self, StringsCmd.self, Convert.self, OpenCmd.self]
    )
}

/// Offsets and lengths accept decimal or 0x-prefixed hex.
struct Number: ExpressibleByArgument {
    let value: UInt64
    init?(argument: String) {
        let s = argument.lowercased().replacingOccurrences(of: "_", with: "")
        if s.hasPrefix("0x") {
            guard let v = UInt64(s.dropFirst(2), radix: 16) else { return nil }
            value = v
        } else {
            guard let v = UInt64(s) else { return nil }
            value = v
        }
    }
}

func openSource(_ path: String) throws -> ByteSource {
    do { return try ByteSource(url: URL(fileURLWithPath: path)) }
    catch {
        FileHandle.standardError.write(Data("hexwerk: \(error)\n".utf8))
        throw ExitCode(1)
    }
}

func openSnapshot(_ path: String) throws -> Snapshot {
    do { return try Document(url: URL(fileURLWithPath: path), readOnly: true).snapshot() }
    catch {
        FileHandle.standardError.write(Data("hexwerk: \(error)\n".utf8))
        throw ExitCode(1)
    }
}

func printJSON(_ obj: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

struct Dump: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Bereich als Hex-Dump ausgeben (Format wie hexdump -C).")

    @Argument(help: "Datei") var file: String
    @Option(help: "Start-Offset (dezimal oder 0x…)") var offset: Number = Number(argument: "0")!
    @Option(help: "Anzahl Bytes (Standard: bis Dateiende)") var length: Number?
    @Option(help: "Bytes pro Zeile") var width: Int = 16

    func validate() throws {
        guard (1...256).contains(width) else { throw ValidationError("--width muss zwischen 1 und 256 liegen") }
    }

    func run() throws {
        let src = try openSource(file)
        let start = offset.value
        let end = length.map { min(src.count, start + $0.value) } ?? src.count
        guard start <= src.count else {
            FileHandle.standardError.write(Data("hexwerk: Offset \(start) liegt hinter dem Dateiende (\(src.count))\n".utf8))
            throw ExitCode(1)
        }
        // Stream in blocks so large ranges never sit in memory at once.
        let block = UInt64(width * 4096)
        var pos = start
        repeat {
            let chunk = src.read(pos ..< min(pos + block, end))
            var lines = HexDump.lines(chunk, startOffset: pos, width: width)
            let isLast = pos + UInt64(chunk.count) >= end
            if !isLast { lines.removeLast() }   // trailing offset only once, at the end
            print(lines.joined(separator: "\n"))
            pos += UInt64(chunk.count)
        } while pos < end
    }
}

struct Inspect: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Bytes an einem Offset als Datentypen deuten.")

    @Argument(help: "Datei") var file: String
    @Argument(help: "Offset (dezimal oder 0x…)") var offset: Number
    @Option(help: "Byte-Reihenfolge: little oder big") var endian: EndianArg = .little
    @Flag(help: "Ausgabe als JSON") var json = false

    func run() throws {
        let src = try openSource(file)
        guard offset.value < src.count else {
            FileHandle.standardError.write(Data("hexwerk: Offset \(offset.value) liegt hinter dem Dateiende (\(src.count))\n".utf8))
            throw ExitCode(1)
        }
        let values = Inspector.values(src.read(offset.value ..< offset.value + UInt64(Inspector.window)),
                                      endian: endian.value)
        if json {
            let obj = values.reduce(into: [String: String]()) { $0[$1.name] = $1.value }
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } else {
            let w = values.map(\.name.count).max() ?? 0
            for v in values {
                print(v.name.padding(toLength: w, withPad: " ", startingAt: 0) + "  " + (v.value ?? "—"))
            }
        }
    }
}

enum EndianArg: String, ExpressibleByArgument {
    case little, big
    var value: Endian { self == .little ? .little : .big }
}
