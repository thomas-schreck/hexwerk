import ArgumentParser
import Foundation
import HexwerkCore
import HexwerkMagic

struct FileType: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: L("Detect the file type (libmagic + signatures) and search for embedded files.")
    )

    @Argument(help: .init(L("File"))) var file: String
    @Flag(name: .shortAndLong, help: .init(L("Also search for embedded files (like binwalk)"))) var embedded = false
    @Flag(help: .init(L("Output as JSON"))) var json = false

    func run() throws {
        let snap = try openSnapshot(file)
        let desc = Magic.describe(snap)
        let mime = Magic.mime(snap)
        let sigs = FileSignatures.detect(snap)
        let emb = embedded ? FileSignatures.scanEmbedded(snap) : []
        if emb.count >= FileSignatures.maxEmbeddedHits { reportStopped(FileSignatures.maxEmbeddedHits) }
        if json {
            func hit(_ h: SignatureHit) -> [String: Any] {
                ["offset": h.offset, "name": h.name, "ext": h.ext, "kaitai": h.kaitai ?? NSNull()]
            }
            var obj: [String: Any] = ["description": desc ?? NSNull(), "mime": mime ?? NSNull(), "signatures": sigs.map(hit)]
            if embedded { obj["embedded"] = emb.map(hit) }
            try printJSON(obj)
            return
        }
        // libmagic quotes strings from the file (titles, names) in its description.
        print(L("Type       %@", desc.map { TerminalText.escape($0) } ?? L("— (no libmagic database)")))
        if let mime { print("MIME       \(TerminalText.escape(mime))") }
        if let s = sigs.first {
            print(L("Signature  %@", s.title) + (s.kaitai.map { L(" → Kaitai format %@", $0) } ?? ""))
        }
        guard embedded else { return }
        print(emb.isEmpty ? L("Embedded: nothing found") : L("Embedded (%ld):", emb.count))
        for h in emb {
            print("  0x" + String(h.offset, radix: 16, uppercase: true) + "  \(h.title)")
        }
    }
}
