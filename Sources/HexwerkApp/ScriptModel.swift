import AppKit
import Combine
import HexwerkCore
import HexwerkHelper
import HexwerkScript

/// JavaScript runner of one window. The script runs in the
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

    private var cancelTask: (() -> Void)?

    func run(
        on doc: Document, cursor: UInt64, selection: Range<UInt64>?, baseAddress: UInt64,
        done: @escaping (_ changed: Bool, ScriptResult) -> Void
    ) {
        guard !running else { return }
        let base = doc.snapshot()
        let readOnly = doc.isReadOnly
        let ctx = ScriptContext(cursor: cursor, selection: selection, fileName: doc.url.lastPathComponent, baseAddress: baseAddress)
        let source = source
        let name = fileURL?.lastPathComponent ?? L("Script")
        running = true
        output = []
        error = nil
        status = ""
        let start = Date()
        // The script runs in the sandboxed helper on a copy of `base` (#102);
        // its edits come back as a piece list and are adopted as one step.
        let task = Task.detached(priority: .userInitiated) {
            try await HelperClient.shared.runScript(source, name: name, base: base, context: ctx, readOnly: readOnly)
        }
        cancelTask = { task.cancel() }
        Task { [weak self] in
            var r: ScriptResult
            var edited: (EditedContent, AddedMap)?
            do {
                let (outcome, map) = try await task.value
                r = outcome.result
                edited = outcome.edited.map { ($0, map) }
            } catch {
                r = ScriptResult()
                r.error = ScriptError(message: String(describing: error), line: nil)
            }
            let elapsed = Date().timeIntervalSince(start)
            guard let self else { return }
            cancelTask = nil
            running = false
            output = r.output
            error = r.error
            var changed = false
            if r.error == nil, let (content, map) = edited {
                do {
                    try doc.adopt(content, map: map, base: base)
                    changed = true
                } catch {
                    self.error = ScriptError(message: L("Not applied: %@", String(describing: error)), line: nil)
                }
            }
            // Bookmarks and highlights point into the base plus the script's
            // edits: only valid when those were taken over, or when there were
            // none and the file was not edited during the run.
            var dropped = false
            if self.error == nil, !r.annotations.isEmpty {
                if changed || (edited == nil && doc.isUnchanged(since: base)) {
                    do { r.annotations = try ScriptAnnotation.checked(r.annotations, documentCount: doc.count) } catch {
                        r.annotations = []
                        self.error = ScriptError(message: L("Not applied: %@", String(describing: error)), line: nil)
                    }
                } else {
                    r.annotations = []
                    dropped = true
                }
            } else {
                r.annotations = []
            }
            status = self.error == nil ? L("Done after %.2f s", elapsed) : L("Error after %.2f s", elapsed)
            if changed {
                status += " · " + (r.edits == 1 ? L("1 change (⌘Z undoes all)") : L("%ld changes (⌘Z undoes all)", r.edits))
            }
            if !r.annotations.isEmpty {
                status += " · " + L("%ld bookmarks and highlights", r.annotations.count)
            }
            if dropped {
                status += " · " + L("bookmarks and highlights dropped: the file was edited during the run")
            }
            done(changed, r)
        }
    }

    func cancel() { cancelTask?() }

    // MARK: Files

    func open() {
        let panel = NSOpenPanel()
        try? FileManager.default.createDirectory(at: Self.scriptsDir, withIntermediateDirectories: true)
        panel.directoryURL = Self.scriptsDir
        panel.message = L("Open JavaScript File")
        guard panel.runModal() == .OK, let url = panel.url,
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        source = text
        fileURL = url
    }

    func save(as: Bool) {
        var url = fileURL
        if url == nil || `as` {
            let panel = NSSavePanel()
            try? FileManager.default.createDirectory(at: Self.scriptsDir, withIntermediateDirectories: true)
            panel.directoryURL = Self.scriptsDir
            panel.nameFieldStringValue = fileURL?.lastPathComponent ?? L("script.js")
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

    /// Example scripts (menu title, source). The code is English in every language.
    static let examples: [(String, String)] = [
        (
            L("Byte Statistics"),
            """
            // Counts zero bytes and printable characters in the selection or file.
            const s = hw.selection ?? { start: 0, end: hw.size() }
            const d = hw.read(s.start, s.end - s.start)
            let zeros = 0, printable = 0
            for (const b of d) {
              if (b === 0) zeros++
              if (b >= 0x20 && b < 0x7f) printable++
            }
            print(`${d.length} bytes, ${zeros} × 0x00, ${printable} printable`)
            """
        ),
        (
            L("XOR Selection"),
            """
            // XORs the selection with a key (one undo step).
            const key = [0x5a]
            const s = hw.selection
            if (!s) throw new Error("Select some bytes first")
            const d = hw.read(s.start, s.end - s.start)
            for (let i = 0; i < d.length; i++) d[i] ^= key[i % key.length]
            hw.write(s.start, d)
            hw.select(s.start, s.end)
            """
        ),
        (
            L("Find Strings"),
            """
            // Printable ASCII runs of 6 or more characters, like `strings`.
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
            """
        ),
        (
            L("PNG Chunks"),
            """
            // Lists the chunks of a PNG file and jumps to the first IDAT.
            if (hw.hex(0, 4) !== "89 50 4E 47") throw new Error("not a PNG file")
            let off = 8
            while (off + 8 <= hw.size()) {
              const len = hw.u32(off, false), type = hw.str(off + 4, 4)
              print("0x" + off.toString(16), type, len)
              if (type === "IDAT") hw.goto(off)
              if (type === "IEND") break
              off += 12 + len
            }
            """
        ),
    ]
}
