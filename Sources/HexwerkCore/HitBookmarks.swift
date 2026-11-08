import Foundation

/// Turns a hit list (search, YARA, strings) into bookmarks in one step (#142).
public enum HitBookmarks {
    /// More bookmarks than this at once would make the bookmark list useless.
    public static let limit = 10_000

    public struct Result: Equatable, Sendable {
        public var added: [(name: String, range: Range<UInt64>)]
        /// Hits left out because a bookmark (or an earlier hit) already marks the same bytes.
        public var duplicates: Int
        /// Hits left out because of `limit`.
        public var overLimit: Int

        public static func == (a: Result, b: Result) -> Bool {
            a.added.elementsEqual(b.added) { $0.name == $1.name && $0.range == $1.range }
                && a.duplicates == b.duplicates && a.overLimit == b.overLimit
        }
    }

    /// One bookmark per hit whose range is not bookmarked yet, in hit order.
    /// A label shared by several hits gets " #1", " #2", … (counted over
    /// the hits added); empty hits are skipped.
    public static func make(
        _ hits: [(label: String, range: Range<UInt64>)], existing: [Range<UInt64>], limit: Int = limit
    ) -> Result {
        var seen = Set(existing)
        var picked: [(label: String, range: Range<UInt64>)] = []
        var duplicates = 0, overLimit = 0
        for h in hits where !h.range.isEmpty {
            guard seen.insert(h.range).inserted else { duplicates += 1; continue }
            guard picked.count < limit else { overLimit += 1; continue }
            picked.append(h)
        }
        var total: [String: Int] = [:]
        for p in picked { total[p.label, default: 0] += 1 }
        var counter: [String: Int] = [:]
        let added = picked.map { p -> (name: String, range: Range<UInt64>) in
            guard total[p.label]! > 1 else { return (p.label, p.range) }
            counter[p.label, default: 0] += 1
            return ("\(p.label) #\(counter[p.label]!)", p.range)
        }
        return Result(added: added, duplicates: duplicates, overLimit: overLimit)
    }
}
