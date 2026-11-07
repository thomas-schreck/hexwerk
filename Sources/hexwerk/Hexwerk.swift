import ArgumentParser
import Foundation
import HexwerkCore
import HexwerkHelper

@main
struct Hexwerk: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: L("Hex tool: view, examine and parse files."),
        version: "hexwerk \(BuildInfo.current.summary)",
        subcommands: [
            Dump.self, Inspect.self, Find.self, Diff.self, Hash.self, Parse.self, Yara.self, Entropy.self, Export.self, Script.self,
            FileType.self, StringsCmd.self, Convert.self, OpenCmd.self,
        ]
    )

    /// The sandboxed child process (#129) is this executable started with a
    /// marker argument; it is not a subcommand, so it stays out of help,
    /// completions and the man page.
    static func main() {
        let args = CommandLine.arguments
        if args.count > 1, args[1] == SandboxedChild.argument {
            SandboxedChild.serve(arguments: Array(args.dropFirst(2)))
        }
        main(nil)
    }
}

/// Offsets and lengths accept decimal or 0x-prefixed hex.
struct Number: ExpressibleByArgument {
    let value: UInt64
    init?(argument: String) {
        let s = argument.lowercased().replacingOccurrences(of: "_", with: "")
        if s.hasPrefix("0x") {
            guard let v = UInt64(s.dropFirst(2), radix: 16) else { return nil }
            value = v
        } else {
            guard let v = UInt64(s) else { return nil }
            value = v
        }
    }

    /// Shown as "(default: …)" in --help; otherwise argument-parser prints
    /// the struct ("Number(value: 0)").
    var defaultValueDescription: String {
        value < 10 ? String(value) : "0x" + String(value, radix: 16, uppercase: true)
    }
}

func openSource(_ path: String) throws -> ByteSource {
    do { return try ByteSource(url: URL(fileURLWithPath: path)) } catch {
        FileHandle.standardError.write(Data("hexwerk: \(error)\n".utf8))
        throw ExitCode(1)
    }
}

/// `failure`: exit status when the file cannot be opened.
func openSnapshot(_ path: String, failure: Int32 = 1) throws -> Snapshot {
    do { return try Document(url: URL(fileURLWithPath: path), readOnly: true).snapshot() } catch {
        FileHandle.standardError.write(Data("hexwerk: \(error)\n".utf8))
        throw ExitCode(failure)
    }
}

/// Runs untrusted-input work in the sandboxed child process (#129). The
/// child crashing ends the command with a message and status 1, a child
/// killed at its time limit with `timeoutStatus`.
func sandboxed<T>(timeoutStatus: Int32 = 1, _ work: (SandboxedChild) throws -> T) throws -> T {
    do { return try work(SandboxedChild()) } catch {
        FileHandle.standardError.write(Data("hexwerk: \(error)\n".utf8))
        if case SandboxedChildError.timedOut = error { throw ExitCode(timeoutStatus) }
        throw ExitCode(1)
    }
}

func printJSON(_ obj: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    print(TerminalText.escapeJSON(String(decoding: data, as: UTF8.self)))
}

struct Dump: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: L("Output a range as a hex dump (format like hexdump -C)."))

    @Argument(help: .init(L("File"))) var file: String
    @Option(help: .init(L("Start offset (decimal or 0x...)"))) var offset: Number = Number(argument: "0")!
    @Option(help: .init(L("Number of bytes (default: to end of file)"))) var length: Number?
    @Option(help: .init(L("Bytes per line"))) var width: Int = 16

    func validate() throws {
        guard (1 ... 256).contains(width) else { throw ValidationError(L("--width must be between 1 and 256")) }
    }

    func run() throws {
        let src = try openSource(file)
        let start = offset.value
        guard start <= src.count else {
            FileHandle.standardError.write(
                Data(("hexwerk: " + L("Offset %llu is past the end of the file (%llu)", start, src.count) + "\n").utf8))
            throw ExitCode(1)
        }
        // Clamp the length before adding: start + length can exceed UInt64.max.
        let end = length.map { start + min($0.value, src.count - start) } ?? src.count
        // Stream in blocks so large ranges never sit in memory at once.
        let block = UInt64(width * 4096)
        var pos = start
        repeat {
            let chunk = src.read(pos ..< min(pos + block, end))
            var lines = HexDump.lines(chunk, startOffset: pos, width: width)
            let isLast = pos + UInt64(chunk.count) >= end
            if !isLast { lines.removeLast() }  // trailing offset only once, at the end
            print(lines.joined(separator: "\n"))
            pos += UInt64(chunk.count)
        } while pos < end
    }
}

struct Inspect: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: L("Interpret the bytes at an offset as data types."))

    @Argument(help: .init(L("File"))) var file: String
    @Argument(help: .init(L("Offset (decimal or 0x...)"))) var offset: Number
    @Option(help: .init(L("Byte order: little or big"))) var endian: EndianArg = .little
    @Flag(help: .init(L("Output as JSON"))) var json = false

    func run() throws {
        let src = try openSource(file)
        guard offset.value < src.count else {
            FileHandle.standardError.write(
                Data(("hexwerk: " + L("Offset %llu is past the end of the file (%llu)", offset.value, src.count) + "\n").utf8))
            throw ExitCode(1)
        }
        let values = Inspector.values(
            src.read(offset.value ..< offset.value + UInt64(Inspector.window)),
            endian: endian.value)
        if json {
            try printJSON(values.reduce(into: [String: String]()) { $0[$1.name] = $1.value })
        } else {
            let w = values.map(\.title.count).max() ?? 0
            for v in values {
                print(v.title.padding(toLength: w, withPad: " ", startingAt: 0) + "  " + (v.value ?? "—"))
            }
        }
    }
}

enum EndianArg: String, ExpressibleByArgument {
    case little, big
    var value: Endian { self == .little ? .little : .big }
}
