import ArgumentParser
import Foundation
import HexwerkCore
import HexwerkScript

struct Script: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: L("Apply a JavaScript script to a file."),
        discussion: L("Without --write, changes are only counted, not saved. Exit 2 on script error, 3 on timeout.")
            + "\n\n" + L("API (global object hw):") + "\n" + ScriptRunner.apiHelp
    )

    @Argument(help: .init(L("Script file (.js); with -e, code instead"))) var script: String
    @Argument(help: .init(L("File"))) var file: String
    @Flag(name: .short, help: .init(L("First argument is code instead of a file name"))) var eval = false
    @Flag(help: .init(L("Write changes to the file"))) var write = false
    @Option(help: .init(L("Timeout in seconds"))) var timeout: Double = ScriptRunner.defaultTimeout

    func run() throws {
        let source: String
        if eval { source = script } else {
            do { source = try String(contentsOfFile: script, encoding: .utf8) }
            catch {
                FileHandle.standardError.write(Data("hexwerk: \(script): \(error.localizedDescription)\n".utf8))
                throw ExitCode(1)
            }
        }
        let doc: Document
        do { doc = try Document(url: URL(fileURLWithPath: file)) }
        catch {
            FileHandle.standardError.write(Data("hexwerk: \(error)\n".utf8))
            throw ExitCode(1)
        }
        let r = ScriptRunner.run(source, name: eval ? "-e" : (script as NSString).lastPathComponent, document: doc,
                                 context: ScriptContext(fileName: (file as NSString).lastPathComponent),
                                 timeout: timeout)
        for line in r.output { print(line) }
        if let e = r.error {
            FileHandle.standardError.write(Data("hexwerk: \(e)\n".utf8))
            throw ExitCode(e.isTimeout ? 3 : 2)
        }
        guard doc.isModified else { return }
        if write {
            do { try doc.save() } catch {
                FileHandle.standardError.write(Data("hexwerk: \(error)\n".utf8))
                throw ExitCode(1)
            }
        } else {
            FileHandle.standardError.write(Data(("hexwerk: " + L("%ld change(s) not saved (--write)", r.edits) + "\n").utf8))
        }
    }
}
