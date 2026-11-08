import Foundation
import HexwerkCore
import HexwerkKaitai
import HexwerkMagic
import HexwerkScript
import HexwerkYARA

/// The parsers' work, shared by the app's XPC helper (#102) and the CLI's
/// sandboxed child process (#129). Both pass the decoded request and the
/// snapshot rebuilt over the received descriptor and send back the result.
enum HelperWork {
    /// `snapshot` nil: only load the .ksy (`.loaded` or `.loadError`).
    static func parse(
        _ req: ParseRequest, _ snapshot: Snapshot?, isCancelled: @escaping () -> Bool,
        read: @escaping (URL) throws -> String?
    ) -> Data {
        let file: KsyFile
        do {
            let loader = KsyLoader(libraryRoots: req.libraryRoots.map { URL(fileURLWithPath: $0) }, read: read)
            file = try loader.load(URL(fileURLWithPath: req.ksy))
        } catch {
            return ParseOutcome.loadError(String(describing: error)).encoded()
        }
        guard let snapshot else { return ParseOutcome.loaded.encoded() }
        let result = KaitaiInterpreter.parse(snapshot, file: file, shouldContinue: { !isCancelled() })
        return ParseOutcome.result(result).encoded()
    }

    /// The rule files are written below `scratch` for compiling (includes).
    /// `snapshot` nil: only compile (no hits, the warnings or errors).
    /// `compiled` is called once the rules are compiled (the CLI's child
    /// starts the scan's time limit there).
    static func scan(_ req: ScanRequest, _ snapshot: Snapshot?, scratch: URL, compiled: () -> Void = {}) throws -> Data {
        let rules: YaraRules
        do {
            rules = try req.rules.compile(materializingIn: scratch.appendingPathComponent("yara-\(UUID().uuidString)"))
        } catch let e as YaraCompileError {
            return YaraScanOutcome.compileErrors(e.diagnostics).encoded()
        }
        compiled()
        guard let snapshot else { return YaraScanOutcome.hits([], warnings: rules.warnings).encoded() }
        do {
            let hits = try rules.scan(
                snapshot, range: req.range, timeout: req.timeout,
                maxMatchesPerPattern: req.maxMatchesPerPattern)
            return YaraScanOutcome.hits(hits, warnings: rules.warnings).encoded()
        } catch {
            if case YaraScanError.timeout = error {
                return YaraScanOutcome.timedOut(String(describing: error), warnings: rules.warnings).encoded()
            }
            return YaraScanOutcome.failed(String(describing: error), warnings: rules.warnings).encoded()
        }
    }

    static func runScript(_ req: ScriptRequest, _ snapshot: Snapshot, isCancelled: @escaping @Sendable () -> Bool) -> Data {
        let copy = Document(editing: snapshot, readOnly: req.readOnly)
        let ctx = ScriptContext(
            cursor: req.cursor, selection: req.selection, fileName: req.fileName, baseAddress: req.baseAddress)
        let r = ScriptRunner.run(
            req.source, name: req.name, document: copy, context: ctx,
            timeout: req.timeout, isCancelled: isCancelled)
        let edited =
            r.error == nil && copy.isModified
            ? copy.editedContent(sentAddedCount: req.header.snapshot.added.count) : nil
        return ScriptOutcome(result: r, edited: edited).encoded()
    }

    static func detectType(_ req: TypeRequest, database: MagicDatabase?) -> Data {
        TypeOutcome(description: database?.describe(req.sample), mime: database?.mime(req.sample)).encoded()
    }
}
