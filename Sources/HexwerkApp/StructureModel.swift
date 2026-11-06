import AppKit
import Combine
import HexwerkCore
import HexwerkKaitai

/// Kaitai structure of one document: chosen format, parse result, which
/// tree nodes are expanded, and the colored field ranges for the hex view.
@MainActor
final class StructureModel: ObservableObject {
    /// Format collection (`make formats`) plus own .ksy files, which win.
    static let formatsDir = HexwerkPaths.formats
    static let ownDir = HexwerkPaths.ksy
    static let catalog = FormatCatalog(root: formatsDir, extraRoots: [ownDir])

    struct Row: Identifiable {
        let node: ParseNode
        let depth: Int
        var id: Int { node.id }
    }

    @Published private(set) var formatURL: URL?
    @Published private(set) var formatTitle: String?
    @Published private(set) var result: ParseResult?
    @Published private(set) var parsing = false
    @Published private(set) var stale = false
    @Published private(set) var loadError: String?
    @Published private(set) var rows: [Row] = []
    @Published var selected: Int?
    @Published var colorize = true
    /// Hints from the last .bt import (lines that were not translated).

    private var expanded: Set<Int> = []
    private var parentOf: [Int: Int] = [:]
    private var byID: [Int: ParseNode] = [:]
    /// Leaf ranges sorted by start, with a color index (for drawing).
    private(set) var leaves: [(Range<UInt64>, Int)] = []
    private var task: Task<Void, Never>?
    /// Marks a result stale when the content was edited while it was computed.
    private var gate = RunGate()
    /// Cursor at the last follow() call, applied once a parse finishes.
    private var lastCursor: UInt64?

    /// Closing the window must not leave a parse running for up to 30 s.
    isolated deinit { task?.cancel() }

    static let genericExtensions: Set<String> = ["bin", "dat", "data", "raw", "img", "dump", "out", "tmp", "rom", "fw", "hex", ""]


    // MARK: Format

    /// Signature first (works for .bin and wrong extensions), then extension.
    func autoDetect(for url: URL, snapshot: Snapshot) {
        for hit in FileSignatures.detect(snapshot) {
            if let id = hit.kaitai, let entry = Self.catalog.entries.first(where: { $0.id == id }) {
                apply(entry.url, title: entry.title, snapshot: snapshot)
                return
            }
        }
        // Generic extensions say nothing about the format (.bin is claimed by
        // U-Boot images in the collection, but is used for anything).
        guard !Self.genericExtensions.contains(url.pathExtension.lowercased()) else { return }
        let matches = Self.catalog.matching(fileExtension: url.pathExtension)
        if let only = matches.first, matches.count == 1 { apply(only.url, title: only.title, snapshot: snapshot) }
    }

    func apply(_ url: URL?, title: String?, snapshot: Snapshot) {
        task?.cancel()
        formatURL = url
        formatTitle = title
        result = nil
        loadError = nil
        stale = false
        rows = []
        leaves = []
        selected = nil
        guard let url else { return }
        parsing = true
        let roots = [Self.formatsDir, Self.ownDir]
        let ticket = gate.begin()
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<ParseResult, Error>
            do {
                // Loading parses expressions recursively; task threads have 512 KiB.
                // It is short and bounded (#10), so the blocking variant is fine;
                // KsyFile is not Sendable, so it cannot use the async one.
                let schema = try onLargeStack { Result { try KsyLoader(libraryRoots: roots).load(url) } }.get()
                // The async parse stops when this task is cancelled (format
                // switch, reparse, window closed) and does not block a pool thread.
                outcome = .success(await KaitaiInterpreter.parse(snapshot, file: schema))
            } catch {
                outcome = .failure(error)
            }
            let cancelled = Task.isCancelled
            await MainActor.run {
                guard let self, !cancelled else { return }
                self.parsing = false
                switch outcome {
                case .success(let r): self.show(r)
                case .failure(let e): self.loadError = String(describing: e)
                }
                if self.gate.finish(ticket) == .stale, self.result != nil { self.stale = true }
            }
        }
    }

    func cancel() {
        task?.cancel()
        parsing = false
    }

    func reparse(snapshot: Snapshot) { apply(formatURL, title: formatTitle, snapshot: snapshot) }

    func contentChanged() {
        gate.contentChanged()
        if result != nil { stale = true }
    }

    private func show(_ r: ParseResult) {
        result = r
        parentOf = [:]
        byID = [:]
        pages = [:]
        var leafList: [(Range<UInt64>, Int)] = []
        func index(_ n: ParseNode, parent: Int?) {
            byID[n.id] = n
            if let parent { parentOf[n.id] = parent }
            if n.childCount == 0 || n.lazy != nil, let r = n.range, !r.isEmpty {
                // A lazy array is colored as one block.
                leafList.append((r, leafList.count % 4))
            }
            for c in n.children { index(c, parent: n.id) }
        }
        index(r.root, parent: nil)
        leaves = leafList.sorted { $0.0.lowerBound < $1.0.lowerBound }
        expanded = [r.root.id]
        // Open the path to the error, so it is visible right away.
        if let bad = firstErrorNode(r.root) { reveal(bad.id) }
        rebuildRows()
        if let c = lastCursor { follow(cursor: c) }
    }

    private func firstErrorNode(_ n: ParseNode) -> ParseNode? {
        for c in n.children { if let e = firstErrorNode(c) { return e } }
        return n.error != nil ? n : nil
    }

    // MARK: Tree rows

    /// Above this many children a node shows pages of this size (FR-6.13).
    static let pageSize = 1000

    /// Synthetic page rows: id → (array node, first index, end index).
    private var pages: [Int: (node: ParseNode, lower: Int, upper: Int)] = [:]

    private func pageID(_ node: ParseNode, _ page: Int) -> Int { -(node.id * 100_000 + page + 1) }

    func isExpanded(_ id: Int) -> Bool { expanded.contains(id) }

    func hasChildren(_ n: ParseNode) -> Bool { n.childCount > 0 || pages[n.id] != nil }

    func toggle(_ id: Int) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        rebuildRows()
    }

    /// Children as shown: pages for big arrays, elements of a page made on
    /// demand (lazy arrays create their nodes only here).
    private func shownChildren(_ n: ParseNode) -> [ParseNode] {
        if let p = pages[n.id] {
            return (p.lower ..< p.upper).map { i in
                let c = p.node.child(i)
                if byID[c.id] == nil {
                    byID[c.id] = c
                    parentOf[c.id] = n.id
                }
                return c
            }
        }
        guard n.childCount > Self.pageSize else { return n.children }
        return stride(from: 0, to: n.childCount, by: Self.pageSize).map { lower in
            let upper = min(n.childCount, lower + Self.pageSize)
            let id = pageID(n, lower / Self.pageSize)
            let first = n.child(lower).range, last = n.child(upper - 1).range
            let range: Range<UInt64>? = first.flatMap { f in last.map { f.lowerBound ..< max(f.lowerBound, $0.upperBound) } }
            let page = ParseNode(id: id, name: "[\(lower) … \(upper - 1)]", typeName: "", value: nil,
                                 range: range, children: [], error: nil, number: nil)
            if pages[id] == nil {
                pages[id] = (n, lower, upper)
                byID[id] = page
                parentOf[id] = n.id
            }
            return page
        }
    }

    private func rebuildRows() {
        guard let root = result?.root else { rows = []; return }
        var out: [Row] = []
        func add(_ n: ParseNode, _ depth: Int) {
            out.append(Row(node: n, depth: depth))
            guard expanded.contains(n.id) else { return }
            for c in shownChildren(n) { add(c, depth + 1) }
        }
        add(root, 0)
        rows = out
    }

    private func reveal(_ id: Int) {
        var p = parentOf[id]
        while let pid = p {
            expanded.insert(pid)
            p = parentOf[pid]
        }
    }

    /// Selects the deepest node containing `offset` and opens its path
    /// (cursor → tree, SPEC FR-6.8). Returns true if the selection changed.
    @discardableResult
    func follow(cursor offset: UInt64) -> Bool {
        lastCursor = offset
        guard let root = result?.root else { return false }
        var best: ParseNode? = nil
        var n = root
        while true {
            var next: ParseNode?
            if n.childCount > Self.pageSize {
                // Find the element, then make sure its page and node exist.
                let i: Int? = n.lazy?.index(of: offset)
                    ?? n.children.firstIndex { $0.range?.contains(offset) == true }
                guard let i else { break }
                let pages = shownChildren(n)
                let page = pages[i / Self.pageSize]
                next = shownChildren(page).first { $0.id == n.child(i).id }
            } else {
                next = n.children.first { $0.range?.contains(offset) == true }
            }
            guard let c = next else { break }
            best = c
            n = c
        }
        guard let best, best.id != selected else { return false }
        selected = best.id
        reveal(best.id)
        rebuildRows()
        return true
    }

    func node(_ id: Int) -> ParseNode? { byID[id] }

    // MARK: Drawing

    static let palette: [NSColor] = [.systemTeal, .systemPurple, .systemGreen, .systemBlue]

    func highlights(in window: Range<UInt64>) -> [(Range<UInt64>, NSColor)] {
        guard colorize, !leaves.isEmpty else { return [] }
        // Binary search for the first leaf that may reach into the window.
        var lo = 0, hi = leaves.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if leaves[mid].0.lowerBound < window.lowerBound { lo = mid + 1 } else { hi = mid }
        }
        // Fields starting a bit earlier can still cover the window start.
        var i = max(0, lo - 64)
        var out: [(Range<UInt64>, NSColor)] = []
        while i < leaves.count, leaves[i].0.lowerBound < window.upperBound {
            if leaves[i].0.overlaps(window) {
                out.append((leaves[i].0, Self.palette[leaves[i].1].withAlphaComponent(0.16)))
            }
            i += 1
        }
        return out
    }
}
