import ArgumentParser
import Foundation

/// Hands files to the app (SPEC FR-8.8), like `open -a`, but by bundle id so
/// it works wherever hexwerk.app is installed.
struct OpenCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Dateien in der hexwerk-App öffnen (je Datei ein Tab)."
    )

    static let bundleID = "de.schreck-thomas.hexwerk"

    @Argument(help: "Eine oder mehrere Dateien.")
    var files: [String]

    func run() throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var paths: [String] = []
        for f in files {
            let url = URL(fileURLWithPath: f, relativeTo: cwd).standardizedFileURL
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                throw ValidationError("\(f): Datei nicht gefunden.")
            }
            guard !isDir.boolValue else { throw ValidationError("\(f) ist ein Ordner.") }
            paths.append(url.path)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-b", Self.bundleID] + paths
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ValidationError("hexwerk.app nicht gefunden oder nicht startbar (make install-app).\n" + msg)
        }
    }
}
