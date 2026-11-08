import Foundation

/// File offsets and the addresses shown to the user (#143).
///
/// A file can have a base address: the address of its first byte, e.g. the
/// load address of a firmware image (0x08000000) or of a memory dump. Intel
/// HEX / S-Record import sets it, the user can set it per file, and it is
/// stored in the project file. It only changes how positions are shown and
/// entered: the bytes, the undo history and every offset in the core APIs
/// (search hits, diff ops, bookmarks, the script API's `hw.*` offsets) stay
/// file offsets. Convert at the edge with this type.
public struct AddressMap: Sendable, Equatable {
    /// Address of offset 0.
    public var base: UInt64

    public init(base: UInt64 = 0) { self.base = base }

    /// Address of a file offset. Wraps at 2^64 like a CPU address; `isValid`
    /// keeps that from happening for the file as it is.
    public func address(of offset: UInt64) -> UInt64 { base &+ offset }

    /// File offset of an address; nil if it lies before the base or past the
    /// end of a file of `count` bytes. The end itself is valid (a cursor
    /// position, like "go to").
    public func offset(of address: UInt64, count: UInt64) -> UInt64? {
        guard address >= base, address - base <= count else { return nil }
        return address - base
    }

    /// True if every address of a file of `count` bytes, including the end
    /// position, fits in 64 bits.
    public static func isValid(base: UInt64, count: UInt64) -> Bool {
        !base.addingReportingOverflow(count).overflow
    }

    /// "0x1000", "4096", "0x0800_0000"; nil for anything else.
    public static func parseNumber(_ text: String) -> UInt64? {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "_", with: "")
        return s.hasPrefix("0x") ? UInt64(s.dropFirst(2), radix: 16) : UInt64(s)
    }

    /// "Go to" input → file offset: an absolute value is an address, "+n" and
    /// "-n" (or "−n") move relative to `cursor`. Nil outside 0 … `count`.
    public func target(of text: String, cursor: UInt64, count: UInt64) -> UInt64? {
        var s = text.trimmingCharacters(in: .whitespaces)
        var sign = 0
        if s.hasPrefix("+") {
            sign = 1; s.removeFirst()
        } else if s.hasPrefix("-") || s.hasPrefix("−") {
            sign = -1; s.removeFirst()
        }
        guard let v = Self.parseNumber(s) else { return nil }
        let target: UInt64
        switch sign {
        case 1: target = cursor.addingReportingOverflow(v).overflow ? .max : cursor + v
        case -1: target = cursor >= v ? cursor - v : 0
        default: return offset(of: v, count: count)
        }
        return target <= count ? target : nil
    }
}
