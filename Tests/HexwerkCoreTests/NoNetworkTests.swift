import Foundation
import Testing

/// hexwerk makes no network connections (issue #38), except the app's
/// update check (#119), which may use URLSession from one file only.
///
/// Checked statically on the build output with `nm`/`otool`, so the test
/// needs `swift build` first (like the CLI tests):
/// 1. The CLI, app and helper (#102) binaries link no networking framework and import no
///    high-level networking API (URLSession, NSURLConnection, Network.framework,
///    CFNetwork streams/sockets, WebKit).
/// 2. The object files compiled from this package and its Swift dependencies
///    import no BSD socket or DNS function at all.
///
/// Why not (2) on the binaries: the statically linked YARA-X library
/// (`libyara_x_capi.a`) carries Rust's `std` as one object, which includes
/// `std::net` (TcpStream, UdpSocket, lookup_host), so the binaries import
/// `socket`/`connect`/`getaddrinfo` from libSystem even though nothing in
/// hexwerk calls them (`ld -why_live _socket` traces them to `std::net` only).
/// `make formats` (git clone of the Kaitai collection) is a build step and
/// not part of the binaries.
@Suite struct NoNetworkTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let build = root.appendingPathComponent(".build")

    static let forbiddenLibraries = ["Network.framework", "CFNetwork.framework", "WebKit.framework", "libcurl"]
    /// Substrings of imported symbol names (Swift-mangled names contain the type name).
    static let forbiddenAPIs = [
        "URLSession", "NSURLConnection", "NSURLDownload", "URLRequest", "_nw_",
        "CFSocket", "CFStreamCreatePairWithSocket", "CFHost", "getStreamsToHost",
        "WKWebView",
    ]
    /// BSD sockets and name resolution, exact symbol names.
    static let forbiddenCalls: Set<String> = [
        "_socket", "_connect", "_bind", "_listen", "_accept", "_sendto", "_sendmsg", "_recvfrom", "_recvmsg",
        "_getaddrinfo", "_gethostbyname", "_gethostbyname2", "_getnameinfo", "_res_query", "_res_9_query",
        "_DNSServiceQueryRecord", "_DNSServiceGetAddrInfo",
    ]

    func tool(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func undefinedSymbols(_ files: [String]) throws -> [String] {
        // nm prints "file:" headers for several files; -j gives bare names.
        var out: [String] = []
        for batch in stride(from: 0, to: files.count, by: 100) {
            out += try tool("/usr/bin/nm", ["-u", "-j"] + files[batch ..< min(files.count, batch + 100)])
                .split(separator: "\n").map(String.init)
        }
        return out
    }

    /// The app may use URLSession for the update check (#119); the CLI and
    /// the parser helper may not.
    static let appUpdateCheckAPIs = ["URLSession", "URLRequest"]
    static let updateCheckSource = "Sources/HexwerkApp/UpdateChecker.swift"

    @Test func binariesUseNoNetworkingAPIs() throws {
        let binaries = ["hexwerk", "HexwerkApp", "HexwerkParser"].map { Self.build.appendingPathComponent("debug/\($0)").path }
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
        try #require(binaries.contains { $0.hasSuffix("/hexwerk") }, "swift build missing")
        for bin in binaries {
            let libs = try tool("/usr/bin/otool", ["-L", bin])
            // URLSession lives in CFNetwork; the macOS 26 SDK links it into the app.
            let allowedLibraries = bin.hasSuffix("/HexwerkApp") ? ["CFNetwork.framework"] : []
            for l in Self.forbiddenLibraries where !allowedLibraries.contains(l) {
                // "/Network.framework", or it would match inside "CFNetwork.framework".
                #expect(!libs.contains("/" + l), "\(bin) links \(l)")
            }
            let symbols = try undefinedSymbols([bin])
            #expect(symbols.count > 100, "nm returned too little for \(bin)")
            for s in symbols {
                let allowed = bin.hasSuffix("/HexwerkApp") ? Self.appUpdateCheckAPIs : []
                for api in Self.forbiddenAPIs where s.contains(api) && !allowed.contains(api) {
                    Issue.record("\(bin) imports \(s)")
                }
            }
        }
    }

    /// Only the update checker uses URLSession, so the exception above
    /// cannot spread unnoticed.
    @Test func onlyUpdateCheckerUsesURLSession() throws {
        let sources = Self.root.appendingPathComponent("Sources")
        let e = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var users: [String] = []
        while let u = e?.nextObject() as? URL {
            guard u.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: u, encoding: .utf8)
            if text.contains("URLSession") || text.contains("URLRequest") {
                users.append(String(u.path.dropFirst(Self.root.path.count + 1)))
            }
        }
        #expect(users == [Self.updateCheckSource])
    }

    @Test func ownCodeCallsNoSocketFunctions() throws {
        var objects: [String] = []
        let e = FileManager.default.enumerator(at: Self.build, includingPropertiesForKeys: nil)
        while let u = e?.nextObject() as? URL {
            let p = u.path
            if p.contains("/checkouts/") || p.contains("/repositories/") || p.contains("Tests") { continue }
            if u.pathExtension == "o" { objects.append(p) }
        }
        try #require(objects.count >= 10, "no object files under .build (swift build missing)")
        let hits = try undefinedSymbols(objects).filter { Self.forbiddenCalls.contains($0) }
        #expect(hits.isEmpty, "socket/DNS imports in hexwerk objects: \(Set(hits).sorted())")
    }
}
