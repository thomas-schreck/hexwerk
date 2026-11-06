import Foundation

/// Text taken from a (possibly hostile) file, made safe to print on a
/// terminal or to show in a one-line UI cell (issue #9).
///
/// A file can carry escape sequences (ESC ] 0; … BEL sets the window title,
/// ESC [ 2 J clears the screen), C1 controls such as CSI U+009B, or bidi
/// overrides that make text read differently than it is stored. All of them
/// are replaced by a visible escape.
public enum TerminalText {
    /// C0 controls, DEL, C1 controls and the bidi embedding/override/isolate
    /// characters (U+202A–U+202E, U+2066–U+2069).
    public static func isUnsafe(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x00...0x1F, 0x7F...0x9F, 0x202A...0x202E, 0x2066...0x2069: true
        default: false
        }
    }

    /// Unsafe scalars become `\xNN` (controls) or `\u{NNNN}` (bidi), so a
    /// value stays one line and the terminal never interprets it. Backslashes
    /// are left alone to keep paths and ordinary text readable.
    /// `keepingLayout` lets tab and line feed through, for multi-line output.
    public static func escape(_ s: String, keepingLayout: Bool = false) -> String {
        let unsafe = { (u: Unicode.Scalar) in isUnsafe(u) && !(keepingLayout && (u == "\t" || u == "\n")) }
        guard s.unicodeScalars.contains(where: unsafe) else { return s }
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            guard unsafe(u) else { out.append(u); continue }
            let code = u.value <= 0xFF ? String(format: "\\x%02X", u.value) : String(format: "\\u{%04X}", u.value)
            out.append(contentsOf: code.unicodeScalars)
        }
        return String(out)
    }

    /// For serialized JSON: JSON itself escapes U+0000–U+001F inside strings
    /// (C0 outside strings is layout whitespace); DEL, C1 and bidi become
    /// `\uNNNN`, which keeps the data lossless. They can only occur inside
    /// string literals, so the JSON stays valid.
    public static func escapeJSON(_ json: String) -> String {
        let unsafe = { (u: Unicode.Scalar) in u.value >= 0x7F && isUnsafe(u) }
        guard json.unicodeScalars.contains(where: unsafe) else { return json }
        var out = String.UnicodeScalarView()
        for u in json.unicodeScalars {
            if unsafe(u) { out.append(contentsOf: String(format: "\\u%04x", u.value).unicodeScalars) }
            else { out.append(u) }
        }
        return String(out)
    }
}
