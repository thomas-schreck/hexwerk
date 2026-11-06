import ArgumentParser
import Foundation
import HexwerkCore
import HexwerkMagic

struct FileType: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Dateityp erkennen (libmagic + Signaturen) und eingebettete Dateien suchen."
    )

    @Argument(help: "Datei") var file: String
    @Flag(name: .shortAndLong, help: "Auch eingebettete Dateien suchen (wie binwalk)") var embedded = false
    @Flag(help: "Ausgabe als JSON") var json = false

    func run() throws {
        let snap = try openSnapshot(file)
        let desc = Magic.describe(snap)
        let mime = Magic.mime(snap)
        let sigs = FileSignatures.detect(snap)
        let emb = embedded ? FileSignatures.scanEmbedded(snap) : []
        if json {
            func hit(_ h: SignatureHit) -> [String: Any] {
                ["offset": h.offset, "name": h.name, "ext": h.ext, "kaitai": h.kaitai ?? NSNull()]
            }
            var obj: [String: Any] = ["description": desc ?? NSNull(), "mime": mime ?? NSNull(), "signatures": sigs.map(hit)]
            if embedded { obj["embedded"] = emb.map(hit) }
            try printJSON(obj)
            return
        }
        print("Typ        \(desc ?? "— (keine libmagic-Datenbank)")")
        if let mime { print("MIME       \(mime)") }
        if let s = sigs.first {
            print("Signatur   \(s.name)" + (s.kaitai.map { " → Kaitai-Format \($0)" } ?? ""))
        }
        guard embedded else { return }
        print(emb.isEmpty ? "Eingebettet: nichts gefunden" : "Eingebettet (\(emb.count)):")
        for h in emb {
            print("  0x" + String(h.offset, radix: 16, uppercase: true) + "  \(h.name)")
        }
    }
}
