import Foundation

/// A persistent "color every match of this pattern" rule for the hex view
/// (issue #141). Kept per file in the project and globally in settings.
public struct HighlightRule: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Hex bytes with `??` and nibble (`4?`, `?D`) wildcards, parsed
        /// like the hex search.
        case hex
        /// UTF-8 text.
        case text
        /// Regular expression over raw bytes (one Latin-1 character per byte).
        case regex
    }

    public var id: UUID
    public var kind: Kind
    public var pattern: String
    /// Index into the app's rule palette.
    public var color: Int
    public var enabled: Bool
    /// Text and regex only.
    public var ignoreCase: Bool

    public init(
        id: UUID = UUID(), kind: Kind, pattern: String, color: Int = 0, enabled: Bool = true, ignoreCase: Bool = false
    ) {
        self.id = id; self.kind = kind; self.pattern = pattern; self.color = color
        self.enabled = enabled; self.ignoreCase = ignoreCase
    }

    /// The optional built-in rule for 0x00 bytes; its color is set by the app.
    public static func zeroBytes(color: Int) -> HighlightRule {
        HighlightRule(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)), kind: .hex, pattern: "00", color: color)
    }

    /// True if the pattern parses (an invalid rule is kept but matches nothing).
    public var isValid: Bool { compiled() != nil }

    enum Compiled {
        case bytes(SearchPattern)
        case regex(NSRegularExpression)
    }

    func compiled() -> Compiled? {
        switch kind {
        case .hex: return SearchPattern.hex(pattern).map(Compiled.bytes)
        case .text: return SearchPattern.text(pattern, encoding: .utf8, ignoreCase: ignoreCase).map(Compiled.bytes)
        case .regex:
            guard !pattern.isEmpty else { return nil }
            var opts: NSRegularExpression.Options = [.dotMatchesLineSeparators]
            if ignoreCase { opts.insert(.caseInsensitive) }
            return (try? NSRegularExpression(pattern: pattern, options: opts)).map(Compiled.regex)
        }
    }

    /// Only `kind` and `pattern` are required, so hand-written rules load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        pattern = try c.decode(String.self, forKey: .pattern)
        color = try c.decodeIfPresent(Int.self, forKey: .color) ?? 0
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        ignoreCase = try c.decodeIfPresent(Bool.self, forKey: .ignoreCase) ?? false
    }

    /// For the JSON settings file, which stores plain JSON objects.
    public static func jsonObject(_ rules: [HighlightRule]) -> Any {
        (try? JSONEncoder().encode(rules)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
    }

    /// Inverse of `jsonObject`; unreadable entries are skipped.
    public static func rules(fromJSONObject object: Any?) -> [HighlightRule] {
        guard let list = object as? [Any] else { return [] }
        return list.compactMap { item in
            guard JSONSerialization.isValidJSONObject(item), let data = try? JSONSerialization.data(withJSONObject: item) else {
                return nil
            }
            return try? JSONDecoder().decode(HighlightRule.self, from: data)
        }
    }
}

/// One colored range found by a rule.
public struct HighlightHit: Sendable, Equatable {
    public let range: Range<UInt64>
    public let color: Int
    public init(range: Range<UInt64>, color: Int) { self.range = range; self.color = color }
}

/// The enabled, valid rules compiled once, matched block by block so the
/// hex view only ever scans what is on screen.
public struct HighlightMatcher: @unchecked Sendable {
    // NSRegularExpression is immutable and documented as thread-safe.
    private let rules: [(color: Int, compiled: HighlightRule.Compiled, length: Int)]

    /// Blocks are aligned, so scrolling a little reuses cached results.
    public static let blockSize: UInt64 = 64 << 10
    /// Hits per rule and block; more are not collected.
    public static let maxHitsPerBlock = 20_000

    public init(_ rules: [HighlightRule]) {
        self.rules = rules.filter(\.enabled).compactMap { r in
            guard let c = r.compiled() else { return nil }
            switch c {
            case .bytes(let p): return (r.color, c, p.count)
            case .regex: return (r.color, c, RegexSearch.overlap)
            }
        }
    }

    public var isEmpty: Bool { rules.isEmpty }

    /// How far a hit starting in a block can reach past the block end.
    public var reach: UInt64 { UInt64(rules.map(\.length).max() ?? 1) }

    /// Indexes of the blocks whose hits can touch `window`.
    public func blocks(covering window: Range<UInt64>) -> ClosedRange<UInt64> {
        let first = window.lowerBound - min(window.lowerBound, reach)
        let last = window.upperBound > window.lowerBound ? window.upperBound - 1 : window.lowerBound
        return first / Self.blockSize ... last / Self.blockSize
    }

    /// Hits starting in block `index`, in rule order (later rules draw on
    /// top), adjacent hits of a rule merged. Nil when cancelled.
    public func hits(inBlock index: UInt64, of snap: Snapshot, isCancelled: () -> Bool = { false }) -> [HighlightHit]? {
        let (start, overflow) = index.multipliedReportingOverflow(by: Self.blockSize)
        guard !overflow, start < snap.count else { return [] }
        let end = min(snap.count, start + Self.blockSize)
        var out: [HighlightHit] = []
        for rule in rules {
            if isCancelled() { return nil }
            let scan = start ..< min(snap.count, end + UInt64(rule.length))
            var found: [Range<UInt64>]
            switch rule.compiled {
            case .bytes(let p):
                found = Search.find(p, in: snap, range: scan) { _ in !isCancelled() }
                found.removeAll { $0.lowerBound >= end }
            case .regex(let re):
                found = Self.regexHits(re, snap.read(scan), at: start, before: end, isCancelled: isCancelled)
            }
            if isCancelled() { return nil }
            var merged: [Range<UInt64>] = []
            for r in found.prefix(Self.maxHitsPerBlock) {
                if let last = merged.last, last.upperBound == r.lowerBound {
                    merged[merged.count - 1] = last.lowerBound ..< r.upperBound
                } else {
                    merged.append(r)
                }
            }
            out += merged.map { HighlightHit(range: $0, color: rule.color) }
        }
        return out
    }

    /// Like `RegexSearch`, but stoppable inside a single slow match, so a
    /// catastrophic pattern cannot keep a worker busy after the view moved on.
    private static func regexHits(
        _ re: NSRegularExpression, _ data: Data, at base: UInt64, before end: UInt64, isCancelled: () -> Bool
    ) -> [Range<UInt64>] {
        let text = String(decoding: data.map { UInt16($0) }, as: UTF16.self) as NSString
        var hits: [Range<UInt64>] = []
        re.enumerateMatches(in: text as String, options: [.reportProgress], range: NSRange(location: 0, length: text.length)) {
            m, _, stop in
            if isCancelled() { stop.pointee = true; return }
            guard let m, m.range.length > 0 else { return }
            let s = base + UInt64(m.range.location)
            if s >= end { stop.pointee = true; return }
            hits.append(s ..< s + UInt64(m.range.length))
            if hits.count >= maxHitsPerBlock { stop.pointee = true }
        }
        return hits
    }
}

/// Block results of one matcher on one content revision. The owner clears
/// it when the rules or the content change.
public struct HighlightCache: Sendable {
    public private(set) var blocks: [UInt64: [HighlightHit]] = [:]
    /// Bounded memory: a long scroll through a big file drops old blocks.
    public static let maxBlocks = 256

    public init() {}

    public func missing(_ wanted: ClosedRange<UInt64>) -> [UInt64] { wanted.filter { blocks[$0] == nil } }

    public mutating func store(_ hits: [HighlightHit], forBlock index: UInt64) {
        if blocks.count >= Self.maxBlocks { blocks.removeAll(keepingCapacity: true) }
        blocks[index] = hits
    }

    public mutating func removeAll() { blocks.removeAll() }

    /// Cached hits of `wanted` blocks that overlap `window`.
    public func hits(in window: Range<UInt64>, blocks wanted: ClosedRange<UInt64>) -> [HighlightHit] {
        // Rule order matters for drawing; within a block it is kept, across blocks a
        // rule's hits only meet at block borders, so concatenating is fine.
        wanted.flatMap { (blocks[$0] ?? []).filter { $0.range.overlaps(window) } }
    }
}
