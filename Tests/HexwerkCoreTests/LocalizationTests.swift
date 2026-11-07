import Foundation
import Testing
@testable import HexwerkCore

/// Keeps the translation tables complete and consistent (issue #40).
@Suite struct LocalizationTests {
    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources")

    static func swiftFiles() -> [URL] {
        let e = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// All `L("…")` keys with file:line, unescaped like Swift does.
    static func keys() throws -> [(key: String, at: String)] {
        let re = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])(?:L|LKey)\(\s*"((?:[^"\\]|\\.)*)""#)
        var out: [(String, String)] = []
        // Whole file, not line by line: swift-format may put the literal on
        // the line after `L(`. The key itself is still a single-line literal.
        for f in swiftFiles() where !f.path.contains("/Localization/") {
            let text = try String(contentsOf: f, encoding: .utf8)
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let raw = String(text[Range(m.range(at: 1), in: text)!])
                let line = text[..<Range(m.range, in: text)!.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                out.append((unescape(raw), "\(f.lastPathComponent):\(line)"))
            }
        }
        return out
    }

    static func unescape(_ s: String) -> String {
        var r = "", it = s.makeIterator()
        while let c = it.next() {
            guard c == "\\", let n = it.next() else { r.append(c); continue }
            switch n {
            case "n": r.append("\n")
            case "t": r.append("\t")
            case "0": r.append("\0")
            default: r.append(n)  // \" \\ \'
            }
        }
        return r
    }

    static func specifiers(_ s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:ll|l|h|hh|q|z|t|j)?[dDuUxXoOfFeEgGcCsSp@%]"#)
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }
            .filter { $0 != "%%" }
            .map { $0.replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression) }
            .sorted()
    }

    @Test func everyKeyIsTranslatedWithMatchingSpecifiers() throws {
        let de = L10n.tables[.de]!
        var missing: [String] = [], mismatched: [String] = []
        for (key, at) in try Self.keys() {
            guard let t = de[key] else { missing.append("\(at): \(key)"); continue }
            if Self.specifiers(key) != Self.specifiers(t) { mismatched.append("\(at): \(key) → \(t)") }
        }
        #expect(missing.isEmpty, "missing German translation:\n\(Set(missing).sorted().joined(separator: "\n"))")
        #expect(mismatched.isEmpty, "format specifiers differ:\n\(mismatched.joined(separator: "\n"))")
    }

    @Test func noUnusedTranslations() throws {
        let used = Set(try Self.keys().map(\.key))
        let unused = L10n.tables[.de]!.keys.filter { !$0.isEmpty && !used.contains($0) }.sorted()
        #expect(unused.isEmpty, "unused translations:\n\(unused.joined(separator: "\n"))")
    }

    /// German leftovers: string literals with umlauts outside the tables.
    @Test func noGermanLiteralsInCode() throws {
        let re = try NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*[äöüÄÖÜß](?:[^"\\]|\\.)*""#)
        var hits: [String] = []
        for f in Self.swiftFiles() where !f.path.contains("/Localization/") {
            let text = try String(contentsOf: f, encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                if re.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                    hits.append("\(f.lastPathComponent):\(n + 1)")
                }
            }
        }
        #expect(hits.isEmpty, "German text outside L10n tables:\n\(hits.joined(separator: "\n"))")
    }

    @Test func languageResolution() {
        #expect(L10n.resolve(environment: ["HEXWERK_LANG": "en", "LANG": "de_DE.UTF-8"], preferred: ["de"]) == .en)
        #expect(L10n.resolve(environment: ["LANG": "de_DE.UTF-8"], preferred: ["en"]) == .de)
        #expect(L10n.resolve(environment: ["LC_ALL": "C"], preferred: ["de"]) == .en)
        #expect(L10n.resolve(environment: [:], preferred: ["de-DE", "en"]) == .de)
        #expect(L10n.resolve(environment: [:], preferred: []) == .en)
    }

    @Test func formatsWithArguments() {
        let saved = L10n.override
        defer { L10n.override = saved }
        L10n.override = .en
        #expect(L("%lld bytes", Int64(3)) == "3 bytes")
        #expect(L("%lld bytes", Int64(99_999_999)) == "99999999 bytes")  // no grouping
        #expect(L("%.1f", 0.5) == "0.5")
        #expect(L("not a key") == "not a key")
    }
}
