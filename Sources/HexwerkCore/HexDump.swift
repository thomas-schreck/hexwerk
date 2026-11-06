import Foundation

/// Text hex dump. With width 16 the format matches `hexdump -C -v`
/// (offset, two groups of eight bytes, |ascii|), which makes it easy to test.
public enum HexDump {
    public static func lines(_ data: Data, startOffset: UInt64, width: Int = 16) -> [String] {
        let bytes = [UInt8](data)
        var out: [String] = []
        var i = 0
        while i < bytes.count {
            let row = bytes[i ..< min(i + width, bytes.count)]
            var hex = ""
            for col in 0 ..< width {
                if col > 0 && col % 8 == 0 { hex += " " }
                hex += col < row.count ? String(format: "%02x ", row[row.startIndex + col]) : "   "
            }
            let ascii = String(row.map { (0x20 ... 0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
            out.append(String(format: "%08llx  ", startOffset + UInt64(i)) + hex + " |\(ascii)|")
            i += width
        }
        // hexdump ends with the offset just past the data.
        out.append(String(format: "%08llx", startOffset + UInt64(bytes.count)))
        return out
    }
}
