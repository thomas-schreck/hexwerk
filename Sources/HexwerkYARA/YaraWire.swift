import Foundation
import HexwerkCore

// MARK: - Rule files for the sandboxed helper (#102)

/// Rule files read by the app or the CLI for compiling in a sandboxed
/// process, which cannot open files. `include` statements are followed here
/// by a plain text search (no YARA parsing), so the sandboxed process can
/// recreate the files YARA-X would look for; anything missed is reported by
/// the compiler as usual.
public struct YaraRuleBundle: Codable, Sendable, Equatable {
    /// The rule files, in order (path → text).
    public var sources: [Entry]
    /// Files possibly reached by `include`.
    public var includes: [Entry]
    public var includeDirs: [String]

    public struct Entry: Codable, Sendable, Equatable {
        public var path: String
        public var text: String
        /// How YARA-X names this file when it is included, in the reading
        /// process: the real path, relative to the working folder if below it.
        public var display: String

        public init(path: String, text: String, display: String? = nil) {
            self.path = path
            self.text = text
            self.display = display ?? path
        }
    }

    static let maxIncludes = 1000
    static let maxBytes = 64 << 20

    /// Reads `files`; a file that cannot be read is a compile error, as in
    /// `YaraRules.compile(files:)`.
    public static func collect(files: [URL]) throws -> YaraRuleBundle {
        let cwd = Self.realPath(FileManager.default.currentDirectoryPath)
        let display = { (path: String) in Self.relative(Self.realPath(path) ?? path, to: cwd) }
        let sources = try files.map { url in
            do { return Entry(path: url.path, text: try YaraSource(file: url).text, display: display(url.path)) } catch {
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
                    // Regular files only (a folder or device is "not found", as in YARA-X).
                    guard Self.isRegularFile(c), let text = try? String(contentsOfFile: c, encoding: .utf8) else { continue }
                    seen.insert(c)
                    let e = Entry(path: c, text: text, display: display(c))
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
    /// diagnostics are given back as YARA-X in the reading process would
    /// have printed them.
    public func compile(materializingIn root: URL) throws -> YaraRules {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // YARA-X names included files by their real path: /var/… is /private/var/….
        let prefix = Self.realPath(root.path) ?? root.standardizedFileURL.path
        let all = sources + includes
        // An absolute `include "/a/b.yar"` would make YARA-X read the
        // original file, which the sandbox denies. It becomes "a//b.yar",
        // found below `prefix` (added as the last include folder): the same
        // length, so columns and the report's markers stay right, and the
        // spelling is given back in the diagnostics. Only names of files that
        // were collected are rewritten.
        let collected = Set(all.map(\.path))
        var renamed: [String: String] = [:]
        for e in all {
            for name in Self.includeNames(in: e.text) where name.hasPrefix("/") && renamed[name] == nil {
                guard collected.contains(URL(fileURLWithPath: name).standardized.path) else { continue }
                renamed[name] = Self.relativeSpelling(name)
            }
        }
        func rewrite(_ text: String) -> String {
            guard !renamed.isEmpty else { return text }
            return text.replacing(/(include\s+")([^"\n]+)"/) { m in
                "\(m.1)\(renamed[String(m.2)] ?? String(m.2))\""
            }
        }
        for e in all {
            let target = URL(fileURLWithPath: prefix + e.path)
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(rewrite(e.text).utf8).write(to: target)
        }
        // What YARA-X prints for an included file here → what it would have
        // printed in the reading process. Longest first: one path can start
        // with another.
        let cwd = Self.realPath(FileManager.default.currentDirectoryPath)
        var names: [(String, String)] = all.map { (Self.relative(prefix + $0.path, to: cwd), $0.display) }
        // Rewritten names only in quotes (source excerpt) and backticks (messages).
        names += renamed.flatMap { [("\"\($0.value)\"", "\"\($0.key)\""), ("`\($0.value)`", "`\($0.key)`")] }
        names.sort { $0.0.count > $1.0.count }
        let restore = { (s: String) in
            var s = names.reduce(s) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
            if s.contains(prefix) { s = s.replacingOccurrences(of: prefix, with: "") }
            return s
        }
        let fix = { (d: YaraDiagnostic) in
            YaraDiagnostic(
                file: d.file.map(restore), line: d.line, column: d.column, code: d.code,
                message: restore(d.message), report: restore(d.report))
        }
        do {
            // The origins are the original paths: YARA-X only shows them
            // (includes of a top-level source are looked up in the folders).
            let rules = try YaraRules.compile(
                sources.map { YaraSource(origin: $0.path, text: rewrite($0.text)) },
                includeDirs: includeDirs.map { prefix + $0 } + (renamed.isEmpty ? [] : [prefix]))
            rules.warnings = rules.warnings.map(fix)
            return rules
        } catch let e as YaraCompileError {
            throw YaraCompileError(diagnostics: e.diagnostics.map(fix))
        }
    }

    /// "/a/b/c.yar" → "a//b/c.yar" (same length, relative). A file directly
    /// in / has no slash to double and becomes one character shorter.
    static func relativeSpelling(_ name: String) -> String {
        let rest = name.drop { $0 == "/" }
        guard let slash = rest.firstIndex(of: "/") else { return String(rest) }
        return String(rest[..<slash]) + "/" + String(rest[slash...])
    }

    static func isRegularFile(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    static func realPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// Like Rust's `Path::strip_prefix`, which YARA-X uses with the working folder.
    static func relative(_ path: String, to cwd: String?) -> String {
        guard let cwd else { return path }
        if cwd == "/" { return path.hasPrefix("/") ? String(path.dropFirst()) : path }
        return path.hasPrefix(cwd + "/") ? String(path.dropFirst(cwd.count + 1)) : path
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
    /// The scan's own time limit (`YaraScanError.timeout`), with its message.
    case timedOut(String, warnings: [YaraDiagnostic])

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
        case .timedOut(let message, let warnings):
            w.u8(3)
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
        case 3: self = .timedOut(try r.string(), warnings: try r.array { try YaraDiagnostic(&$0) })
        default: throw WireError("bad scan outcome")
        }
        try r.expectEnd()
    }
}
