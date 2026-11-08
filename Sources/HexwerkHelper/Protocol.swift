import Foundation
import HexwerkCore
import HexwerkYARA

/// The sandboxed helper (#102): Kaitai parsing (with .ksy loading), YARA-X
/// scans, JavaScript and libmagic (#129) run in an XPC service inside the app bundle, so a
/// hostile file that hits a bug takes down the helper, not the app with its
/// unsaved edits. The service has no network and no file access; it reads
/// the document through a descriptor the app passes along with each request
/// and asks the app for .ksy files (`HelperHostXPC`).
///
/// Requests are Codable (property list); replies use the compact binary
/// forms (`ParseOutcome`, `YaraScanOutcome`, `ScriptOutcome`), which the app
/// decodes defensively. `reply`'s String is a failure of the request itself.
@objc public protocol HelperXPC {
    func parse(_ request: Data, file: FileHandle?, reply: @escaping @Sendable (Data?, String?) -> Void)
    func scan(_ request: Data, file: FileHandle?, reply: @escaping @Sendable (Data?, String?) -> Void)
    func runScript(_ request: Data, file: FileHandle?, reply: @escaping @Sendable (Data?, String?) -> Void)
    /// libmagic on the start of the document (#129); `database` is magic.mgc,
    /// opened by the app.
    func detectType(_ request: Data, database: FileHandle?, reply: @escaping @Sendable (Data?, String?) -> Void)
    /// Stops the request with this id (parse and script; a YARA-X scan cannot
    /// be interrupted and ends at its timeout).
    func cancel(_ requestID: String)
}

/// Test-only extension of `HelperXPC` (#134): runs one of the sandbox
/// probes (`Probe`) inside the service. Exported only by the service that
/// `make sandbox-probes` builds, never by the one in hexwerk.app.
@objc public protocol HelperProbeXPC: HelperXPC {
    func probe(_ probe: String, reply: @escaping @Sendable (String) -> Void)
}

/// Exported by the app on the same connection.
@objc public protocol HelperHostXPC {
    /// Text of a .ksy file: (text, nil); missing: (nil, nil); unreadable: (nil, reason).
    func readFormatFile(_ path: String, reply: @escaping @Sendable (String?, String?) -> Void)
}

public enum HelperService {
    /// Bundle identifier and name of `Contents/XPCServices/<name>.xpc`.
    public static let name = "de.schreck-thomas.hexwerk.Parser"
}

/// What every request carries besides its own fields.
struct RequestHeader: Codable, Sendable {
    var id: String
    /// The app's language: messages made in the helper must match it.
    var language: String
    var snapshot: SnapshotWire
    /// The document's path, for names in messages only.
    var path: String
}

struct ParseRequest: Codable, Sendable {
    var header: RequestHeader
    var ksy: String
    var libraryRoots: [String]
}

struct ScanRequest: Codable, Sendable {
    var header: RequestHeader
    var rules: YaraRuleBundle
    var range: Range<UInt64>?
    var timeout: Int
    /// nil: YARA-X default (CLI).
    var maxMatchesPerPattern: Int?
}

struct ScriptRequest: Codable, Sendable {
    var header: RequestHeader
    var source: String
    var name: String
    var cursor: UInt64
    var selection: Range<UInt64>?
    var fileName: String
    var baseAddress: UInt64
    var readOnly: Bool
    var timeout: Double
}

/// libmagic works on the first MiB only (`Magic.sample`), so the request
/// carries those bytes instead of the document.
struct TypeRequest: Codable, Sendable {
    var language: String
    var sample: Data
}

/// libmagic's description and MIME type; nil without a usable database.
public struct TypeOutcome: Sendable, Equatable {
    public var description: String?
    public var mime: String?

    func encoded() -> Data {
        var w = WireWriter()
        w.optional(description) { $0.string($1) }
        w.optional(mime) { $0.string($1) }
        return w.data
    }

    public init(description: String?, mime: String?) {
        self.description = description
        self.mime = mime
    }

    init(encoded data: Data) throws {
        var r = WireReader(data)
        description = try r.optional { try $0.string() }
        mime = try r.optional { try $0.string() }
        try r.expectEnd()
    }
}

enum RequestCoder {
    static func encode<T: Encodable>(_ v: T) throws -> Data {
        let e = PropertyListEncoder()
        e.outputFormat = .binary
        return try e.encode(v)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try PropertyListDecoder().decode(type, from: data)
    }
}
