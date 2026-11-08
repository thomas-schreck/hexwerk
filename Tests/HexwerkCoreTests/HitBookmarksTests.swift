import Foundation
import Testing
@testable import HexwerkCore

/// "Bookmark All" for search, YARA and strings hits (#142).
@Suite struct HitBookmarksTests {
    @Test func namesAndDeduplicates() {
        let r = HitBookmarks.make(
            [
                ("MZ", 0 ..< 2), ("rule $a", 10 ..< 14), ("MZ", 20 ..< 22), ("rule $b", 10 ..< 14),
                ("MZ", 30 ..< 32), ("empty", 40 ..< 40), ("MZ", 50 ..< 52),
            ],
            existing: [30 ..< 32])
        #expect(r.added.map(\.name) == ["MZ #1", "rule $a", "MZ #2", "MZ #3"])
        #expect(r.added.map(\.range) == [0 ..< 2, 10 ..< 14, 20 ..< 22, 50 ..< 52])
        #expect(r.duplicates == 2)  // 10..<14 twice, 30..<32 already bookmarked
        #expect(r.overLimit == 0)
    }

    @Test func respectsTheLimit() {
        let hits = (0 ..< 25).map { (label: "h", range: UInt64($0) ..< UInt64($0) + 1) }
        let r = HitBookmarks.make(hits, existing: [], limit: 10)
        #expect(r.added.count == 10 && r.overLimit == 15)
        #expect(r.added.last?.name == "h #10")
        #expect(HitBookmarks.make([], existing: []) == HitBookmarks.Result(added: [], duplicates: 0, overLimit: 0))
    }
}
