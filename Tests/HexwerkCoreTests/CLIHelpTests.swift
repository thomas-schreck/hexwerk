import Foundation
import Testing

/// Issue #42: option defaults appear as values, not as Swift structs.
extension CLITests {
    @Test func helpShowsNumberDefaultsAsValues() throws {
        let (s, top) = try run(["--help"])
        #expect(s == 0)
        let subcommands = [
            "dump", "inspect", "find", "diff", "hash", "parse", "yara", "entropy", "export",
            "script", "type", "strings", "convert", "open",
        ]
        #expect(subcommands.allSatisfy { top.contains($0) })
        for sub in subcommands {
            let (status, out) = try run([sub, "--help"])
            #expect(status == 0, "\(sub)")
            #expect(!out.contains("Number(value"), "\(sub)")
        }
        #expect(try run(["dump", "--help"]).1.contains("(default: 0)"))
    }
}
