import ArgumentParser
import Foundation
import HexwerkCore
import HexwerkKaitai

/// Where the Kaitai format collection lives (`make formats` clones it there).
let formatLibrary = HexwerkPaths.formats

struct Parse: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Datei mit einer Kaitai-Struct-Beschreibung (.ksy) zerlegen.",
        discussion: "Formate aus der Sammlung (\(formatLibrary.path)) per --format, eigene per --ksy."
    )

    @Argument(help: "Datei") var file: String
    @Option(help: "Pfad zu einer .ksy-Datei") var ksy: String?
    @Option(help: "Format-ID aus der Sammlung, z. B. png oder zip") var format: String?
    @Option(help: "Maximale Tiefe der Ausgabe") var depth: Int = 64
    @Flag(help: "Ausgabe als JSON") var json = false

    func validate() throws {
        guard (ksy == nil) != (format == nil) else { throw ValidationError("Genau eins von --ksy oder --format angeben") }
    }

    func run() throws {
        let url: URL
        if let ksy { url = URL(fileURLWithPath: ksy) }
        else {
            guard let hit = FormatCatalog(root: formatLibrary).url(forID: format!) else {
                FileHandle.standardError.write(Data("hexwerk: Format \(format!) nicht in \(formatLibrary.path) (make formats)\n".utf8))
                throw ExitCode(1)
            }
            url = hit
        }
        let schema: KsyFile
        do { schema = try KsyLoader(libraryRoots: [formatLibrary]).load(url) }
        catch {
            FileHandle.standardError.write(Data("hexwerk: \(error)\n".utf8))
            throw ExitCode(2)
        }
        let result = KaitaiInterpreter.parse(try openSnapshot(file), file: schema)
        if json {
            let data = try JSONSerialization.data(withJSONObject: jsonObject(result.root, depth: depth),
                                                  options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } else {
            printTree(result.root, indent: 0, depth: depth)
        }
        if let e = result.error {
            FileHandle.standardError.write(Data("hexwerk: Fehler beim Zerlegen: \(e)\n".utf8))
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
        print(line)
        guard indent < depth else { return }
        // Long arrays: first 50 entries are enough on a terminal.
        for i in 0 ..< n.childCount {
            if i == 50 && n.childCount > 60 {
                print(pad + "  … \(n.childCount - 50) weitere")
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
