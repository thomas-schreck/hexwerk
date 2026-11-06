import Foundation

/// Text renderings of a byte range for the clipboard or a file (SPEC FR-9.4).
public enum ExportFormat: String, CaseIterable, Sendable {
    case hex, c, python, swift, base64

    public var title: String {
        switch self {
        case .hex: "Hex"
        case .c: L("C array")
        case .python: "Python bytes"
        case .swift: "Swift [UInt8]"
        case .base64: "Base64"
        }
    }

    public func render(_ data: Data, name: String = "data") -> String {
        switch self {
        case .hex:
            return data.map { String(format: "%02X", $0) }.joined(separator: " ")
        case .base64:
            return data.base64EncodedString()
        case .c:
            return "unsigned char \(name)[\(data.count)] = {\n\(Self.lines(data, "0x%02X"))\n};"
        case .swift:
            return "let \(name): [UInt8] = [\n\(Self.lines(data, "0x%02X"))\n]"
        case .python:
            // \xNN for everything except safe printable ASCII, like repr().
            let body = data.map { b -> String in
                switch b {
                case 0x5C: "\\\\"
                case 0x22: "\\\""
                case 0x20..<0x7F: String(UnicodeScalar(b))
                default: String(format: "\\x%02x", b)
                }
            }.joined()
            return "\(name) = b\"\(body)\""
        }
    }

    /// 12 values per line, indented, comma separated.
    private static func lines(_ data: Data, _ fmt: String) -> String {
        let items = data.map { String(format: fmt, $0) }
        return stride(from: 0, to: items.count, by: 12).map {
            "    " + items[$0 ..< min($0 + 12, items.count)].joined(separator: ", ")
        }.joined(separator: ",\n")
    }
}
