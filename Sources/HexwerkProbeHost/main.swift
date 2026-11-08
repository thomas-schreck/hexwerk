import Foundation
import HexwerkCore
import HexwerkHelper
import HexwerkScript
import HexwerkYARA

// Test-only host of the probe service (#134), assembled by
// `make sandbox-probes` as hexwerk-probes.app with
// Contents/XPCServices/de.schreck-thomas.hexwerk.Parser.probes.xpc. An XPC
// service in a bundle can only be reached from that bundle's executable, so
// XPCSandboxTests run this host instead of connecting themselves.
//
// Every argument is one command; the answer is printed as one line each:
//   <probe>                    a `Probe` inside the service (e.g. open:/etc/hosts)
//   @type:<file>:<magic.mgc>   libmagic's description
//   @parse:<file>:<ksy>        names of the top-level fields, or the load error
//   @scan:<file>:<rules.yar>   matching rule names
//   @script:<file>:<script.js> the script's output
let service = "de.schreck-thomas.hexwerk.Parser.probes"

func connection() -> NSXPCConnection {
    let c = NSXPCConnection(serviceName: service)
    c.remoteObjectInterface = NSXPCInterface(with: HelperProbeXPC.self)
    c.resume()
    return c
}

func probe(_ spec: String) -> String {
    let c = connection()
    defer { c.invalidate() }
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var answer = "no answer"
    let proxy =
        c.remoteObjectProxyWithErrorHandler { e in
            answer = "xpc error \((e as NSError).code)"
            done.signal()
        } as? HelperProbeXPC
    proxy?.probe(spec.replacingOccurrences(of: "%HOST%", with: String(getpid()))) { r in
        answer = r
        done.signal()
    }
    if done.wait(timeout: .now() + 30) == .timedOut { return "timed out" }
    return answer
}

func work(_ command: String) async -> String {
    let parts = command.dropFirst().split(separator: ":", maxSplits: 2).map(String.init)
    guard parts.count == 3 else { return "bad command" }
    let client = HelperClient { NSXPCConnection(serviceName: service) }
    let file = URL(fileURLWithPath: parts[1]), arg = URL(fileURLWithPath: parts[2])
    do {
        let snap = try Document(url: file, readOnly: true).snapshot()
        switch parts[0] {
        case "type":
            return try await client.detectType(snap, database: arg).description ?? "nil"
        case "parse":
            switch try await client.parse(snap, ksy: arg, libraryRoots: []) {
            case .success(let r): return "fields \(r.root.children.map(\.name).joined(separator: ","))"
            case .failure(let e): return "load error \(e)"
            }
        case "scan":
            let rules = try YaraRuleBundle.collect(files: [arg])
            switch try await client.scan(snap, rules: rules, range: nil, timeout: 10, maxMatchesPerPattern: 100) {
            case .hits(let hits, _): return "rules " + hits.map(\.rule).sorted().joined(separator: ",")
            case .compileErrors(let d): return "compile errors \(d)"
            case .failed(let m, _), .timedOut(let m, _): return "failed \(m)"
            }
        case "script":
            let source = try String(contentsOf: arg, encoding: .utf8)
            let (outcome, _) = try await client.runScript(
                source, name: arg.lastPathComponent, base: snap,
                context: ScriptContext(cursor: 0, selection: nil, fileName: file.lastPathComponent),
                readOnly: true, timeout: 10)
            return outcome.result.error.map { "error \($0)" } ?? outcome.result.output.joined(separator: "|")
        default: return "bad command"
        }
    } catch {
        return "failed \(error)"
    }
}

for command in CommandLine.arguments.dropFirst() {
    print(command.hasPrefix("@") ? await work(command) : probe(command))
}
