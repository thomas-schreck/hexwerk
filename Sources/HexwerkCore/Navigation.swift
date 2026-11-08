import Foundation

/// A position in the hex view: cursor and optional selection.
public struct NavigationEntry: Sendable, Equatable {
    public var cursor: UInt64
    public var selection: Range<UInt64>?

    public init(cursor: UInt64, selection: Range<UInt64>? = nil) {
        self.cursor = cursor
        self.selection = selection
    }
}

/// Back/forward through recent jumps (go to, structure tree, hits,
/// bookmarks, pointers), like a browser. Arrow keys are not recorded.
public struct NavigationHistory: Sendable, Equatable {
    /// Oldest entries are dropped beyond this.
    public static let limit = 100

    public private(set) var back: [NavigationEntry] = []
    public private(set) var forward: [NavigationEntry] = []

    public init() {}

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// A jump from `current` to `target`: remembers `current` and drops the
    /// forward list. A jump that does not move records nothing.
    public mutating func record(from current: NavigationEntry, to target: NavigationEntry) {
        guard current != target else { return }
        if back.last != current { back.append(current) }
        if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        forward.removeAll()
    }

    /// Where Back goes; `current` becomes the first Forward entry.
    public mutating func goBack(from current: NavigationEntry) -> NavigationEntry? {
        guard let e = back.popLast() else { return nil }
        forward.append(current)
        return e
    }

    /// Where Forward goes; `current` becomes the last Back entry.
    public mutating func goForward(from current: NavigationEntry) -> NavigationEntry? {
        guard let e = forward.popLast() else { return nil }
        back.append(current)
        return e
    }

    /// Keeps entries on their data when bytes are inserted or deleted (see
    /// `Range.adjustedForEdit`); a cursor inside deleted bytes lands at the edit.
    public mutating func adjust(replacing edited: Range<UInt64>, newLength: UInt64) {
        guard UInt64(edited.count) != newLength else { return }
        func fix(_ e: NavigationEntry) -> NavigationEntry {
            let c = (e.cursor ..< e.cursor + 1).adjustedForEdit(replacing: edited, newLength: newLength)?.lowerBound
            return NavigationEntry(
                cursor: c ?? edited.lowerBound,
                selection: e.selection?.adjustedForEdit(replacing: edited, newLength: newLength))
        }
        back = back.map(fix)
        forward = forward.map(fix)
    }
}

/// Selection helpers: record stepping, parent structure, start/end marks.
public enum SelectionHelpers {
    /// The selection moved by its own length (next/previous record), nil
    /// when it would leave the file of `count` bytes.
    public static func step(_ sel: Range<UInt64>, forward: Bool, count: UInt64) -> Range<UInt64>? {
        let n = UInt64(sel.count)
        guard n > 0 else { return nil }
        if forward {
            let (end, overflow) = sel.upperBound.addingReportingOverflow(n)
            guard !overflow, end <= count else { return nil }
            return sel.upperBound ..< end
        }
        guard sel.lowerBound >= n else { return nil }
        return sel.lowerBound - n ..< sel.lowerBound
    }

    /// The smallest of `candidates` (the ranges of the structure elements
    /// around the selection) that contains `sel` and is larger than it.
    public static func parent(of sel: Range<UInt64>, in candidates: [Range<UInt64>]) -> Range<UInt64>? {
        candidates
            .filter { $0.lowerBound <= sel.lowerBound && $0.upperBound >= sel.upperBound && $0.count > sel.count }
            .min { $0.count < $1.count }
    }

    /// Selection between a start mark and an end mark (both byte offsets,
    /// inclusive, in either order), limited to a file of `count` bytes.
    public static func marked(start: UInt64, end: UInt64, count: UInt64) -> Range<UInt64>? {
        let lo = min(start, end), hi = max(start, end)
        guard lo < count else { return nil }
        return lo ..< min(count, hi + 1)
    }
}

/// "Follow pointer": an integer read from the file as a target offset.
public enum PointerTarget {
    /// File offset for an address `value`. `base` is the address of file
    /// offset 0 (load address of a HEX import, later the user base address
    /// of #143), subtracted here and only here. Nil outside the file;
    /// offset `count` (end of file) is allowed like in "Go to Offset".
    public static func offset(for value: UInt64, base: UInt64 = 0, count: UInt64) -> UInt64? {
        guard value >= base else { return nil }
        let off = value - base
        return off <= count ? off : nil
    }

    /// Integer inspector rows that can be followed, by size in bytes.
    public static let inspectorSizes: [String: Int] = ["uint16": 2, "uint32": 4, "uint64": 8]

    /// Unsigned value of the first `size` bytes of `data` in `endian`, nil
    /// when there are too few bytes.
    public static func value(_ data: Data, size: Int, endian: Endian) -> UInt64? {
        guard (1 ... 8).contains(size), data.count >= size else { return nil }
        let b = Array(data.prefix(size))
        return (endian == .little ? b.reversed() : b).reduce(0) { $0 << 8 | UInt64($1) }
    }
}
