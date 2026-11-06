import AppKit
import Combine
import HexwerkCore
import HexwerkScript

/// JavaScript runner of one window (SPEC FR-9.2). The script runs in the
/// background on a working copy; the result is adopted as one undo step.
@MainActor
final class ScriptModel: ObservableObject {
    static let scriptsDir = HexwerkPaths.scripts

    /// Editor text, kept across launches (shared by all windows).
    @Published var source: String = Settings.shared.string(forKey: "scriptSource") ?? ScriptModel.examples[0].1 {
        didSet { Settings.shared.set(source, forKey: "scriptSource") }
    }
    @Published var fileURL: URL?
    @Published private(set) var running = false
    @Published private(set) var output: [String] = []
    @Published private(set) var error: ScriptError?
    @Published private(set) var status = ""

    private var cancelFlag = CancelFlag()

    func run(on doc: Document, cursor: UInt64, selection: Range<UInt64>?,
             done: @escaping (_ changed: Bool, ScriptResult) -> Void) {
        guard !running else { return }
        let base = doc.snapshot()
        let copy = Document(editing: base, readOnly: doc.isReadOnly)
        let ctx = ScriptContext(cursor: cursor, selection: selection, fileName: doc.url.lastPathComponent)
        let source = source
        let name = fileURL?.lastPathComponent ?? "Skript"
        let flag = CancelFlag()
        cancelFlag = flag
        running = true
        output = []
        error = nil
        status = ""
        let start = Date()
        // The copy is only touched by the background task until it is adopted.
        let box = UncheckedBox(copy)
        Task { [weak self] in
            let r = await Task.detached(priority: .userInitiated) {
                ScriptRunner.run(source, name: name, document: box.value, context: ctx, isCancelled: { flag.value })
            }.value
            let elapsed = Date().timeIntervalSince(start)
            guard let self else { return }
            running = false
            output = r.output
            error = r.error
            var changed = false
            if r.error == nil, copy.isModified {
                do {
                    try doc.adopt(copy, base: base)
                    changed = true
                } catch {
                    self.error = ScriptError(message: "Nicht übernommen: \(error)", line: nil)
                }
            }
            status = (self.error == nil ? "Fertig" : "Fehler") + String(format: " nach %.2f s", elapsed)
                + (changed ? " · \(r.edits) Änderung\(r.edits == 1 ? "" : "en") (⌘Z macht alle rückgängig)" : "")
            done(changed, r)
        }
    }

    func cancel() { cancelFlag.value = true }

    // MARK: Files

    func open() {
        let panel = NSOpenPanel()
        try? FileManager.default.createDirectory(at: Self.scriptsDir, withIntermediateDirectories: true)
        panel.directoryURL = Self.scriptsDir
        panel.message = "JavaScript-Datei öffnen"
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        source = text
        fileURL = url
    }

    func save(as: Bool) {
        var url = fileURL
        if url == nil || `as` {
            let panel = NSSavePanel()
            try? FileManager.default.createDirectory(at: Self.scriptsDir, withIntermediateDirectories: true)
            panel.directoryURL = Self.scriptsDir
            panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "skript.js"
            guard panel.runModal() == .OK else { return }
            url = panel.url
        }
        guard let url else { return }
        do {
            try source.write(to: url, atomically: true, encoding: .utf8)
            fileURL = url
        } catch {
            self.error = ScriptError(message: error.localizedDescription, line: nil)
        }
    }

    func load(example i: Int) {
        source = Self.examples[i].1
        fileURL = nil
    }

    static let examples: [(String, String)] = [
        ("Byte-Statistik", """
        // Zählt Nullbytes und druckbare Zeichen der Auswahl oder Datei.
        const s = hw.selection ?? { start: 0, end: hw.size() }
        const d = hw.read(s.start, s.end - s.start)
        let zeros = 0, printable = 0
        for (const b of d) {
          if (b === 0) zeros++
          if (b >= 0x20 && b < 0x7f) printable++
        }
        print(`${d.length} Byte, ${zeros} × 0x00, ${printable} druckbar`)
        """),
        ("Auswahl XOR", """
        // XOR der Auswahl mit einem Schlüssel (ein Undo-Schritt).
        const key = [0x5a]
        const s = hw.selection
        if (!s) throw new Error("Bitte erst Bytes auswählen")
        const d = hw.read(s.start, s.end - s.start)
        for (let i = 0; i < d.length; i++) d[i] ^= key[i % key.length]
        hw.write(s.start, d)
        hw.select(s.start, s.end)
        """),
        ("Strings finden", """
        // Druckbare ASCII-Folgen ab 6 Zeichen, wie `strings`.
        const min = 6, d = hw.read(0, hw.size())
        let start = -1, found = 0
        for (let i = 0; i <= d.length; i++) {
          const ok = i < d.length && d[i] >= 0x20 && d[i] < 0x7f
          if (ok && start < 0) start = i
          if (!ok && start >= 0) {
            if (i - start >= min && found++ < 200) print("0x" + start.toString(16), hw.str(start, i - start))
            start = -1
          }
        }
        print(`${found} Strings`)
        """),
        ("PNG-Chunks", """
        // Listet die Chunks einer PNG-Datei auf und springt zum ersten IDAT.
        if (hw.hex(0, 4) !== "89 50 4E 47") throw new Error("keine PNG-Datei")
        let off = 8
        while (off + 8 <= hw.size()) {
          const len = hw.u32(off, false), type = hw.str(off + 4, 4)
          print("0x" + off.toString(16), type, len)
          if (type === "IDAT") hw.goto(off)
          if (type === "IEND") break
          off += 12 + len
        }
        """),
    ]
}

final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Set from the main thread, read by the script's watchdog.
final class CancelFlag: @unchecked Sendable {
    var value = false
}
