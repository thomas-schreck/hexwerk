import AppKit
import Combine
import HexwerkCore

extension Notification.Name {
    /// Global highlight rules changed in one window; the others reload them.
    static let hexwerkHighlightRulesChanged = Notification.Name("hexwerkHighlightRulesChanged")
}

/// Highlight rules of one document (#141): rules of this file (project),
/// global rules and the built-in zero-byte rule. Matches are computed in
/// the background for the visible blocks only and cached until the rules or
/// the content change.
@MainActor
final class HighlightRulesModel: ObservableObject {
    static let palette: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue, .systemPurple, .systemPink,
        .systemGray,
    ]
    static let zeroColor = palette.count - 1

    @Published var fileRules: [HighlightRule] = [] { didSet { rulesChanged() } }
    @Published var globalRules: [HighlightRule] = HighlightRule.rules(fromJSONObject: Settings.shared.object(forKey: "highlightRules"))
    {
        didSet {
            rulesChanged()
            guard !syncing else { return }
            Settings.shared.set(HighlightRule.jsonObject(globalRules), forKey: "highlightRules")
            NotificationCenter.default.post(name: .hexwerkHighlightRulesChanged, object: self)
        }
    }
    @Published var zeroBytes = Settings.shared.bool(forKey: "highlightZeroBytes") {
        didSet {
            rulesChanged()
            guard !syncing else { return }
            Settings.shared.set(zeroBytes, forKey: "highlightZeroBytes")
            NotificationCenter.default.post(name: .hexwerkHighlightRulesChanged, object: self)
        }
    }
    /// Bumped when background results arrive, so the hex view redraws.
    @Published private(set) var resultsVersion = 0

    private let doc: Document
    private var matcher = HighlightMatcher([])
    private var cache = HighlightCache()
    private var task: Task<Void, Never>?
    private var pending: [UInt64] = []
    /// Results of an older rule set or content revision are dropped.
    private var generation = 0
    private var syncing = false
    private var observer: NSObjectProtocol?

    init(doc: Document) {
        self.doc = doc
        rulesChanged()
        observer = NotificationCenter.default.addObserver(forName: .hexwerkHighlightRulesChanged, object: nil, queue: .main) {
            [weak self] note in
            let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, sender != ObjectIdentifier(self) else { return }
                self.syncing = true
                self.globalRules = HighlightRule.rules(fromJSONObject: Settings.shared.object(forKey: "highlightRules"))
                self.zeroBytes = Settings.shared.bool(forKey: "highlightZeroBytes")
                self.syncing = false
            }
        }
    }

    isolated deinit {
        task?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Drawing order: zero bytes underneath, then global, then this file's rules.
    var activeRules: [HighlightRule] {
        (zeroBytes ? [HighlightRule.zeroBytes(color: Self.zeroColor)] : []) + globalRules + fileRules
    }

    private func rulesChanged() {
        matcher = HighlightMatcher(activeRules)
        invalidate()
    }

    func contentChanged() { invalidate() }

    func cancel() {
        task?.cancel()
        task = nil
        pending = []
    }

    private func invalidate() {
        cancel()
        generation += 1
        cache.removeAll()
        resultsVersion += 1
    }

    /// Cached hits touching `window`; missing blocks are computed in the
    /// background and trigger a redraw when ready.
    func highlights(in window: Range<UInt64>) -> [(Range<UInt64>, NSColor)] {
        guard !matcher.isEmpty else { return [] }
        let blocks = matcher.blocks(covering: window)
        let missing = cache.missing(blocks)
        // Blocks finishing one by one must not restart the run still busy with the rest.
        if !Set(missing).isSubset(of: pending) { schedule(missing) }
        return cache.hits(in: window, blocks: blocks).map {
            ($0.range, Self.palette[$0.color % Self.palette.count].withAlphaComponent(0.3))
        }
    }

    private func schedule(_ blocks: [UInt64]) {
        // The view moved on: what was requested before is no longer needed.
        task?.cancel()
        pending = blocks
        let matcher = matcher, snapshot = doc.snapshot(), gen = generation
        task = Task.detached(priority: .userInitiated) { [weak self] in
            for b in blocks {
                guard let hits = matcher.hits(inBlock: b, of: snapshot, isCancelled: { Task.isCancelled }) else { return }
                await MainActor.run {
                    guard let self, self.generation == gen, !Task.isCancelled else { return }
                    self.cache.store(hits, forBlock: b)
                    self.resultsVersion += 1
                }
            }
            await MainActor.run {
                guard let self, self.generation == gen, !Task.isCancelled else { return }
                self.pending = []
            }
        }
    }
}
