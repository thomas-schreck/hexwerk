import ArgumentParser
import Foundation
import HexwerkCore

/// Hands files to the app, like `open -a`, but by bundle id so
/// it works wherever hexwerk.app is installed.
struct OpenCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: L("Open files in the hexwerk app (one tab per file).")
    )

    static let bundleID = "de.schreck-thomas.hexwerk"

    @Argument(help: .init(L("One or more files.")))
    var files: [String]

    func run() throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var paths: [String] = []
        for f in files {
            let url = URL(fileURLWithPath: f, relativeTo: cwd).standardizedFileURL
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                throw ValidationError(L("%@: file not found.", f))
            }
            guard !isDir.boolValue else { throw ValidationError(L("%@ is a folder.", f)) }
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
            throw ValidationError(L("hexwerk.app not found or cannot be launched (make install-app).") + "\n" + msg)
        }
    }
}
