import Foundation
import Testing
@testable import HexwerkCore

@Suite struct NavigationTests {
    func at(_ c: UInt64, _ sel: Range<UInt64>? = nil) -> NavigationEntry { NavigationEntry(cursor: c, selection: sel) }

    @Test func backAndForwardLikeABrowser() {
        var h = NavigationHistory()
        #expect(!h.canGoBack && !h.canGoForward)
        h.record(from: at(0), to: at(0x100))
        h.record(from: at(0x100), to: at(0x200, 0x200 ..< 0x210))
        #expect(h.goBack(from: at(0x20F, 0x200 ..< 0x210)) == at(0x100))
        #expect(h.goBack(from: at(0x100)) == at(0))
        #expect(h.goBack(from: at(0)) == nil)
        #expect(h.goForward(from: at(0)) == at(0x100))
        #expect(h.goForward(from: at(0x100)) == at(0x20F, 0x200 ..< 0x210))
        #expect(h.goForward(from: at(0x20F)) == nil)
    }

    @Test func newJumpDropsForwardAndIgnoresNoMove() {
        var h = NavigationHistory()
        h.record(from: at(0), to: at(10))
        h.record(from: at(10), to: at(20))
        _ = h.goBack(from: at(20))
        #expect(h.canGoForward)
        h.record(from: at(10), to: at(30))
        #expect(!h.canGoForward)
        #expect(h.back == [at(0), at(10)])
        // Jumping to where we are, or twice from the same place, adds nothing new.
        h.record(from: at(30), to: at(30))
        h.record(from: at(30), to: at(40))
        h.record(from: at(30), to: at(50))
        #expect(h.back == [at(0), at(10), at(30)])
    }

    @Test func historyIsBounded() {
        var h = NavigationHistory()
        for i in 0 ..< UInt64(NavigationHistory.limit + 50) { h.record(from: at(i), to: at(i + 1)) }
        #expect(h.back.count == NavigationHistory.limit)
        #expect(h.back.first == at(50))
    }

    @Test func entriesFollowInsertsAndDeletes() {
        var h = NavigationHistory()
        h.record(from: at(5), to: at(100))
        h.record(from: at(100, 100 ..< 110), to: at(200))
        h.record(from: at(50), to: at(300))
        // 4 bytes inserted at 20: later entries move, earlier stay.
        h.adjust(replacing: 20 ..< 20, newLength: 4)
        #expect(h.back == [at(5), at(104, 104 ..< 114), at(54)])
        // Bytes 50 ..< 60 deleted: a cursor inside lands at the edit.
        h.adjust(replacing: 50 ..< 60, newLength: 0)
        #expect(h.back == [at(5), at(94, 94 ..< 104), at(50)])
        // Overwrites move nothing.
        let before = h
        h.adjust(replacing: 0 ..< 8, newLength: 8)
        #expect(h == before)
    }

    @Test func stepSelectionByItsLength() {
        #expect(SelectionHelpers.step(16 ..< 24, forward: true, count: 100) == 24 ..< 32)
        #expect(SelectionHelpers.step(16 ..< 24, forward: false, count: 100) == 8 ..< 16)
        #expect(SelectionHelpers.step(8 ..< 16, forward: false, count: 100) == 0 ..< 8)
        #expect(SelectionHelpers.step(4 ..< 12, forward: false, count: 100) == nil)
        #expect(SelectionHelpers.step(90 ..< 95, forward: true, count: 100) == 95 ..< 100)
        #expect(SelectionHelpers.step(92 ..< 97, forward: true, count: 100) == nil)
        #expect(SelectionHelpers.step(.max - 2 ..< .max, forward: true, count: .max) == nil)  // no overflow trap
    }

    @Test func parentIsTheSmallestStrictlyLargerElement() {
        let path: [Range<UInt64>] = [0 ..< 1000, 16 ..< 80, 16 ..< 80, 20 ..< 24]
        #expect(SelectionHelpers.parent(of: 21 ..< 22, in: path) == 20 ..< 24)
        #expect(SelectionHelpers.parent(of: 20 ..< 24, in: path) == 16 ..< 80)
        // An element of the same size (a struct with one field) is skipped.
        #expect(SelectionHelpers.parent(of: 16 ..< 80, in: path) == 0 ..< 1000)
        #expect(SelectionHelpers.parent(of: 0 ..< 1000, in: path) == nil)
        // Not contained in a candidate that only overlaps.
        #expect(SelectionHelpers.parent(of: 70 ..< 90, in: path) == 0 ..< 1000)
    }

    @Test func markedSelection() {
        #expect(SelectionHelpers.marked(start: 10, end: 19, count: 100) == 10 ..< 20)
        #expect(SelectionHelpers.marked(start: 19, end: 10, count: 100) == 10 ..< 20)
        #expect(SelectionHelpers.marked(start: 5, end: 5, count: 100) == 5 ..< 6)
        #expect(SelectionHelpers.marked(start: 90, end: 100, count: 100) == 90 ..< 100)  // end at EOF
        #expect(SelectionHelpers.marked(start: 100, end: 100, count: 100) == nil)
    }

    @Test func pointerTargets() {
        #expect(PointerTarget.offset(for: 0x40, count: 0x100) == 0x40)
        #expect(PointerTarget.offset(for: 0x100, count: 0x100) == 0x100)  // end of file, like Go to Offset
        #expect(PointerTarget.offset(for: 0x101, count: 0x100) == nil)
        #expect(PointerTarget.offset(for: 0x0800_0040, base: 0x0800_0000, count: 0x100) == 0x40)
        #expect(PointerTarget.offset(for: 0x40, base: 0x0800_0000, count: 0x100) == nil)

        let d = Data([0x78, 0x56, 0x34, 0x12, 0, 0, 0, 0])
        #expect(PointerTarget.value(d, size: 4, endian: .little) == 0x1234_5678)
        #expect(PointerTarget.value(d, size: 4, endian: .big) == 0x7856_3412)
        #expect(PointerTarget.value(d, size: 2, endian: .little) == 0x5678)
        #expect(PointerTarget.value(d, size: 8, endian: .little) == 0x1234_5678)
        #expect(PointerTarget.value(d.prefix(3), size: 4, endian: .little) == nil)
        // The followable rows exist in the inspector.
        let names = Set(Inspector.values(d, endian: .little).map(\.name))
        #expect(Set(PointerTarget.inspectorSizes.keys).isSubset(of: names))
    }
}
