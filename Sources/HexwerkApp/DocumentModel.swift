import AppKit
import Combine
import HexwerkCore
import HexwerkScript

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
    let rules: HighlightRulesModel

    // Cursor and selection mirror the hex view.
    @Published private(set) var cursor: UInt64 = 0
    @Published private(set) var selection: Range<UInt64>?
    @Published var insertMode = false
    @Published var endian: Endian = .little { didSet { refreshInspector() } }
    @Published private(set) var inspectorValues: [InspectorValue] = []
    /// Bumped on every content change, so views can react.
    @Published private(set) var revision = 0

    // View options.
    @Published var bytesPerRowSetting = 16  // 0 = fit window
    @Published var decimalOffsets = false
    /// Base address: the address of offset 0 (Intel HEX / S-Record import,
    /// View > Base Address). Shown in the offset column, hit lists and the
    /// status bar and accepted by "go to"; the content never changes.
    @Published var offsetBase: UInt64 = 0
    var addresses: AddressMap { AddressMap(base: offsetBase) }
    /// "0x..." address of a file offset, as the offset column shows it.
    func addressText(_ offset: UInt64) -> String { hex(addresses.address(of: offset)) }

    /// Vim key bindings (View → Vim Key Bindings), app-wide.
    @Published var vimEnabled = Settings.shared.bool(forKey: "vimMode")
    var vim = VimMachine()
    @Published private(set) var vimStatus = VimMachine().status
    func vimStatusChanged() { vimStatus = vim.status }

    /// Set when the file was imported from Intel HEX / S-Record: saving
    /// writes that format back to `source`.
    struct ImportInfo {
        let source: URL
        let format: HexRecords.Format
        /// Address of the image's first byte; Save writes the records there
        /// even if the displayed base address was changed.
        let base: UInt64
        let gaps: [Range<UInt64>]
        let start: UInt64?
        var startSegment: UInt32? = nil
        let header: String?
    }
    var importInfo: ImportInfo?
    @Published var charset: TextEncodingView = .utf8

    // Search.
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

    // Diff.
    @Published private(set) var diffs: [DiffOp] = []
    @Published private(set) var diffFile: URL?
    /// The comparison stopped at `Search.maxHits`; there are more differences.
    @Published private(set) var diffsTruncated = false
    /// Edited since `diffs` were computed; a new comparison is due or running.
    /// Taking over differences waits for it, their offsets may be off.
    @Published private(set) var diffStale = false
    @Published private(set) var diffRunning = false
    /// The other file's content: the diff follows edits of this one (#143).
    private var diffOther: Snapshot?
    private var diffTask: Task<Void, Never>?
    private var diffGate = RunGate()
    private var rediffPending = false
    private var rediffTimer: DispatchWorkItem?

    // Bookmarks.
    @Published var bookmarks: [Bookmark] = []
    /// Result of the last "Bookmark All" (shown in the bookmarks tab).
    @Published var bookmarkMessage: String?
    /// Ranges colored by the last script run (`hw.highlight`), kept on their
    /// data like bookmarks.
    @Published var scriptHighlights: [ScriptHighlight] = []

    // Checksums.
    @Published private(set) var checksums: [Checksum: String] = [:]
    /// Ranges left out of the checksums (e.g. the checksum field itself);
    /// they move with edits like bookmarks.
    @Published var checksumExclusions: [Range<UInt64>] = []
    @Published private(set) var checksumScope = ""
    @Published private(set) var checksumRunning = false
    private var checksumTask: Task<Void, Never>?
    /// Only the latest run on unchanged content may fill the table.
    private var checksumGate = RunGate()
    /// Which algorithms to compute; remembered across launches.
    @Published var checksumSelection: Set<Checksum> = Set(
        (Settings.shared.stringArray(forKey: "checksums") ?? Checksum.common.map(\.rawValue)).compactMap(Checksum.init(rawValue:))
    )
    {
        didSet { Settings.shared.set(checksumSelection.map(\.rawValue), forKey: "checksums") }
    }

    /// Remembered across windows and launches.
    @Published var sidebarTab: SidebarTab = SidebarTab(stored: Settings.shared.string(forKey: "sidebarTab") ?? "") ?? .data {
        didSet { Settings.shared.set(sidebarTab.rawValue, forKey: "sidebarTab") }
    }

    /// Back/forward through jumps (#140).
    var history = NavigationHistory()
    /// "Mark Selection Start" position, for "Mark Selection End".
    var selectionMark: UInt64?

    /// File offset an integer value points to, nil outside the file. The
    /// value is an address: the base address (#143) is subtracted; the end
    /// of the file is allowed like in "go to".
    func pointerOffset(_ value: UInt64) -> UInt64? {
        addresses.offset(of: value, count: doc.count)
    }

    /// Follow pointer: jumps to the offset `value` points to (recorded for Back).
    func followPointer(_ value: UInt64) {
        guard let off = pointerOffset(value) else { NSSound.beep(); return }
        jump?(off, nil)
    }

    /// Moves the hex view (set by the window controller).
    var jump: ((_ cursor: UInt64, _ select: Range<UInt64>?) -> Void)?
    /// Re-syncs the hex view after an edit made outside it.
    var reloadView: (() -> Void)?

    // Inspector editing.
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
    /// Search and diff share `task`; results of an older run or of edited
    /// content must never be shown (Replace would hit shifted offsets).
    private var searchGate = RunGate()

    init(doc: Document) {
        self.doc = doc
        rules = HighlightRulesModel(doc: doc)
        refreshInspector()
        // Edits arrive synchronously from main-thread code (hex view, inspector, replace).
        doc.didReplace = { [weak self] range, n in
            MainActor.assumeIsolated {
                self?.shiftBookmarks(replacing: range, newLength: n)
                self?.history.adjust(replacing: range, newLength: n)
            }
        }
    }

    /// Raw values are stored in settings.json ("sidebarTab").
    enum SidebarTab: String, CaseIterable {
        case data, structure, yara, analysis, script, strings, image, hits, bookmarks, checksums

        /// Also accepts the German raw values stored before issue #40.
        init?(stored: String) {
            let legacy: [String: SidebarTab] = [
                "Daten": .data, "Struktur": .structure, "YARA": .yara, "Analyse": .analysis, "Skript": .script,
                "Strings": .strings, "Bild": .image, "Treffer": .hits, "Lesezeichen": .bookmarks,
                "Pr\u{FC}fsummen": .checksums,
            ]
            guard let tab = SidebarTab(rawValue: stored) ?? legacy[stored] else { return nil }
            self = tab
        }

        var title: String {
            switch self {
            case .data: L("Data")
            case .structure: L("Structure")
            case .yara: "YARA"
            case .analysis: L("Analysis")
            case .script: L("Script")
            case .strings: L("Strings")
            case .image: L("Image")
            case .hits: L("Hits")
            case .bookmarks: L("Bookmarks")
            case .checksums: L("Checksums")
            }
        }
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

    struct ScriptHighlight: Equatable {
        var range: Range<UInt64>
        var color: NSColor
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
        searchGate.contentChanged()
        if searching {
            cancelSearch()
            findMessage = L("Content changed – search again")
        }
        // Undo/redo can shorten the file without telling us the range.
        clampBookmarks()
        if !hits.isEmpty || currentHit != nil {
            hits = []
            currentHit = nil
            findMessage = L("Content changed – search again")
        }
        diffGate.contentChanged()
        if diffOther != nil {
            diffStale = true
            scheduleRediff()
        }
        checksums = [:]
        checksumGate.contentChanged()
        if checksumRunning { cancelChecksums() }
        structure.contentChanged()
        yara.contentChanged()
        analysis.contentChanged()
        strings.contentChanged()
        rules.contentChanged()
        refreshInspector()
    }

    // MARK: Search

    func pattern(_ text: String) -> SearchPattern? {
        switch findMode {
        case .hex: .hex(text)
        case .text: .text(text, encoding: textEncoding, ignoreCase: ignoreCase)
        case .regex: nil  // handled by RegexSearch in runSearch
        default: .number(text, kind: SearchPattern.NumberKind(rawValue: findMode.rawValue.lowercased())!, endian: endian)
        }
    }

    func runSearch(thenSelect index: Int? = nil) {
        // Before validating: an invalid pattern must not let the old search deliver.
        cancelSearch()
        if findMode == .regex { runRegexSearch(thenSelect: index); return }
        guard let p = pattern(findText) else {
            findMessage = findText.isEmpty ? nil : L("Invalid pattern")
            hits = []
            currentHit = nil
            return
        }
        searching = true
        progress = 0
        findMessage = nil
        let snapshot = doc.snapshot()
        let start = cursor
        let ticket = searchGate.begin()
        task = Task.detached(priority: .userInitiated) { [weak self] in
            var throttle = ProgressThrottle()
            let found = Search.find(p, in: snapshot) { fraction in
                if throttle.shouldReport() { Task { @MainActor in self?.progress = fraction } }
                return !Task.isCancelled
            }
            let cancelled = Task.isCancelled
            await MainActor.run {
                guard let self, !cancelled, self.searchGate.finish(ticket) == .current else { return }
                self.searching = false
                self.hits = found
                self.findMessage =
                    found.isEmpty
                    ? L("No hits")
                    : found.count >= Search.maxHits ? L("more than %ld hits", Search.maxHits) : nil
                // First hit at or after the cursor, like a text editor.
                let i = index ?? found.firstIndex { $0.lowerBound >= start } ?? 0
                if !found.isEmpty { self.select(hit: min(i, found.count - 1)) }
            }
        }
    }

    /// Regex over raw bytes (each byte one Latin-1 character).
    private func runRegexSearch(thenSelect index: Int?) {
        guard !findText.isEmpty else { hits = []; currentHit = nil; findMessage = nil; return }
        do { _ = try NSRegularExpression(pattern: findText) } catch {
            findMessage = L("Invalid expression")
            hits = []
            currentHit = nil
            return
        }
        searching = true
        progress = 0
        findMessage = nil
        let snapshot = doc.snapshot(), start = cursor, text = findText, ic = ignoreCase
        let ticket = searchGate.begin()
        task = Task.detached(priority: .userInitiated) { [weak self] in
            var throttle = ProgressThrottle()
            let found =
                (try? RegexSearch.find(text, ignoreCase: ic, in: snapshot) { fraction in
                    if throttle.shouldReport() { Task { @MainActor in self?.progress = fraction } }
                    return !Task.isCancelled
                }) ?? []
            let cancelled = Task.isCancelled
            await MainActor.run {
                guard let self, !cancelled, self.searchGate.finish(ticket) == .current else { return }
                self.searching = false
                self.hits = found
                self.findMessage =
                    found.isEmpty
                    ? L("No hits")
                    : found.count >= Search.maxHits ? L("more than %ld hits", Search.maxHits) : nil
                let i = index ?? found.firstIndex { $0.lowerBound >= start } ?? 0
                if !found.isEmpty { self.select(hit: min(i, found.count - 1)) }
            }
        }
    }

    func cancelSearch() {
        task?.cancel()
        searchGate.cancel()
        searching = false
    }

    /// Stops everything still running for this window (it is closing).
    func cancelBackgroundWork() {
        cancelSearch()
        clearDiff()
        structure.cancel()
        yara.cancel()
        analysis.cancel()
        analysis.cancelEmbedded()
        strings.cancel()
        script.cancel()
        rules.cancel()
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
        if findMode == .regex { return Data(replaceText.utf8) }  // literal text, no back references
        guard let p = pattern(replaceText) else { return nil }
        var out = Data()
        for e in p.elements {
            guard case .byte(let b) = e else { return nil }  // ?? not allowed here
            out.append(b)
        }
        return out
    }

    func replaceCurrent() {
        guard let i = currentHit, hits.indices.contains(i) else { return }
        guard let bytes = replacementBytes() else { findMessage = L("Invalid replacement"); return }
        do {
            try doc.replace(hits[i], with: bytes)
            contentChanged()
            reloadView?()  // the file may have become shorter
            runSearch(thenSelect: i)
        } catch { findMessage = String(describing: error) }
    }

    func replaceAll() {
        guard !hits.isEmpty else { return }
        guard let bytes = replacementBytes() else { findMessage = L("Invalid replacement"); return }
        do {
            let n = hits.count
            try doc.replaceAll(hits, with: bytes)
            contentChanged()
            reloadView?()  // the file may have become shorter
            findMessage = L("%ld replaced", n)
        } catch { findMessage = String(describing: error) }
    }

    // MARK: Diff

    func compare(with url: URL) {
        let other: Snapshot
        do { other = try Document(url: url, readOnly: true).snapshot() } catch { findMessage = String(describing: error); return }
        clearDiff()
        diffOther = other
        diffFile = url  // the hits tab shows the comparison running
        sidebarTab = .hits
        runDiff(file: url, showFirst: true)
    }

    /// Compares the current content with `diffOther`. One run at a time:
    /// a comparison cannot be interrupted and holds both files in memory,
    /// so edits meanwhile only mark a rerun as pending.
    private func runDiff(file url: URL, showFirst: Bool) {
        guard let other = diffOther else { return }
        diffRunning = true
        rediffPending = false
        let mine = doc.snapshot()
        let ticket = diffGate.begin()
        diffTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Realigns after inserted/deleted bytes (positional beyond 256 MiB).
            let d = AlignedDiff.diff(mine, other)
            let truncated = AlignedDiff.isTruncated(d, mine, other)
            await MainActor.run {
                guard let self, self.diffOther != nil else { return }
                let verdict = self.diffGate.finish(ticket)
                guard verdict != .superseded else { return }
                self.diffRunning = false
                if verdict == .current {
                    self.diffs = d
                    self.diffsTruncated = truncated
                    self.diffFile = url
                    self.diffStale = false
                    if showFirst {
                        self.sidebarTab = .hits
                        if let first = d.first { self.show(diff: first) }
                    }
                }
                if self.rediffPending { self.runDiff(file: url, showFirst: false) }
            }
        }
    }

    /// After an edit (also undo/redo), once typing pauses.
    private func scheduleRediff() {
        rediffTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.diffOther != nil else { return }
            if self.diffRunning {
                self.rediffPending = true
            } else if let url = self.diffFile {
                self.runDiff(file: url, showFirst: false)
            }
        }
        rediffTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    func clearDiff() {
        diffTask?.cancel()
        diffTask = nil
        diffGate.cancel()
        rediffTimer?.cancel()
        rediffPending = false
        diffOther = nil
        diffRunning = false
        diffStale = false
        diffs = []
        diffFile = nil
        diffsTruncated = false
    }

    /// The difference at the cursor (where "next difference" puts it).
    var diffAtCursor: DiffOp? {
        diffs.first { $0.a.isEmpty ? $0.a.lowerBound == cursor : $0.a.contains(cursor) }
    }

    /// Taking over is possible: an up-to-date diff of an editable document.
    var canTakeOver: Bool { diffOther != nil && !diffStale && !diffRunning && !doc.isReadOnly && !diffs.isEmpty }

    /// Merge: copies the difference at the cursor, or all differences, from
    /// the other file into this one. One undo step; the diff then updates.
    func takeOver(all: Bool) { takeOver(all ? diffs : diffAtCursor.map { [$0] } ?? [], all: all) }

    func takeOver(_ ops: [DiffOp], all: Bool = false) {
        guard canTakeOver, let other = diffOther else { NSSound.beep(); return }
        guard let first = ops.first else { NSSound.beep(); return }
        let size = Document.takeOverSize(ops)
        guard size <= FillPattern.maximum else {
            findMessage = L(
                "Too much data to take over (%@).", ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .binary))
            return
        }
        do { try doc.takeOver(ops, from: other) } catch {
            findMessage = String(describing: error)
            return
        }
        contentChanged()
        reloadView?()
        if !all { jump?(min(first.a.lowerBound, doc.count), nil) }
    }

    func jumpToDiff(forward: Bool) {
        let target =
            forward
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
        let range = selection ?? 0 ..< doc.count
        let excluded = checksumExclusions
        checksumScope = selection == nil ? L("Whole file") : L("Selection, %ld bytes", range.count)
        let skipped = range.count - Checksum.included(range, excluding: excluded).reduce(0) { $0 + $1.count }
        if skipped > 0 { checksumScope += ", " + L("%ld bytes excluded", skipped) }
        checksumTask?.cancel()
        checksumRunning = true
        checksums = [:]
        let snapshot = doc.snapshot()
        let algos = checksumSelection
        let ticket = checksumGate.begin()
        checksumTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Checksum.compute(
                Checksum.allCases.filter { algos.contains($0) }, snapshot, range: range, excluding: excluded,
                progress: { _ in !Task.isCancelled })
            await MainActor.run {
                guard let self, let result, self.checksumGate.finish(ticket) == .current else { return }
                self.checksums = result
                self.checksumRunning = false
            }
        }
    }

    /// Adds the selection (or the byte at the cursor) to the exclusions.
    func excludeSelectionFromChecksums() {
        let r = selection ?? cursor ..< min(doc.count, cursor + 1)
        guard !r.isEmpty, !checksumExclusions.contains(r) else { return }
        checksumExclusions.append(r)
        checksumExclusions.sort { $0.lowerBound < $1.lowerBound }
    }

    func cancelChecksums() {
        checksumTask?.cancel()
        checksumTask = nil
        checksumGate.cancel()
        checksumRunning = false
    }

    // MARK: Bookmarks

    static let bookmarkColors: [NSColor] = [.systemBlue, .systemGreen, .systemPurple, .systemPink, .systemTeal, .systemIndigo]

    func addBookmark(name: String) {
        let range = selection ?? cursor ..< min(doc.count, cursor + 1)
        let color = Self.bookmarkColors[bookmarks.count % Self.bookmarkColors.count]
        bookmarks.append(Bookmark(name: name.isEmpty ? L("Bookmark %ld", bookmarks.count + 1) : name, range: range, color: color))
        bookmarks.sort { $0.range.lowerBound < $1.range.lowerBound }
        sidebarTab = .bookmarks
    }

    /// One bookmark per hit (search, YARA, strings) not bookmarked yet (#142).
    func bookmarkAll(_ hits: [(label: String, range: Range<UInt64>)]) {
        let r = HitBookmarks.make(hits, existing: bookmarks.map(\.range))
        var marks = bookmarks
        for (name, range) in r.added {
            marks.append(Bookmark(name: name, range: range, color: Self.bookmarkColors[marks.count % Self.bookmarkColors.count]))
        }
        marks.sort { $0.range.lowerBound < $1.range.lowerBound }
        bookmarks = marks
        var message = r.added.count == 1 ? L("1 bookmark added") : L("%ld bookmarks added", r.added.count)
        if r.duplicates > 0 { message += " · " + L("%ld already bookmarked", r.duplicates) }
        if r.overLimit > 0 { message += " · " + L("%1$ld left out (at most %2$ld at once)", r.overLimit, HitBookmarks.limit) }
        bookmarkMessage = message
        sidebarTab = .bookmarks
    }

    /// Bookmarks and highlights a script asked for (`hw.bookmark`,
    /// `hw.highlight`); the helper's ranges were checked against the size.
    func applyScriptAnnotations(_ annotations: [ScriptAnnotation]) {
        var highlights: [ScriptHighlight] = []
        var marks = bookmarks
        // Running a script twice must not double its bookmarks.
        var seen = Set(marks.map { "\($0.range)\u{0}\($0.name)" })
        for a in annotations {
            guard let range = a.range.clampedToDocument(count: doc.count) else { continue }
            switch a.kind {
            case .bookmark(let name):
                guard seen.insert("\(range)\u{0}\(name)").inserted else { continue }
                let color = Self.bookmarkColors[marks.count % Self.bookmarkColors.count]
                marks.append(Bookmark(name: name, range: range, color: color))
            case .highlight(let c):
                highlights.append(ScriptHighlight(range: range, color: Self.color(c)))
            }
        }
        if marks.count != bookmarks.count {
            marks.sort { $0.range.lowerBound < $1.range.lowerBound }
            bookmarks = marks
        }
        scriptHighlights = highlights
    }

    static func color(_ c: ScriptAnnotation.Color) -> NSColor {
        let base: NSColor =
            switch c {
            case .yellow: .systemYellow
            case .red: .systemRed
            case .orange: .systemOrange
            case .green: .systemGreen
            case .blue: .systemBlue
            case .purple: .systemPurple
            case .pink: .systemPink
            case .gray: .systemGray
            }
        return base.withAlphaComponent(0.35)
    }

    /// Keeps bookmarks on their data when bytes are inserted or deleted.
    private func shiftBookmarks(replacing range: Range<UInt64>, newLength: UInt64) {
        guard UInt64(range.count) != newLength else { return }  // overwrite: nothing moves
        let moved = bookmarks.compactMap { b -> Bookmark? in
            guard let r = b.range.adjustedForEdit(replacing: range, newLength: newLength) else { return nil }
            var b = b
            b.range = r
            return b
        }
        if moved != bookmarks { bookmarks = moved }
        let excl = checksumExclusions.compactMap { $0.adjustedForEdit(replacing: range, newLength: newLength) }
        if excl != checksumExclusions { checksumExclusions = excl }
        if !scriptHighlights.isEmpty {
            scriptHighlights = scriptHighlights.compactMap { h in
                h.range.adjustedForEdit(replacing: range, newLength: newLength).map { ScriptHighlight(range: $0, color: h.color) }
            }
        }
    }

    private func clampBookmarks() {
        let n = doc.count
        if checksumExclusions.contains(where: { $0.upperBound > n }) {
            checksumExclusions = checksumExclusions.compactMap { $0.clampedToDocument(count: n) }
        }
        if scriptHighlights.contains(where: { $0.range.upperBound > n }) {
            scriptHighlights = scriptHighlights.compactMap { h in
                h.range.clampedToDocument(count: n).map { ScriptHighlight(range: $0, color: h.color) }
            }
        }
        guard bookmarks.contains(where: { $0.range.upperBound > n }) else { return }
        bookmarks = bookmarks.compactMap { b in
            guard let r = b.range.clampedToDocument(count: n) else { return nil }
            var b = b
            b.range = r
            return b
        }
    }

    // MARK: Highlights for drawing

    /// Colored ranges intersecting `window`, in drawing order (later on top).
    func highlights(in window: Range<UInt64>) -> [(Range<UInt64>, NSColor)] {
        // Structure colors lie underneath everything else.
        var out = structure.highlights(in: window)
        out += rules.highlights(in: window)
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
        for h in scriptHighlights where h.range.overlaps(window) { out.append((h.range, h.color)) }
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
        return ranges[lo ..< end]
    }
}
