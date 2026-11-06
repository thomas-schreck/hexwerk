import ArgumentParser
import Foundation
import HexwerkCore
import HexwerkScript

struct Script: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "JavaScript-Skript auf eine Datei anwenden.",
        discussion: """
        Ohne --write werden Änderungen nur gezählt, nicht gespeichert. Exit 2 bei Skriptfehler, 3 bei Zeitlimit.

        API (globales Objekt hw):
        \(ScriptRunner.apiHelp)
        """
    )

    @Argument(help: "Skriptdatei (.js); mit -e stattdessen Code") var script: String
    @Argument(help: "Datei") var file: String
    @Flag(name: .short, help: "Erstes Argument ist Code statt Dateiname") var eval = false
    @Flag(help: "Änderungen in die Datei schreiben") var write = false
    @Option(help: "Zeitlimit in Sekunden") var timeout: Double = ScriptRunner.defaultTimeout

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
            FileHandle.standardError.write(Data("hexwerk: \(r.edits) Änderung(en) nicht gespeichert (--write)\n".utf8))
        }
    }
}
