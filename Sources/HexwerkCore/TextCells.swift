import Foundation

/// How one byte shows up in the text column.
public enum TextCell: Equatable, Sendable {
    /// Printable character starting at this byte, covering `span` bytes.
    case char(Character, span: Int)
    /// Byte that belongs to a character starting earlier.
    case continuation
    /// Control character, invalid sequence or something not worth drawing.
    case unprintable
}

public enum TextEncodingView: String, CaseIterable, Sendable {
    case ascii = "ASCII", latin1 = "Latin-1", utf8 = "UTF-8"
}

public enum TextCells {
    /// Cells for `bytes[from...]`. Bytes before `from` are context only: pass
    /// up to three bytes before the visible range so that a character whose
    /// first byte scrolled off the top still decodes.
    public static func decode(_ bytes: [UInt8], from: Int = 0, as encoding: TextEncodingView) -> [TextCell] {
        switch encoding {
        case .ascii:
            return bytes[from...].map { (0x20 ... 0x7E).contains($0) ? .char(Character(UnicodeScalar($0)), span: 1) : .unprintable }
        case .latin1:
            return bytes[from...].map {
                (0x20 ... 0x7E).contains($0) || $0 >= 0xA0 ? .char(Character(UnicodeScalar($0)), span: 1) : .unprintable
            }
        case .utf8:
            return utf8(bytes, from: from)
        }
    }

    private static func utf8(_ b: [UInt8], from: Int) -> [TextCell] {
        var cells = [TextCell](repeating: .unprintable, count: b.count)
        var i = 0
        while i < b.count {
            let lead = b[i]
            let len =
                lead < 0x80 ? 1 : lead >= 0xC2 && lead <= 0xDF ? 2 : lead >= 0xE0 && lead <= 0xEF ? 3 : lead >= 0xF0 && lead <= 0xF4 ? 4 : 0
            // Decoding the slice rejects overlong forms, surrogates and
            // values above U+10FFFF; a cut-off sequence at the end fails too.
            if len > 0, i + len <= b.count,
                let s = String(bytes: b[i ..< i + len], encoding: .utf8), let ch = s.first
            {
                cells[i] = printable(ch) ? .char(ch, span: len) : .unprintable
                for k in 1 ..< len { cells[i + k] = .continuation }
                i += len
            } else {
                i += 1  // stays .unprintable
            }
        }
        return Array(cells[from...])
    }

    /// Controls, format characters and lone combining marks would draw as
    /// nothing or mess up the grid.
    static func printable(_ ch: Character) -> Bool {
        guard let s = ch.unicodeScalars.first else { return false }
        switch s.properties.generalCategory {
        case .control, .format, .nonspacingMark, .enclosingMark, .spacingMark,
            .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned:
            return false
        default:
            return s.value != 0x7F
        }
    }
}
