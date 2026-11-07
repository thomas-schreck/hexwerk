import ArgumentParser
import Foundation
import HexwerkCore
import HexwerkHelper
import HexwerkKaitai

/// Where the Kaitai format collection lives (`make formats` clones it there).
let formatLibrary = HexwerkPaths.formats

struct Parse: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: L("Parse a file with a Kaitai Struct description (.ksy)."),
        discussion: L("Formats from the collection (%@) via --format, your own via --ksy.", formatLibrary.path)
    )

    @Argument(help: .init(L("File"))) var file: String
    @Option(help: .init(L("Path to a .ksy file"))) var ksy: String?
    @Option(
        help: .init(L("Format ID from the collection, e.g. png or zip")),
        // Shell completion: the IDs of the installed collection.
        completion: .custom { _, _, prefix in
            FormatCatalog(root: formatLibrary).entries.map(\.id).filter { $0.hasPrefix(prefix) }.sorted()
        }
    ) var format: String?
    @Option(help: .init(L("Maximum output depth"))) var depth: Int = 64
    @Flag(help: .init(L("Output as JSON"))) var json = false

    func validate() throws {
        guard (ksy == nil) != (format == nil) else { throw ValidationError(L("Specify exactly one of --ksy or --format")) }
    }

    func run() throws {
        let url: URL
        if let ksy {
            url = URL(fileURLWithPath: ksy)
        } else {
            guard let hit = FormatCatalog(root: formatLibrary).url(forID: format!) else {
                FileHandle.standardError.write(
                    Data(("hexwerk: " + L("Format %@ not in %@ (make formats)", format!, formatLibrary.path) + "\n").utf8))
                throw ExitCode(1)
            }
            url = hit
        }
        // The .ksy is loaded and the file parsed in the sandboxed child. A
        // file that cannot be opened is reported after the format's errors.
        let opened = Result { try Document(url: URL(fileURLWithPath: file), readOnly: true).snapshot() }
        let result: ParseResult
        switch try sandboxed({ try $0.parse(try? opened.get(), ksy: url, libraryRoots: [formatLibrary]) }) {
        case .loadError(let e):
            FileHandle.standardError.write(Data("hexwerk: \(e)\n".utf8))
            throw ExitCode(2)
        case .loaded:
            _ = try openSnapshot(file)  // reports the error and exits
            throw ExitCode(1)
        case .result(let r): result = r
        }
        if json {
            try printJSON(jsonObject(result.root, depth: depth))
        } else {
            printTree(result.root, indent: 0, depth: depth)
        }
        if let e = result.error {
            FileHandle.standardError.write(Data(("hexwerk: " + L("Parse error: %@", TerminalText.escape("\(e)")) + "\n").utf8))
            throw ExitCode(2)
        }
    }

    private func printTree(_ n: ParseNode, indent: Int, depth: Int) {
        let pad = String(repeating: "  ", count: indent)
        var line = pad + n.name
        if !n.typeName.isEmpty { line += " : \(n.typeName)" }
        if let v = n.value { line += " = \(v)" }
        if let r = n.range { line += String(format: "  [0x%llx, %llu B]", r.lowerBound, UInt64(r.count)) }
        if let e = n.error { line += "  ⚠ \(e)" }
        // Names, values and errors can all carry bytes from the file.
        print(TerminalText.escape(line))
        guard indent < depth else { return }
        // Long arrays: first 50 entries are enough on a terminal.
        for i in 0 ..< n.childCount {
            if i == 50 && n.childCount > 60 {
                print(pad + "  " + L("… %ld more", n.childCount - 50))
                break
            }
            printTree(n.child(i), indent: indent + 1, depth: depth)
        }
    }

    private func jsonObject(_ n: ParseNode, depth: Int) -> [String: Any] {
        var o: [String: Any] = ["name": n.name, "type": n.typeName]
        if let v = n.value { o["value"] = v }
        if let num = n.number { o["number"] = num }
        if let r = n.range { o["offset"] = r.lowerBound; o["size"] = r.count }
        if let e = n.error { o["error"] = e }
        if depth > 0 { o["children"] = n.allChildren.map { jsonObject($0, depth: depth - 1) } }
        return o
    }
}
