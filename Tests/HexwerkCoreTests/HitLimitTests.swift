import Foundation
import Testing
import UniformTypeIdentifiers
@testable import HexwerkCore

/// Issue #36: hit limits hold exactly and truncation is reported.
@Suite struct HitLimitTests {
    @Test func differencesStopExactlyAtTheLimit() throws {
        // Every other byte differs: 500 single-byte ranges, and B is longer.
        let a = Data(count: 1000)
        let b = Data((0 ..< 1010).map { $0 % 2 == 0 ? 0 : 1 })
        let (da, ua) = try doc(a), (db, ub) = try doc(b)
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub) }
        let r = Compare.differences(da.snapshot(), db.snapshot(), maxHits: 100)
        #expect(r.count == 100)
        #expect(r.last == 199 ..< 200)  // no bogus range to the end
        #expect(r.allSatisfy { $0.count == 1 })
        #expect(Compare.differences(da.snapshot(), db.snapshot()).count == 501)  // 500 + tail
    }

    @Test func embeddedScanStopsExactlyAtTheLimit() throws {
        let png = image(.png, width: 2, height: 2)
        let url = try tempFile(Data(repeating: 0, count: 16) + Data((0 ..< 50).flatMap { _ in png }))
        defer { try? FileManager.default.removeItem(at: url) }
        let s = try Document(url: url, readOnly: true).snapshot()
        #expect(FileSignatures.scanEmbedded(s, maxHits: 10).count == 10)
        #expect(FileSignatures.scanEmbedded(s).count >= 50)
    }

    func runCLI(_ args: [String]) throws -> (status: Int32, lines: Int, stderr: String) {
        try #require(FileManager.default.isExecutableFile(atPath: CLITests.exe.path))
        let p = Process()
        p.executableURL = CLITests.exe
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(["HEXWERK_LANG": "en"]) { $1 }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        // Read stderr in the background so a full pipe cannot block the child.
        nonisolated(unsafe) var errData = Data()
        let t = Thread { errData = err.fileHandleForReading.readDataToEndOfFile() }
        t.start()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        while !t.isFinished { usleep(1000) }
        return (p.terminationStatus, o.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }, String(decoding: errData, as: UTF8.self))
    }

    @Test func cliReportsTruncatedDiffAndRegex() throws {
        let n = 2 * Search.maxHits + 100
        let a = try tempFile(Data(count: n))
        let b = try tempFile(Data((0 ..< n).map { $0 % 2 == 0 ? 0 : 1 }))
        defer { for u in [a, b] { try? FileManager.default.removeItem(at: u) } }

        let d = try runCLI(["diff", "--positional", a.path, b.path])
        #expect(d.status == 1)
        #expect(d.lines == Search.maxHits)
        #expect(d.stderr.contains("stopped after"))

        let f = try runCLI(["find", "--mode", "regex", b.path, "\\x01"])
        #expect(f.status == 0)
        #expect(f.lines == Search.maxHits)
        #expect(f.stderr.contains("stopped after"))

        let ok = try runCLI(["diff", "--positional", a.path, a.path])
        #expect(ok.status == 0 && !ok.stderr.contains("stopped after"))
    }
}
