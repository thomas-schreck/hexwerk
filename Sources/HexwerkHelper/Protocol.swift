import Foundation
import HexwerkCore
import HexwerkYARA

/// The sandboxed helper (#102): Kaitai parsing (with .ksy loading), YARA-X
/// scans and JavaScript run in an XPC service inside the app bundle, so a
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
    /// Stops the request with this id (parse and script; a YARA-X scan cannot
    /// be interrupted and ends at its timeout).
    func cancel(_ requestID: String)
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
    var maxMatchesPerPattern: Int
}

struct ScriptRequest: Codable, Sendable {
    var header: RequestHeader
    var source: String
    var name: String
    var cursor: UInt64
    var selection: Range<UInt64>?
    var fileName: String
    var readOnly: Bool
    var timeout: Double
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
