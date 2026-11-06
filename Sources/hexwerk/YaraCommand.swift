import ArgumentParser
import Foundation
import HexwerkCore
import HexwerkYARA

struct Yara: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: L("Scan a file with YARA rules (YARA-X %@).", YaraX.version),
        discussion: L("Rules: a file or a folder (all .yar/.yara in it). Exit 2 on compile error, 3 on timeout.")
    )

    @Argument(help: .init(L("Rule file or folder with rules"))) var rules: String
    @Argument(help: .init(L("File to scan"))) var file: String
    @Option(help: .init(L("Timeout in seconds"))) var timeout: Int = YaraX.defaultTimeout
    @Option(help: .init(L("Scan only from this offset (decimal or 0x…)"))) var offset: Number?
    @Option(help: .init(L("Scan only this many bytes"))) var length: Number?
    @Flag(name: .shortAndLong, help: .init(L("Print matching bytes per pattern (like yr -s)"))) var showMatches = false
    @Flag(help: .init(L("Output as JSON"))) var json = false

    func run() throws {
        let files = try ruleFiles()
        let compiled: YaraRules
        do { compiled = try YaraRules.compile(files: files) }
        catch let e as YaraCompileError {
            for d in e.diagnostics { FileHandle.standardError.write(Data("\(d.report.isEmpty ? d.description : d.report)\n".utf8)) }
            throw ExitCode(2)
        }
        for w in compiled.warnings { FileHandle.standardError.write(Data((L("Warning: %@", "\(w)") + "\n").utf8)) }

        let snap = try openSnapshot(file)
        let start = offset?.value ?? 0
        guard start <= snap.count else {
            FileHandle.standardError.write(Data(("hexwerk: " + L("Offset is past the end of the file") + "\n").utf8))
            throw ExitCode(1)
        }
        let end = length.map { start + min($0.value, snap.count - start) } ?? snap.count
        let hits: [YaraRuleMatch]
        do { hits = try compiled.scan(snap, range: start ..< end, timeout: timeout) }
        catch let e as YaraScanError {
            FileHandle.standardError.write(Data("hexwerk: \(e)\n".utf8))
            if case .timeout = e { throw ExitCode(3) }
            throw ExitCode(1)
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
            (0x20..<0x7F).contains(b) && b != 0x5C ? String(UnicodeScalar(b)) : String(format: "\\x%02x", b)
        }.joined()
    }
}
