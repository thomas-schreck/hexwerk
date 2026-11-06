import Foundation

/// Vim-style key handling for the hex view (SPEC FR-10.9), as a pure state
/// machine: keys in, actions out. The view executes the actions.
public enum VimMode: String, Sendable {
    case normal = "NORMAL", insert = "INSERT", replace = "REPLACE", visual = "VISUAL"

    /// Localized name for the status bar.
    public var title: String {
        switch self {
        case .normal: L("NORMAL")
        case .insert: L("INSERT")
        case .replace: L("REPLACE")
        case .visual: L("VISUAL")
        }
    }
}

public enum VimAction: Equatable, Sendable {
    case moveBytes(Int64)          // h/l/w/b, with count
    case moveRows(Int64)           // j/k
    case movePages(Double)         // Ctrl-f/b (1), Ctrl-d/u (0.5)
    case rowStart, rowEnd, top, bottom
    case enterInsert(after: Bool)  // i / a
    case enterReplace              // R
    case enterNormal               // Esc
    case startVisual, endVisual
    case yank(count: Int)          // y (visual: selection)
    case paste(after: Bool)        // p / P
    case delete(count: Int)        // x (visual: d/x selection)
    case replaceByte(UInt8)        // r + two hex digits
    case undo, redo
    case search, searchNext, searchPrevious, goToPrompt
    case setMark(Character), jumpMark(Character)
    case switchPane
    case beep
}

public struct VimMachine: Sendable {
    public private(set) var mode: VimMode = .normal
    private var count = ""
    private var pending: Character?
    private var nibble: UInt8?

    public init() {}

    /// What the status bar shows, e.g. "NORMAL 12" while typing a count.
    public var status: String {
        var s = mode.title
        if !count.isEmpty { s += " \(count)" }
        if let p = pending { s += " \(p)" + (nibble.map { String($0, radix: 16, uppercase: true) } ?? "") }
        return s
    }

    /// Insert and replace mode leave typing to the view; only Esc comes here.
    public var handlesTyping: Bool { mode == .normal || mode == .visual }

    private mutating func takeCount() -> Int {
        let n = Int(count) ?? 1
        count = ""
        return max(1, min(n, 1_000_000))
    }

    public mutating func escape() -> [VimAction] {
        count = ""; pending = nil; nibble = nil
        switch mode {
        case .normal: return []
        case .visual: mode = .normal; return [.endVisual]
        case .insert, .replace: mode = .normal; return [.enterNormal]
        }
    }

    /// One typed character in normal or visual mode. `control` for Ctrl-keys.
    public mutating func key(_ ch: Character, control: Bool = false) -> [VimAction] {
        if control {
            let n = Double(takeCount())
            switch ch {
            case "f": return [.movePages(n)]
            case "b": return [.movePages(-n)]
            case "d": return [.movePages(0.5 * n)]
            case "u": return [.movePages(-0.5 * n)]
            case "r": return [.redo]
            default: return [.beep]
            }
        }
        // Second key of a two-key command.
        if let p = pending {
            switch p {
            case "g":
                pending = nil
                count = ""
                return ch == "g" ? [.top] : [.beep]
            case "m", "'":
                pending = nil
                count = ""
                guard ch.isLetter || ch.isNumber else { return [.beep] }
                return p == "m" ? [.setMark(ch)] : [.jumpMark(ch)]
            case "r":
                guard let d = ch.hexDigitValue else { pending = nil; nibble = nil; return [.beep] }
                if let hi = nibble {
                    pending = nil
                    nibble = nil
                    count = ""
                    return [.replaceByte(hi << 4 | UInt8(d))]
                }
                nibble = UInt8(d)
                return []
            default:
                pending = nil
            }
        }
        if ch.isNumber, ch != "0" || !count.isEmpty {
            count.append(ch)
            return []
        }
        switch ch {
        case "h": return [.moveBytes(-Int64(takeCount()))]
        case "l", " ": return [.moveBytes(Int64(takeCount()))]
        case "j": return [.moveRows(Int64(takeCount()))]
        case "k": return [.moveRows(-Int64(takeCount()))]
        case "w": return [.moveBytes(4 * Int64(takeCount()))]
        case "b": return [.moveBytes(-4 * Int64(takeCount()))]
        case "0", "^": count = ""; return [.rowStart]
        case "$": count = ""; return [.rowEnd]
        case "G": count = ""; return [.bottom]
        case "g", "m", "'", "r":
            pending = ch
            return []
        case "i", "a":
            count = ""
            let wasVisual = mode == .visual
            mode = .insert
            return (wasVisual ? [.endVisual] : []) + [.enterInsert(after: ch == "a")]
        case "R":
            count = ""
            mode = .replace
            return [.enterReplace]
        case "v":
            count = ""
            if mode == .visual { mode = .normal; return [.endVisual] }
            mode = .visual
            return [.startVisual]
        case "y":
            let n = takeCount()
            if mode == .visual { mode = .normal; return [.yank(count: 0), .endVisual] }
            return [.yank(count: n)]
        case "x", "d":
            let n = takeCount()
            if mode == .visual { mode = .normal; return [.delete(count: 0), .endVisual] }
            return ch == "x" ? [.delete(count: n)] : [.beep]
        case "p": count = ""; return [.paste(after: true)]
        case "P": count = ""; return [.paste(after: false)]
        case "u": count = ""; return [.undo]
        case "/": count = ""; return [.search]
        case "n": count = ""; return [.searchNext]
        case "N": count = ""; return [.searchPrevious]
        case ":": count = ""; return [.goToPrompt]
        default:
            count = ""
            return [.beep]
        }
    }
}
