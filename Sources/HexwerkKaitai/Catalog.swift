import Foundation

/// The .ksy files of a format collection (kaitai_struct_formats layout:
/// <category>/<id>.ksy), indexed by id and file extension without parsing
/// every file: id and extensions are read from the meta block text.
public struct FormatCatalog: Sendable {
    public struct Entry: Sendable, Identifiable, Hashable {
        public let id: String
        public let title: String
        public let category: String
        public let url: URL
        public let extensions: [String]
    }

    public let root: URL
    public let entries: [Entry]

    public init(root: URL, extraRoots: [URL] = []) {
        self.root = root
        var found: [String: Entry] = [:]
        // Later roots win: own formats override the collection.
        for r in [root] + extraRoots {
            guard let e = FileManager.default.enumerator(at: r, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.pathExtension == "ksy" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let id = Self.metaValue("id", in: text) ?? url.deletingPathExtension().lastPathComponent
                let title = Self.metaValue("title", in: text) ?? id
                let category = url.deletingLastPathComponent().lastPathComponent
                found[id] = Entry(id: id, title: title, category: category, url: url, extensions: Self.extensions(in: text))
            }
        }
        entries = found.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public func url(forID id: String) -> URL? { entries.first { $0.id == id }?.url }

    /// Formats claiming the file's extension.
    public func matching(fileExtension ext: String) -> [Entry] {
        let e = ext.lowercased()
        return entries.filter { $0.extensions.contains(e) }
    }

    static func metaValue(_ key: String, in text: String) -> String? {
        guard let m = text.range(of: "(?m)^meta:\\s*$", options: .regularExpression) else { return nil }
        let after = text[m.upperBound...]
        guard let r = after.range(of: "(?m)^  \(key):[ \\t]*(.+)$", options: .regularExpression) else { return nil }
        let line = after[r]
        var v = line.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
        v = v.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("'") || v.hasPrefix("\"") { v = String(v.dropFirst().dropLast()) }
        return v.isEmpty ? nil : v
    }

    static func extensions(in text: String) -> [String] {
        guard let m = text.range(of: "(?m)^meta:\\s*$", options: .regularExpression) else { return [] }
        let after = String(text[m.upperBound...])
        guard let r = after.range(of: "(?m)^  file-extension:(.*)$", options: .regularExpression) else { return [] }
        // Value after the colon; empty means a block list follows.
        let first =
            after[r].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if !first.isEmpty {
            return first.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        }
        // Block list on the following lines: "    - png"
        var out: [String] = []
        for line in after[r.upperBound...].split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- ") else { break }
            out.append(String(t.dropFirst(2)).lowercased())
        }
        return out
    }
}
