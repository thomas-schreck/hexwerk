import ArgumentParser
import Foundation
import HexwerkCore
import HexwerkHelper
import HexwerkYARA

struct Yara: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: L("Scan a file with YARA rules (YARA-X %@).", YaraX.version),
        discussion: L("Rules: a file or a folder (all .yar/.yara in it). Exit 2 on compile error, 3 on timeout.")
    )

    @Argument(help: .init(L("Rule file or folder with rules"))) var rules: String
    @Argument(help: .init(L("File to scan"))) var file: String
    @Option(help: .init(L("Timeout in seconds"))) var timeout: Int = YaraX.defaultTimeout
    @Option(help: .init(L("Scan only from this offset (decimal or 0x...)"))) var offset: Number?
    @Option(help: .init(L("Scan only this many bytes"))) var length: Number?
    @Flag(name: .shortAndLong, help: .init(L("Print matching bytes per pattern (like yr -s)"))) var showMatches = false
    @Flag(help: .init(L("Output as JSON"))) var json = false

    func run() throws {
        // Rules are read here and compiled and run in the sandboxed child.
        // Messages keep the in-process order: rule errors and warnings
        // first, then a file that cannot be opened or a bad offset.
        let bundle: YaraRuleBundle
        do { bundle = try YaraRuleBundle.collect(files: try ruleFiles()) } catch let e as YaraCompileError {
            reportCompileErrors(e.diagnostics)
            throw ExitCode(2)
        }
        let opened = try? Document(url: URL(fileURLWithPath: file), readOnly: true).snapshot()
        let start = offset?.value ?? 0
        // Without a file to scan the child only compiles.
        let target = opened.flatMap { start <= $0.count ? $0 : nil }
        let range = target.map { snap in start ..< (length.map { start + min($0.value, snap.count - start) } ?? snap.count) }
        let outcome = try sandboxed(timeoutStatus: 3) { try $0.scan(target, rules: bundle, range: range, timeout: timeout) }
        let hits: [YaraRuleMatch], warnings: [YaraDiagnostic], failure: (message: String, status: Int32)?
        switch outcome {
        case .compileErrors(let d):
            reportCompileErrors(d)
            throw ExitCode(2)
        case .hits(let h, let w): (hits, warnings, failure) = (h, w, nil)
        case .failed(let m, let w): (hits, warnings, failure) = ([], w, (m, 1))
        case .timedOut(let m, let w): (hits, warnings, failure) = ([], w, (m, 3))
        }
        for w in warnings { FileHandle.standardError.write(Data((L("Warning: %@", "\(w)") + "\n").utf8)) }

        let snap = try opened ?? openSnapshot(file)
        guard target != nil else {
            FileHandle.standardError.write(Data(("hexwerk: " + L("Offset is past the end of the file") + "\n").utf8))
            throw ExitCode(1)
        }
        if let failure {
            FileHandle.standardError.write(Data("hexwerk: \(failure.message)\n".utf8))
            throw ExitCode(failure.status)
        }

        if json {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try enc.encode(hits), as: UTF8.self))
            return
        }
        for h in hits {
            print(h.tags.isEmpty ? "\(h.rule) \(file)" : "\(h.rule) [\(h.tags.joined(separator: ","))] \(file)")
            guard showMatches else { continue }
            for m in h.matches {
                let bytes = snap.read(m.offset ..< m.offset + min(m.length, 64))
                print("0x\(String(m.offset, radix: 16)):\(m.length):\(m.pattern): \(escape(bytes))\(m.length > 64 ? " …" : "")")
            }
        }
    }

    private func reportCompileErrors(_ diagnostics: [YaraDiagnostic]) {
        for d in diagnostics { FileHandle.standardError.write(Data("\(d.report.isEmpty ? d.description : d.report)\n".utf8)) }
    }

    private func ruleFiles() throws -> [URL] {
        let url = URL(fileURLWithPath: rules)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            FileHandle.standardError.write(Data(("hexwerk: " + L("%@: not found", rules) + "\n").utf8))
            throw ExitCode(1)
        }
        guard isDir.boolValue else { return [url] }
        let found = (FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { ["yar", "yara"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }
        guard !found.isEmpty else {
            FileHandle.standardError.write(Data(("hexwerk: " + L("no .yar/.yara files in %@", rules) + "\n").utf8))
            throw ExitCode(1)
        }
        return found
    }

    /// Printable ASCII as is, everything else as \xNN (like yr).
    private func escape(_ d: Data) -> String {
        d.map { b in
            (0x20 ..< 0x7F).contains(b) && b != 0x5C ? String(UnicodeScalar(b)) : String(format: "\\x%02x", b)
        }.joined()
    }
}
