import ArgumentParser
import Foundation
import HexwerkCore

struct StringsCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "strings",
        abstract: L("Find printable strings (like strings, with UTF-8 and UTF-16).")
    )

    @Argument(help: .init(L("File"))) var file: String
    @Option(name: .short, help: .init(L("Minimum length in characters"))) var n: Int = 4
    @Option(name: .shortAndLong, help: .init(L("Encodings: ascii, utf8, utf16le, utf16be (comma-separated)"))) var encodings: String = "ascii,utf16le"
    @Option(help: .init(L("Start offset"))) var offset: Number?
    @Option(help: .init(L("Length"))) var length: Number?
    @Flag(help: .init(L("Output as JSON"))) var json = false

    func run() throws {
        var encs = Set<FoundString.Encoding>()
        for e in encodings.lowercased().split(separator: ",") {
            switch e.trimmingCharacters(in: .whitespaces) {
            case "ascii": encs.insert(.ascii)
            case "utf8", "utf-8": encs.insert(.utf8)
            case "utf16le", "utf-16le": encs.insert(.utf16le)
            case "utf16be", "utf-16be": encs.insert(.utf16be)
            default: throw ValidationError(L("Unknown encoding %@", String(e)))
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
            print(String(format: "%8llx", f.offset) + "\(tag) " + TerminalText.escape(f.text))
        }
    }
}
