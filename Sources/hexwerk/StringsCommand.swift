import ArgumentParser
import Foundation
import HexwerkCore

struct StringsCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "strings",
        abstract: "Druckbare Zeichenketten finden (wie strings, mit UTF-8 und UTF-16)."
    )

    @Argument(help: "Datei") var file: String
    @Option(name: .short, help: "Mindestlänge in Zeichen") var n: Int = 4
    @Option(name: .shortAndLong, help: "Kodierungen: ascii, utf8, utf16le, utf16be (Komma-getrennt)") var encodings: String = "ascii,utf16le"
    @Option(help: "Start-Offset") var offset: Number?
    @Option(help: "Länge") var length: Number?
    @Flag(help: "Ausgabe als JSON") var json = false

    func run() throws {
        var encs = Set<FoundString.Encoding>()
        for e in encodings.lowercased().split(separator: ",") {
            switch e.trimmingCharacters(in: .whitespaces) {
            case "ascii": encs.insert(.ascii)
            case "utf8", "utf-8": encs.insert(.utf8)
            case "utf16le", "utf-16le": encs.insert(.utf16le)
            case "utf16be", "utf-16be": encs.insert(.utf16be)
            default: throw ValidationError("Unbekannte Kodierung \(e)")
            }
        }
        let snap = try openSnapshot(file)
        let r = try resolveRange(snap, offset, length)
        let found = Strings.find(snap, range: r, minLength: max(1, n), encodings: encs)
        if json {
            try printJSON(found.map { ["offset": $0.offset, "length": $0.length, "encoding": $0.encoding.rawValue, "text": $0.text] })
            return
        }
        for f in found {
            let tag = f.encoding == .ascii ? "" : " [\(f.encoding.rawValue)]"
            print(String(format: "%8llx", f.offset) + "\(tag) " + f.text)
        }
    }
}
