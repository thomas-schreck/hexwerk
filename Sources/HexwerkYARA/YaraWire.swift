import Foundation
import HexwerkCore

// MARK: - Rule files for the sandboxed helper (#102)

/// Rule files read by the app for compiling in the sandboxed helper, which
/// cannot open files. `include` statements are followed here by a plain text
/// search (no YARA parsing), so the helper can recreate the files YARA-X
/// would look for; anything missed is reported by the compiler as usual.
public struct YaraRuleBundle: Codable, Sendable, Equatable {
    /// The rule files, in order (path → text).
    public var sources: [Entry]
    /// Files possibly reached by `include`.
    public var includes: [Entry]
    public var includeDirs: [String]

    public struct Entry: Codable, Sendable, Equatable {
        public var path: String
        public var text: String
    }

    static let maxIncludes = 1000
    static let maxBytes = 64 << 20

    /// Reads `files`; a file that cannot be read is a compile error, as in
    /// `YaraRules.compile(files:)`.
    public static func collect(files: [URL]) throws -> YaraRuleBundle {
        let sources = try files.map { url in
            do { return Entry(path: url.path, text: try YaraSource(file: url).text) } catch {
                throw YaraCompileError(diagnostics: [
                    YaraDiagnostic(
                        file: url.path, line: nil, column: nil, code: "io",
                        message: L("cannot be read: %@", error.localizedDescription), report: "")
                ])
            }
        }
        let dirs = Array(Set(files.map { $0.deletingLastPathComponent().path })).sorted()
        var seen = Set(sources.map(\.path))
        var includes: [Entry] = []
        var queue = sources
        var bytes = sources.reduce(0) { $0 + $1.text.utf8.count }
        while let file = queue.popLast(), includes.count < maxIncludes, bytes < maxBytes {
            let here = URL(fileURLWithPath: file.path).deletingLastPathComponent().path
            for name in includeNames(in: file.text) {
                let candidates = name.hasPrefix("/") ? [name] : ([here] + dirs).map { $0 + "/" + name }
                // `standardized`, not `standardizedFileURL`: the latter turns
                // /private/tmp/x into /tmp/x for existing files only, and the
                // include would then be written where YARA-X does not look.
                for c in candidates.map({ URL(fileURLWithPath: $0).standardized.path }) where !seen.contains(c) {
                    guard let text = try? String(contentsOfFile: c, encoding: .utf8) else { continue }
                    seen.insert(c)
                    let e = Entry(path: c, text: text)
                    includes.append(e)
                    queue.append(e)
                    bytes += text.utf8.count
                }
            }
        }
        return YaraRuleBundle(sources: sources, includes: includes, includeDirs: dirs)
    }

    static func includeNames(in text: String) -> [String] {
        text.matches(of: /include\s+"([^"\n]+)"/).map { String($0.1) }
    }

    /// Writes all files below `root` at their original paths and compiles
    /// from there, so includes resolve as they would in place. Paths in the
    /// diagnostics are given back without `root`.
    public func compile(materializingIn root: URL) throws -> YaraRules {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.standardizedFileURL.path
        for e in sources + includes {
            let target = URL(fileURLWithPath: prefix + e.path)
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(e.text.utf8).write(to: target)
        }
        let unprefix = { (s: String) in s.replacingOccurrences(of: prefix, with: "") }
        let fix = { (d: YaraDiagnostic) in
            YaraDiagnostic(
                file: d.file.map(unprefix), line: d.line, column: d.column, code: d.code,
                message: unprefix(d.message), report: unprefix(d.report))
        }
        do {
            let rules = try YaraRules.compile(
                sources.map { YaraSource(origin: prefix + $0.path, text: $0.text) },
                includeDirs: includeDirs.map { prefix + $0 })
            rules.warnings = rules.warnings.map(fix)
            return rules
        } catch let e as YaraCompileError {
            throw YaraCompileError(diagnostics: e.diagnostics.map(fix))
        }
    }
}

// MARK: - Results

extension YaraDiagnostic {
    func write(_ w: inout WireWriter) {
        w.optional(file) { $0.string($1) }
        w.optional(line) { $0.int($1) }
        w.optional(column) { $0.int($1) }
        w.string(code)
        w.string(message)
        w.string(report)
    }

    init(_ r: inout WireReader) throws {
        self.init(
            file: try r.optional { try $0.string() }, line: try r.optional { try $0.int() },
            column: try r.optional { try $0.int() }, code: try r.string(), message: try r.string(),
            report: try r.string())
    }
}

/// What a scan in the helper produced: hits, or why there are none.
public enum YaraScanOutcome: Sendable {
    case hits([YaraRuleMatch], warnings: [YaraDiagnostic])
    case compileErrors([YaraDiagnostic])
    case failed(String, warnings: [YaraDiagnostic])

    public func encoded() -> Data {
        var w = WireWriter()
        switch self {
        case .hits(let hits, let warnings):
            w.u8(0)
            w.array(warnings) { w, d in d.write(&w) }
            w.array(hits) { w, h in
                w.string(h.rule)
                w.string(h.namespace)
                w.array(h.tags) { $0.string($1) }
                w.array(h.metadata) { w, m in
                    w.string(m.key); w.string(m.value)
                }
                w.array(h.matches) { w, m in
                    w.string(m.pattern)
                    w.uint(m.offset)
                    w.uint(m.length)
                    w.optional(m.xorKey) { $0.int($1) }
                }
            }
        case .compileErrors(let d):
            w.u8(1)
            w.array(d) { w, d in d.write(&w) }
        case .failed(let message, let warnings):
            w.u8(2)
            w.string(message)
            w.array(warnings) { w, d in d.write(&w) }
        }
        return w.data
    }

    public init(encoded data: Data) throws {
        var r = WireReader(data)
        switch try r.u8() {
        case 0:
            let warnings = try r.array { try YaraDiagnostic(&$0) }
            let hits = try r.array { r in
                YaraRuleMatch(
                    rule: try r.string(), namespace: try r.string(), tags: try r.array { try $0.string() },
                    metadata: try r.array { YaraMeta(key: try $0.string(), value: try $0.string()) },
                    matches: try r.array(minSize: 4) { r in
                        let pattern = try r.string(), offset = try r.uint(), length = try r.uint()
                        guard !offset.addingReportingOverflow(length).overflow else { throw WireError("match out of range") }
                        return YaraPatternMatch(
                            pattern: pattern, offset: offset, length: length,
                            xorKey: try r.optional { try $0.int() })
                    })
            }
            self = .hits(hits, warnings: warnings)
        case 1: self = .compileErrors(try r.array { try YaraDiagnostic(&$0) })
        case 2: self = .failed(try r.string(), warnings: try r.array { try YaraDiagnostic(&$0) })
        default: throw WireError("bad scan outcome")
        }
        try r.expectEnd()
    }
}
