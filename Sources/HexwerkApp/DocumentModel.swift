import AppKit
import Combine
import HexwerkCore

/// Everything a document window shows besides the raw bytes: cursor,
/// search, bookmarks, diff, checksums, view options. Shared between the
/// AppKit hex view and the SwiftUI panels.
@MainActor
final class DocumentModel: ObservableObject {
    let doc: Document
    let structure = StructureModel()
    let yara = YaraModel()
    let analysis = AnalysisModel()
    let script = ScriptModel()
    let strings = StringsModel()
    let image = ImageModel()

    // Cursor and selection mirror the hex view.
    @Published private(set) var cursor: UInt64 = 0
    @Published private(set) var selection: Range<UInt64>?
    @Published var insertMode = false
    @Published var endian: Endian = .little { didSet { refreshInspector() } }
    @Published private(set) var inspectorValues: [InspectorValue] = []
    /// Bumped on every content change, so views can react.
    @Published private(set) var revision = 0

    // View options (SPEC FR-2.6–2.8).
    @Published var bytesPerRowSetting = 16          // 0 = fit window
    @Published var decimalOffsets = false
    /// Load address of offset 0 (Intel HEX / S-Record import); shown in
    /// the offset column and accepted by "go to".
    @Published var offsetBase: UInt64 = 0

    /// Vim key bindings (Darstellung → Vim-Tastenkürzel), app-wide.
    @Published var vimEnabled = Settings.shared.bool(forKey: "vimMode")
    var vim = VimMachine()
    @Published private(set) var vimStatus = VimMode.normal.rawValue
    func vimStatusChanged() { vimStatus = vim.status }

    /// Set when the file was imported from Intel HEX / S-Record: saving
    /// writes that format back to `source`.
    struct ImportInfo {
        let source: URL
        let format: HexRecords.Format
        let gaps: [Range<UInt64>]
        let start: UInt64?
        let header: String?
    }
    var importInfo: ImportInfo?
    @Published var charset: TextEncodingView = .utf8

    // Search (FR-5.x).
    @Published var findVisible = false
    @Published var findText = ""
    @Published var findMode: FindMode = .hex
    @Published var textEncoding: SearchPattern.TextEncoding = .utf8
    @Published var ignoreCase = false
    @Published var replaceText = ""
    @Published var showReplace = false
    @Published private(set) var hits: [Range<UInt64>] = []
    @Published private(set) var currentHit: Int?
    @Published private(set) var searching = false
    @Published private(set) var progress: Double = 0
    @Published var findMessage: String?

    // Diff (FR-5.7).
    @Published private(set) var diffs: [DiffOp] = []
    @Published private(set) var diffFile: URL?

    // Bookmarks (FR-3.6).
    @Published var bookmarks: [Bookmark] = []

    // Checksums (FR-5.8).
    @Published private(set) var checksums: [Checksum: String] = [:]
    @Published private(set) var checksumScope = ""
    @Published private(set) var checksumRunning = false
    /// Which algorithms to compute; remembered across launches.
    @Published var checksumSelection: Set<Checksum> = Set(
        (Settings.shared.stringArray(forKey: "checksums") ?? Checksum.common.map(\.rawValue)).compactMap(Checksum.init(rawValue:))
    ) {
        didSet { Settings.shared.set(checksumSelection.map(\.rawValue), forKey: "checksums") }
    }

    /// Remembered across windows and launches.
    @Published var sidebarTab: SidebarTab = SidebarTab(rawValue: Settings.shared.string(forKey: "sidebarTab") ?? "") ?? .data {
        didSet { Settings.shared.set(sidebarTab.rawValue, forKey: "sidebarTab") }
    }

    /// Moves the hex view (set by the window controller).
    var jump: ((_ cursor: UInt64, _ select: Range<UInt64>?) -> Void)?
    /// Re-syncs the hex view after an edit made outside it.
    var reloadView: (() -> Void)?

    // Inspector editing (FR-4.6).
    @Published var inspectorEditing: String?
    @Published var inspectorText = ""
    @Published var inspectorError: String?

    func beginInspectorEdit(_ name: String, current: String?) {
        guard !doc.isReadOnly else { NSSound.beep(); return }
        inspectorEditing = name
        inspectorText = current.map { Inspector.unquoteForEdit($0, name: name) } ?? ""
        inspectorError = nil
    }

    func commitInspectorEdit() {
        guard let name = inspectorEditing else { return }
        do {
            let bytes = try Inspector.encode(name, inspectorText, endian: endian)
            try doc.overwrite(at: cursor, with: bytes)
            inspectorEditing = nil
            inspectorError = nil
            contentChanged()
            reloadView?()
        } catch {
            inspectorError = String(describing: error)
        }
    }

    func cancelInspectorEdit() { inspectorEditing = nil; inspectorError = nil }

    /// Runs the script tab's script (set by the window controller).
    var runScript: (() -> Void)?

    private var task: Task<Void, Never>?

    init(doc: Document) {
        self.doc = doc
        refreshInspector()
    }

    enum SidebarTab: String, CaseIterable {
        case data = "Daten", structure = "Struktur", yara = "YARA", analysis = "Analyse", script = "Skript", strings = "Strings", image = "Bild", hits = "Treffer", bookmarks = "Lesezeichen", checksums = "Prüfsummen"
        var symbol: String {
            switch self {
            case .data: "number"
            case .structure: "list.bullet.indent"
            case .yara: "shield.lefthalf.filled"
            case .analysis: "waveform.path.ecg"
            case .script: "curlybraces"
            case .strings: "textformat.abc"
            case .image: "photo"
            case .hits: "magnifyingglass"
            case .bookmarks: "bookmark"
            case .checksums: "checkmark.seal"
            }
        }
    }

    enum FindMode: String, CaseIterable, Identifiable {
        case hex = "Hex", text = "Text", regex = "Regex"
        case int8 = "Int8", int16 = "Int16", int32 = "Int32", int64 = "Int64"
        case float32 = "Float32", float64 = "Float64"
        var id: String { rawValue }
    }

    struct Bookmark: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var range: Range<UInt64>
        var color: NSColor
    }

    // MARK: Cursor

    func cursorMoved(_ cursor: UInt64, selection: Range<UInt64>?) {
        self.cursor = cursor
        self.selection = selection
        refreshInspector()
        if sidebarTab == .structure { structure.follow(cursor: cursor) }
    }

    private func refreshInspector() {
        inspectorValues = Inspector.values(doc.read(cursor ..< cursor + UInt64(Inspector.window)), endian: endian)
    }

    /// Called after every edit. Results that depend on the content are stale.
    func contentChanged() {
        revision += 1
        if !hits.isEmpty || currentHit != nil {
            hits = []
            currentHit = nil
            findMessage = "Inhalt geändert – erneut suchen"
        }
        diffs = []
        diffFile = nil
        checksums = [:]
        structure.contentChanged()
        yara.contentChanged()
        analysis.contentChanged()
        strings.contentChanged()
        refreshInspector()
    }

    // MARK: Search

    func pattern(_ text: String) -> SearchPattern? {
        switch findMode {
        case .hex: .hex(text)
        case .text: .text(text, encoding: textEncoding, ignoreCase: ignoreCase)
        case .regex: nil      // handled by RegexSearch in runSearch
        default: .number(text, kind: SearchPattern.NumberKind(rawValue: findMode.rawValue.lowercased())!, endian: endian)
        }
    }

    func runSearch(thenSelect index: Int? = nil) {
        if findMode == .regex { runRegexSearch(thenSelect: index); return }
        guard let p = pattern(findText) else {
            findMessage = findText.isEmpty ? nil : "Ungültiges Muster"
            hits = []
            currentHit = nil
            return
        }
        task?.cancel()
        searching = true
        progress = 0
        findMessage = nil
        let snapshot = doc.snapshot()
        let start = cursor
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let found = Search.find(p, in: snapshot) { fraction in
                Task { @MainActor in self?.progress = fraction }
                return !Task.isCancelled
            }
            let cancelled = Task.isCancelled
            await MainActor.run {
                guard let self, !cancelled else { return }
                self.searching = false
                self.hits = found
                self.findMessage = found.isEmpty ? "Keine Treffer"
                    : found.count >= Search.maxHits ? "mehr als \(Search.maxHits) Treffer" : nil
                // First hit at or after the cursor, like a text editor.
                let i = index ?? found.firstIndex { $0.lowerBound >= start } ?? 0
                if !found.isEmpty { self.select(hit: min(i, found.count - 1)) }
            }
        }
    }

    /// Regex over raw bytes (each byte one Latin-1 character), FR-10.5.
    private func runRegexSearch(thenSelect index: Int?) {
        guard !findText.isEmpty else { hits = []; currentHit = nil; findMessage = nil; return }
        do { _ = try NSRegularExpression(pattern: findText) } catch {
            findMessage = "Ungültiger Ausdruck"
            hits = []
            currentHit = nil
            return
        }
        task?.cancel()
        searching = true
        progress = 0
        findMessage = nil
        let snapshot = doc.snapshot(), start = cursor, text = findText, ic = ignoreCase
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let found = (try? RegexSearch.find(text, ignoreCase: ic, in: snapshot) { fraction in
                Task { @MainActor in self?.progress = fraction }
                return !Task.isCancelled
            }) ?? []
            let cancelled = Task.isCancelled
            await MainActor.run {
                guard let self, !cancelled else { return }
                self.searching = false
                self.hits = found
                self.findMessage = found.isEmpty ? "Keine Treffer"
                    : found.count >= Search.maxHits ? "mehr als \(Search.maxHits) Treffer" : nil
                let i = index ?? found.firstIndex { $0.lowerBound >= start } ?? 0
                if !found.isEmpty { self.select(hit: min(i, found.count - 1)) }
            }
        }
    }

    func cancelSearch() {
        task?.cancel()
        searching = false
    }

    func select(hit i: Int) {
        guard hits.indices.contains(i) else { return }
        currentHit = i
        jump?(hits[i].lowerBound, hits[i])
    }

    func nextHit() {
        guard !hits.isEmpty else { runSearch(); return }
        select(hit: ((currentHit ?? -1) + 1) % hits.count)
    }

    func previousHit() {
        guard !hits.isEmpty else { runSearch(); return }
        select(hit: ((currentHit ?? 0) - 1 + hits.count) % hits.count)
    }

    private func replacementBytes() -> Data? {
        if replaceText.isEmpty { return Data() }
        if findMode == .regex { return Data(replaceText.utf8) }      // literal text, no back references
        guard let p = pattern(replaceText) else { return nil }
        var out = Data()
        for e in p.elements {
            guard case .byte(let b) = e else { return nil }   // ?? not allowed here
            out.append(b)
        }
        return out
    }

    func replaceCurrent() {
        guard let i = currentHit, hits.indices.contains(i) else { return }
        guard let bytes = replacementBytes() else { findMessage = "Ungültige Ersetzung"; return }
        do {
            try doc.replace(hits[i], with: bytes)
            contentChanged()
            reloadView?()                   // the file may have become shorter
            runSearch(thenSelect: i)
        } catch { findMessage = String(describing: error) }
    }

    func replaceAll() {
        guard !hits.isEmpty else { return }
        guard let bytes = replacementBytes() else { findMessage = "Ungültige Ersetzung"; return }
        do {
            let n = hits.count
            try doc.replaceAll(hits, with: bytes)
            contentChanged()
            reloadView?()                   // the file may have become shorter
            findMessage = "\(n) ersetzt"
        } catch { findMessage = String(describing: error) }
    }

    // MARK: Diff

    func compare(with url: URL) {
        let other: Snapshot
        do { other = try Document(url: url, readOnly: true).snapshot() }
        catch { findMessage = String(describing: error); return }
        task?.cancel()
        searching = true
        let mine = doc.snapshot()
        task = Task.detached(priority: .userInitiated) { [weak self] in
            // Realigns after inserted/deleted bytes (positional beyond 256 MiB).
            let d = AlignedDiff.diff(mine, other)
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.searching = false
                self.diffs = d
                self.diffFile = url
                self.sidebarTab = .hits
                if let first = d.first { self.show(diff: first) }
            }
        }
    }

    func clearDiff() {
        diffs = []
        diffFile = nil
    }

    func jumpToDiff(forward: Bool) {
        let target = forward
            ? diffs.first { $0.a.lowerBound > cursor }
            : diffs.last { $0.a.lowerBound < cursor }
        if let t = target ?? (forward ? diffs.first : diffs.last) { show(diff: t) }
    }

    func show(diff d: DiffOp) {
        jump?(min(d.a.lowerBound, doc.count), d.a.isEmpty ? nil : d.a)
    }

    /// Ranges to color in this file: inserts (bytes only in the other file)
    /// mark the byte in front of which they belong.
    func diffHighlight(_ d: DiffOp) -> (Range<UInt64>, NSColor) {
        switch d.kind {
        case .replace: (d.a, NSColor.systemRed.withAlphaComponent(0.28))
        case .delete: (d.a, NSColor.systemOrange.withAlphaComponent(0.30))
        case .insert: (d.a.lowerBound ..< min(doc.count, d.a.lowerBound + 1), NSColor.systemGreen.withAlphaComponent(0.45))
        }
    }

    // MARK: Checksums

    func computeChecksums() {
        let range = selection ?? 0..<doc.count
        checksumScope = selection == nil ? "Ganze Datei" : "Auswahl, \(range.count) Byte"
        checksumRunning = true
        checksums = [:]
        let snapshot = doc.snapshot()
        let algos = checksumSelection
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Checksum.compute(Checksum.allCases.filter { algos.contains($0) }, snapshot, range: range) ?? [:]
            await MainActor.run {
                self?.checksums = result
                self?.checksumRunning = false
            }
        }
    }

    // MARK: Bookmarks

    static let bookmarkColors: [NSColor] = [.systemBlue, .systemGreen, .systemPurple, .systemPink, .systemTeal, .systemIndigo]

    func addBookmark(name: String) {
        let range = selection ?? cursor ..< min(doc.count, cursor + 1)
        let color = Self.bookmarkColors[bookmarks.count % Self.bookmarkColors.count]
        bookmarks.append(Bookmark(name: name.isEmpty ? "Lesezeichen \(bookmarks.count + 1)" : name, range: range, color: color))
        bookmarks.sort { $0.range.lowerBound < $1.range.lowerBound }
        sidebarTab = .bookmarks
    }

    // MARK: Highlights for drawing

    /// Colored ranges intersecting `window`, in drawing order (later on top).
    func highlights(in window: Range<UInt64>) -> [(Range<UInt64>, NSColor)] {
        // Structure colors lie underneath everything else.
        var out = structure.highlights(in: window)
        out += yara.highlights(in: window)
        for r in doc.modifiedRanges where r.overlaps(window) {
            out.append((r, NSColor.systemOrange.withAlphaComponent(0.22)))
        }
        if !diffs.isEmpty {
            // Ops are sorted by A offset: binary search the first visible one.
            var lo = 0, hi = diffs.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if diffs[mid].a.upperBound < window.lowerBound { lo = mid + 1 } else { hi = mid }
            }
            var i = lo
            while i < diffs.count, diffs[i].a.lowerBound <= window.upperBound {
                let h = diffHighlight(diffs[i])
                if h.0.overlaps(window) { out.append(h) }
                i += 1
            }
        }
        for b in bookmarks where b.range.overlaps(window) { out.append((b.range, b.color.withAlphaComponent(0.28))) }
        for r in Self.visible(hits, in: window) { out.append((r, NSColor.systemYellow.withAlphaComponent(0.35))) }
        if let i = currentHit, hits.indices.contains(i), hits[i].overlaps(window) {
            out.append((hits[i], NSColor.systemYellow.withAlphaComponent(0.85)))
        }
        return out
    }

    /// Ranges of a sorted, non-overlapping list that touch `window` (binary search).
    static func visible(_ ranges: [Range<UInt64>], in window: Range<UInt64>) -> ArraySlice<Range<UInt64>> {
        var lo = 0, hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ranges[mid].upperBound <= window.lowerBound { lo = mid + 1 } else { hi = mid }
        }
        var end = lo
        while end < ranges.count && ranges[end].lowerBound < window.upperBound { end += 1 }
        return ranges[lo..<end]
    }
}
