import AppKit
import Combine
import HexwerkCore
import HexwerkYARA

/// YARA-X state of one document window: rule files, last scan, highlights.
@MainActor
final class YaraModel: ObservableObject {
    /// Default place for own rules, offered first in the open panel.
    static let rulesDir = HexwerkPaths.yara
    /// Caps hits per pattern so a pattern like `{ 00 00 }` cannot flood the UI.
    static let maxMatchesPerPattern = 100_000

    enum Scope: String, CaseIterable { case file = "Datei", selection = "Auswahl" }

    /// Rule files and folders, shared by all windows and kept across launches.
    @Published var ruleFiles: [URL] = (Settings.shared.stringArray(forKey: "yaraRules") ?? [])
        .map { URL(fileURLWithPath: $0) } {
        didSet { Settings.shared.set(ruleFiles.map(\.path), forKey: "yaraRules") }
    }
    @Published var timeout: Int = Settings.shared.object(forKey: "yaraTimeout") as? Int ?? YaraX.defaultTimeout {
        didSet { Settings.shared.set(timeout, forKey: "yaraTimeout") }
    }
    @Published var scope: Scope = .file

    @Published private(set) var running = false
    @Published private(set) var results: [YaraRuleMatch]?
    @Published private(set) var compileErrors: [YaraDiagnostic] = []
    @Published private(set) var warnings: [YaraDiagnostic] = []
    @Published private(set) var scanError: String?
    @Published private(set) var stale = false
    @Published private(set) var summary = ""
    @Published var expanded: Set<String> = []
    @Published var selectedMatch: YaraPatternMatch?

    /// All match ranges sorted by start, for drawing.
    private(set) var ranges: [Range<UInt64>] = []
    private var task: Task<Void, Never>?

    var matchCount: Int { results?.reduce(0) { $0 + $1.matches.count } ?? 0 }

    // MARK: Rules

    func addRules(_ urls: [URL]) {
        for u in urls where !ruleFiles.contains(u) { ruleFiles.append(u) }
    }

    func removeRules(_ url: URL) { ruleFiles.removeAll { $0 == url } }

    /// Files to compile: folders contribute all .yar/.yara inside.
    private static func expand(_ urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [url] }
            guard isDir.boolValue else { return [url] }
            return (FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .filter { ["yar", "yara"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.path < $1.path }
        }
    }

    // MARK: Scan

    func scan(_ snapshot: Snapshot, selection: Range<UInt64>?) {
        task?.cancel()
        let range = scope == .selection ? selection : nil
        let files = Self.expand(ruleFiles)
        let timeout = timeout
        let cap = Self.maxMatchesPerPattern
        running = true
        scanError = nil
        compileErrors = []
        summary = ""
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let start = Date()
            var hits: [YaraRuleMatch]?
            var warn: [YaraDiagnostic] = []
            var compileErrors: [YaraDiagnostic] = []
            var failure: String?
            do {
                let rules = try YaraRules.compile(files: files)
                warn = rules.warnings
                hits = try rules.scan(snapshot, range: range, timeout: timeout,
                                      maxMatchesPerPattern: cap)
            } catch let e as YaraCompileError {
                compileErrors = e.diagnostics
            } catch {
                failure = String(describing: error)
            }
            let elapsed = Date().timeIntervalSince(start)
            let cancelled = Task.isCancelled
            await MainActor.run {
                guard let self, !cancelled else { return }
                self.running = false
                self.warnings = warn
                self.compileErrors = compileErrors
                self.scanError = failure
                if let hits { self.show(hits, range: range, size: snapshot.count, elapsed: elapsed) }
            }
        }
    }

    /// The scan itself cannot be interrupted (YARA-X has no cancel call); it
    /// stops at the timeout at the latest and its result is discarded.
    func cancel() {
        task?.cancel()
        task = nil
        running = false
        scanError = "Abgebrochen"
    }

    func contentChanged() { if results != nil { stale = true } }

    private func show(_ hits: [YaraRuleMatch], range: Range<UInt64>?, size: UInt64, elapsed: TimeInterval) {
        results = hits
        stale = false
        selectedMatch = nil
        ranges = hits.flatMap { $0.matches.map(\.range) }.filter { !$0.isEmpty }
            .sorted { $0.lowerBound < $1.lowerBound }
        expanded = hits.count <= 3 ? Set(hits.map(\.id)) : []
        let scanned = range.map { "Auswahl \(hex($0.lowerBound))–\(hex($0.upperBound - 1))" } ?? "ganze Datei"
        summary = "\(hits.count) \(hits.count == 1 ? "Regel" : "Regeln") · \(matchCount) Treffer · \(scanned) · "
            + String(format: "%.2f s", elapsed)
    }

    func clear() {
        results = nil
        ranges = []
        summary = ""
        stale = false
        selectedMatch = nil
    }

    // MARK: Drawing

    func highlights(in window: Range<UInt64>) -> [(Range<UInt64>, NSColor)] {
        guard !ranges.isEmpty else { return [] }
        // Matches may overlap, so the sorted list is not disjoint: scan from
        // the first range starting at or after window start minus a margin.
        var lo = 0, hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ranges[mid].lowerBound < window.lowerBound { lo = mid + 1 } else { hi = mid }
        }
        var i = max(0, lo - 256)
        var out: [(Range<UInt64>, NSColor)] = []
        let color = NSColor.systemPink.withAlphaComponent(0.30)
        while i < ranges.count, ranges[i].lowerBound < window.upperBound {
            if ranges[i].overlaps(window) { out.append((ranges[i], color)) }
            i += 1
        }
        if let m = selectedMatch, m.range.overlaps(window) {
            out.append((m.range, NSColor.systemPink.withAlphaComponent(0.7)))
        }
        return out
    }
}
