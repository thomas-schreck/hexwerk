import AppKit
import Combine
import HexwerkCore
import HexwerkHelper
import HexwerkYARA

/// YARA-X state of one document window: rule files, last scan, highlights.
@MainActor
final class YaraModel: ObservableObject {
    /// Default place for own rules, offered first in the open panel.
    static let rulesDir = HexwerkPaths.yara
    /// Caps hits per pattern so a pattern like `{ 00 00 }` cannot flood the UI.
    static let maxMatchesPerPattern = 100_000

    enum Scope: CaseIterable {
        case file, selection
        var title: String { self == .file ? L("Entire File") : L("Selection") }
    }

    /// Rule files and folders, shared by all windows and kept across launches.
    @Published var ruleFiles: [URL] = (Settings.shared.stringArray(forKey: "yaraRules") ?? [])
        .map { URL(fileURLWithPath: $0) }
    {
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
    /// What the last scan covered; `summary(_:)` turns it into text, so
    /// the scanned range follows the base address and offset format (#149).
    struct ScanInfo: Equatable {
        let range: Range<UInt64>?
        let elapsed: TimeInterval
    }
    @Published private(set) var lastScan: ScanInfo?
    @Published var expanded: Set<String> = []
    @Published var selectedMatch: YaraPatternMatch?

    /// All match ranges sorted by start, for drawing.
    private(set) var ranges: [Range<UInt64>] = []
    private var task: Task<Void, Never>?
    /// Marks a result stale when the content was edited while it was computed.
    private var gate = RunGate()

    /// "2 rules · 5 hits · selection 0x10–0x1F · 0.01 s"; empty before a scan.
    /// `address` formats the scanned range like the offset column.
    func summary(_ address: (Range<UInt64>) -> String) -> String {
        guard let scan = lastScan, let hits = results else { return "" }
        let scanned = scan.range.map { L("selection %@", address($0)) } ?? L("whole file")
        let rules = hits.count == 1 ? L("1 rule") : L("%ld rules", hits.count)
        return L("%1$@ · %2$ld hits · %3$@ · %4$.2f s", rules, matchCount, scanned, scan.elapsed)
    }

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
        lastScan = nil
        let ticket = gate.begin()
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let start = Date()
            var hits: [YaraRuleMatch]?
            var warn: [YaraDiagnostic] = []
            var compileErrors: [YaraDiagnostic] = []
            var failure: String?
            do {
                // The app only reads the rule files; compiling and scanning
                // run in the sandboxed helper (#102).
                let bundle = try YaraRuleBundle.collect(files: files)
                switch try await HelperClient.shared.scan(
                    snapshot, rules: bundle, range: range, timeout: timeout,
                    maxMatchesPerPattern: cap)
                {
                case .hits(let h, let w): hits = h; warn = w
                case .compileErrors(let d): compileErrors = d
                case .failed(let m, let w), .timedOut(let m, let w): failure = m; warn = w
                }
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
                if self.gate.finish(ticket) == .stale, self.results != nil { self.stale = true }
            }
        }
    }

    /// The scan itself cannot be interrupted (YARA-X has no cancel call); it
    /// stops at the timeout at the latest and its result is discarded.
    func cancel() {
        task?.cancel()
        task = nil
        running = false
        scanError = L("Cancelled")
    }

    func contentChanged() {
        gate.contentChanged()
        if results != nil { stale = true }
    }

    private func show(_ hits: [YaraRuleMatch], range: Range<UInt64>?, size: UInt64, elapsed: TimeInterval) {
        results = hits
        stale = false
        selectedMatch = nil
        ranges = hits.flatMap { $0.matches.map(\.range) }.filter { !$0.isEmpty }
            .sorted { $0.lowerBound < $1.lowerBound }
        expanded = hits.count <= 3 ? Set(hits.map(\.id)) : []
        lastScan = ScanInfo(range: range, elapsed: elapsed)
    }

    func clear() {
        results = nil
        ranges = []
        lastScan = nil
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
