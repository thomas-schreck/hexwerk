internal import CYaraX
import Foundation
import HexwerkCore

/// Thin Swift layer over the YARA-X C API (SPEC FR-7.x). Everything the C
/// side hands out (rule names, metadata, matches) is only valid inside its
/// callback, so it is copied into Swift values right there.
public enum YaraX {
    public static let version = "\(YARA_X_MAJOR).\(YARA_X_MINOR).\(YARA_X_PATCH)"

    /// Default scan timeout in seconds (SPEC appendix).
    public static let defaultTimeout = 60

    static var lastError: String {
        yrx_last_error().map { String(cString: $0) } ?? L("unknown YARA-X error")
    }
}

// MARK: - Compiling

/// One rule source, usually a file. `origin` appears in error messages.
public struct YaraSource: Sendable {
    public let origin: String
    public let text: String

    public init(origin: String, text: String) {
        self.origin = origin
        self.text = text
    }

    public init(file url: URL) throws {
        origin = url.path
        text = try String(contentsOf: url, encoding: .utf8)
    }
}

/// A compiler error or warning, with the position resolved to line/column.
public struct YaraDiagnostic: Sendable, Codable, CustomStringConvertible {
    public let file: String?
    public let line: Int?
    public let column: Int?
    public let code: String
    public let message: String
    /// Full report as `yr` prints it (with source excerpt).
    public let report: String

    public var description: String {
        var where_ = file.map { URL(fileURLWithPath: $0).lastPathComponent } ?? L("rule")
        if let line { where_ += ":\(line)" }
        if let column { where_ += ":\(column)" }
        return "\(where_): \(message)"
    }
}

public struct YaraCompileError: Error, CustomStringConvertible {
    public let diagnostics: [YaraDiagnostic]
    public var description: String { diagnostics.map(\.description).joined(separator: "\n") }
}

public final class YaraRules: @unchecked Sendable {
    // Immutable after compiling; YARA-X allows sharing rules across threads,
    // each scan gets its own scanner.
    let ptr: OpaquePointer
    public let count: Int
    public let warnings: [YaraDiagnostic]

    private init(ptr: OpaquePointer, warnings: [YaraDiagnostic]) {
        self.ptr = ptr
        self.warnings = warnings
        count = Int(yrx_rules_count(ptr))
    }

    deinit { yrx_rules_destroy(ptr) }

    public static func compile(files: [URL]) throws -> YaraRules {
        let sources = try files.map { url in
            do { return try YaraSource(file: url) } catch {
                throw YaraCompileError(diagnostics: [YaraDiagnostic(
                    file: url.path, line: nil, column: nil, code: "io",
                    message: L("cannot be read: %@", error.localizedDescription), report: "")])
            }
        }
        // `include "x.yar"` resolves against the including file's folder.
        let dirs = Array(Set(files.map { $0.deletingLastPathComponent().path })).sorted()
        return try compile(sources, includeDirs: dirs)
    }

    public static func compile(_ sources: [YaraSource], includeDirs: [String] = []) throws -> YaraRules {
        var comp: OpaquePointer?
        guard yrx_compiler_create(0, &comp) == YRX_SUCCESS, let comp else {
            throw YaraCompileError(diagnostics: [plain(YaraX.lastError)])
        }
        defer { yrx_compiler_destroy(comp) }
        for d in includeDirs { _ = yrx_compiler_add_include_dir(comp, d) }

        var failed = false
        for s in sources where yrx_compiler_add_source_with_origin(comp, s.text, s.origin) != YRX_SUCCESS {
            failed = true
        }
        let texts = Dictionary(sources.map { ($0.origin, $0.text) }, uniquingKeysWith: { a, _ in a })
        let errors = diagnostics(comp, errors: true, sources: texts)
        if failed || !errors.isEmpty {
            throw YaraCompileError(diagnostics: errors.isEmpty ? [plain(YaraX.lastError)] : errors)
        }
        let warnings = diagnostics(comp, errors: false, sources: texts)
        guard let rules = yrx_compiler_build(comp) else {
            throw YaraCompileError(diagnostics: [plain(YaraX.lastError)])
        }
        return YaraRules(ptr: rules, warnings: warnings)
    }

    private static func plain(_ message: String) -> YaraDiagnostic {
        YaraDiagnostic(file: nil, line: nil, column: nil, code: "", message: message, report: message)
    }

    private struct JSONDiag: Decodable {
        struct Label: Decodable {
            struct Span: Decodable { let start: Int }
            let code_origin: String?
            let span: Span?
        }
        let code: String?
        let title: String?
        let labels: [Label]?
        let text: String?
    }

    private static func diagnostics(_ comp: OpaquePointer, errors: Bool,
                                    sources: [String: String]) -> [YaraDiagnostic] {
        var buf: UnsafeMutablePointer<YRX_BUFFER>?
        let r = errors ? yrx_compiler_errors_json(comp, &buf) : yrx_compiler_warnings_json(comp, &buf)
        guard r == YRX_SUCCESS, let buf else { return [] }
        defer { yrx_buffer_destroy(buf) }
        let data = Data(bytes: buf.pointee.data, count: buf.pointee.length)
        guard let list = try? JSONDecoder().decode([JSONDiag].self, from: data) else { return [] }
        return list.map { d in
            let label = d.labels?.first
            // The origin is null when there is a single source without one.
            let file = label?.code_origin ?? (sources.count == 1 ? sources.keys.first : nil)
            var line: Int?, column: Int?
            if let start = label?.span?.start, let file, let text = sources[file] {
                (line, column) = lineColumn(text, byteOffset: start)
            }
            return YaraDiagnostic(file: file, line: line, column: column, code: d.code ?? "",
                                  message: d.title ?? L("Error"), report: d.text ?? d.title ?? "")
        }
    }

    /// Spans are byte offsets into the UTF-8 source.
    static func lineColumn(_ text: String, byteOffset: Int) -> (Int, Int) {
        let bytes = Array(text.utf8.prefix(byteOffset))
        let line = bytes.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
        let lineStart = bytes.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        let column = String(decoding: bytes[lineStart...], as: UTF8.self).count + 1
        return (line, column)
    }
}

// MARK: - Scanning

public struct YaraPatternMatch: Sendable, Codable, Hashable {
    public let pattern: String
    public let offset: UInt64
    public let length: UInt64
    /// Key for patterns with the `xor` modifier.
    public let xorKey: Int?

    public var range: Range<UInt64> { offset ..< offset + length }
}

public struct YaraMeta: Sendable, Codable, Hashable {
    public let key: String
    public let value: String
}

public struct YaraRuleMatch: Sendable, Codable, Identifiable, Hashable {
    public let rule: String
    public let namespace: String
    public let tags: [String]
    public let metadata: [YaraMeta]
    /// Empty for rules that match by condition only.
    public let matches: [YaraPatternMatch]

    public var id: String { namespace + "." + rule }
}

public enum YaraScanError: Error, CustomStringConvertible {
    case timeout(Int)
    case failed(String)

    public var description: String {
        switch self {
        case .timeout(let s): L("Time limit of %ld s exceeded", s)
        case .failed(let m): m
        }
    }
}

extension YaraRules {
    /// Scans `data`. Match offsets are shifted by `base`, so a scan of a
    /// selection reports file offsets (FR-7.3). `maxMatchesPerPattern` caps
    /// how many hits YARA-X records per pattern (nil: YARA-X default).
    public func scan(_ data: UnsafeRawBufferPointer, base: UInt64 = 0,
                     timeout: Int = YaraX.defaultTimeout,
                     maxMatchesPerPattern: Int? = nil) throws -> [YaraRuleMatch] {
        var scanner: OpaquePointer?
        guard yrx_scanner_create(ptr, &scanner) == YRX_SUCCESS, let scanner else {
            throw YaraScanError.failed(YaraX.lastError)
        }
        defer { yrx_scanner_destroy(scanner) }
        _ = yrx_scanner_set_timeout(scanner, UInt64(max(1, timeout)))
        if let maxMatchesPerPattern { _ = yrx_scanner_max_matches_per_pattern(scanner, maxMatchesPerPattern) }

        let collector = Collector(base: base)
        let ud = Unmanaged.passUnretained(collector).toOpaque()
        _ = yrx_scanner_on_matching_rule(scanner, { rule, ud in
            guard let rule, let ud else { return }
            Unmanaged<Collector>.fromOpaque(ud).takeUnretainedValue().add(rule)
        }, ud)

        let result = withExtendedLifetime(collector) {
            onLargeStack {
                yrx_scanner_scan(scanner, data.baseAddress?.assumingMemoryBound(to: UInt8.self), data.count)
            }
        }
        switch result {
        case YRX_SUCCESS: return collector.rules
        case YRX_SCAN_TIMEOUT: throw YaraScanError.timeout(timeout)
        default: throw YaraScanError.failed(YaraX.lastError)
        }
    }

    /// Scans a document snapshot (current, possibly unsaved content: FR-7.6).
    public func scan(_ snapshot: Snapshot, range: Range<UInt64>? = nil,
                     timeout: Int = YaraX.defaultTimeout,
                     maxMatchesPerPattern: Int? = nil) throws -> [YaraRuleMatch] {
        let r = (range ?? 0 ..< snapshot.count).clamped(to: 0 ..< snapshot.count)
        return try snapshot.withContiguousBytes(r) {
            try scan($0, base: r.lowerBound, timeout: timeout, maxMatchesPerPattern: maxMatchesPerPattern)
        }
    }
}

// Scans run via `onLargeStack` (HexwerkCore): YARA-X executes conditions in
// wasmtime, whose wasm stack limit (512 KiB by default) must fit on the host
// thread, more than Swift concurrency threads have.

/// Boxes handed to the C callbacks as `user_data`.
private final class Collector {
    let base: UInt64
    var rules: [YaraRuleMatch] = []
    init(base: UInt64) { self.base = base }

    func add(_ rule: OpaquePointer) {
        let name = Self.string { yrx_rule_identifier(rule, $0, $1) }
        let ns = Self.string { yrx_rule_namespace(rule, $0, $1) }

        let tags = Box<[String]>([])
        _ = yrx_rule_iter_tags(rule, { tag, ud in
            guard let tag, let ud else { return }
            Unmanaged<Box<[String]>>.fromOpaque(ud).takeUnretainedValue().value.append(String(cString: tag))
        }, Unmanaged.passUnretained(tags).toOpaque())

        let meta = Box<[YaraMeta]>([])
        _ = yrx_rule_iter_metadata(rule, { m, ud in
            guard let m, let ud else { return }
            Unmanaged<Box<[YaraMeta]>>.fromOpaque(ud).takeUnretainedValue().value.append(Collector.meta(m.pointee))
        }, Unmanaged.passUnretained(meta).toOpaque())

        let matches = Box<PatternState>(PatternState(base: base))
        _ = yrx_rule_iter_patterns(rule, { pattern, ud in
            guard let pattern, let ud else { return }
            let box = Unmanaged<Box<PatternState>>.fromOpaque(ud).takeUnretainedValue()
            box.value.current = Collector.string { yrx_pattern_identifier(pattern, $0, $1) }
            _ = yrx_pattern_iter_matches(pattern, { m, ud in
                guard let m, let ud else { return }
                let box = Unmanaged<Box<PatternState>>.fromOpaque(ud).takeUnretainedValue()
                let k = Int(m.pointee.xor_key)
                box.value.out.append(YaraPatternMatch(
                    pattern: box.value.current, offset: box.value.base + UInt64(m.pointee.offset),
                    length: UInt64(m.pointee.length), xorKey: k < 0 ? nil : k))
            }, ud)
        }, Unmanaged.passUnretained(matches).toOpaque())

        withExtendedLifetime((tags, meta, matches)) {
            rules.append(YaraRuleMatch(rule: name, namespace: ns, tags: tags.value, metadata: meta.value,
                                       matches: matches.value.out.sorted { ($0.offset, $0.pattern) < ($1.offset, $1.pattern) }))
        }
    }

    struct PatternState {
        let base: UInt64
        var current = ""
        var out: [YaraPatternMatch] = []
    }

    /// Identifiers come as (pointer, length), not NUL-terminated.
    static func string(_ get: (UnsafeMutablePointer<UnsafePointer<UInt8>?>, UnsafeMutablePointer<Int>) -> YRX_RESULT) -> String {
        var p: UnsafePointer<UInt8>?
        var n = 0
        guard get(&p, &n) == YRX_SUCCESS, let p else { return "" }
        return String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)
    }

    static func meta(_ m: YRX_METADATA) -> YaraMeta {
        let key = m.identifier.map { String(cString: $0) } ?? ""
        let value: String = switch m.value_type {
        case YRX_I64: String(m.value.i64)
        case YRX_F64: String(m.value.f64)
        case YRX_BOOLEAN: m.value.boolean ? "true" : "false"
        case YRX_STRING: m.value.string.map { String(cString: $0) } ?? ""
        case YRX_BYTES:
            UnsafeBufferPointer(start: m.value.bytes.data, count: m.value.bytes.length)
                .map { String(format: "%02X", $0) }.joined(separator: " ")
        default: ""
        }
        return YaraMeta(key: key, value: value)
    }
}

private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}
