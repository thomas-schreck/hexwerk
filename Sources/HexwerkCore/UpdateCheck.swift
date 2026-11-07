import Foundation

/// A semantic version (semver.org 2.0) for comparing releases, e.g.
/// `0.1.0`, `1.2.3-beta.1`, `v2.0.0+build.5`. A leading `v` is accepted,
/// build metadata after `+` is ignored for ordering.
public struct SemanticVersion: Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Dot-separated pre-release identifiers; empty for a release.
    public let prerelease: [String]

    public init?(_ text: String) {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        if let plus = s.firstIndex(of: "+") { s = s[..<plus] }
        var pre: [String] = []
        if let dash = s.firstIndex(of: "-") {
            pre = s[s.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !pre.isEmpty, pre.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } })
            else { return nil }
            s = s[..<dash]
        }
        let core = s.split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3, core.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) }),
            let a = Int(core[0]), let b = Int(core[1]), let c = Int(core[2]), a >= 0, b >= 0, c >= 0
        else { return nil }
        (major, minor, patch, prerelease) = (a, b, c, pre)
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public static func < (l: Self, r: Self) -> Bool {
        if (l.major, l.minor, l.patch) != (r.major, r.minor, r.patch) {
            return (l.major, l.minor, l.patch) < (r.major, r.minor, r.patch)
        }
        // A pre-release sorts before the release of the same version.
        switch (l.prerelease.isEmpty, r.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (a, b) in zip(l.prerelease, r.prerelease) where a != b {
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y
            case (_?, nil): return true  // numeric identifiers sort first
            case (nil, _?): return false
            case (nil, nil): return a < b
            }
        }
        return l.prerelease.count < r.prerelease.count
    }

    public static func == (l: Self, r: Self) -> Bool { !(l < r) && !(r < l) }
}

/// Decisions for the app's update check (#119). The network request itself
/// lives in the app; everything that can be decided without it is here.
public enum UpdateCheck {
    public static let repository = "thomas-schreck/hexwerk"
    /// Latest published release; GitHub leaves out drafts and pre-releases.
    public static let latestReleaseAPI = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    /// Release pages the hint may link to; anything else falls back to the tag page.
    static let releasePagePrefix = "https://github.com/\(repository)/releases/"
    /// Automatic checks run at most once per interval.
    public static let interval: TimeInterval = 24 * 60 * 60

    /// A newer release than the running one.
    public struct Release: Equatable, Sendable {
        public let version: SemanticVersion
        public let page: URL
    }

    /// The running version when it can be compared, nil for `dev` and
    /// other unversioned builds (no checks at all for those).
    public static func comparableVersion(_ running: String) -> SemanticVersion? {
        running == "dev" ? nil : SemanticVersion(running)
    }

    /// Whether the automatic check should run now: enabled, a real version,
    /// and the last check at least `interval` ago. A last check in the future
    /// (clock set back) counts as due so a wrong clock cannot stop checks.
    public static func shouldCheck(running: String, enabled: Bool, lastCheck: Date?, now: Date = Date()) -> Bool {
        guard enabled, comparableVersion(running) != nil else { return false }
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed < 0 || elapsed >= interval
    }

    /// Whether `tag` (e.g. `v0.2.0`) names a newer version than `running`.
    public static func isNewer(tag: String, than running: String) -> Bool {
        guard let current = comparableVersion(running), let latest = SemanticVersion(tag) else { return false }
        return current < latest
    }

    /// The release page for a tag, or `htmlURL` when it is one of this repository's release pages.
    public static func page(tag: String, htmlURL: String?) -> URL {
        if let htmlURL, htmlURL.hasPrefix(releasePagePrefix), let url = URL(string: htmlURL) { return url }
        let encoded = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? ""
        return URL(string: releasePagePrefix + "tag/" + encoded)!
    }

    public enum Failure: Error, Equatable {
        case unreadableResponse
    }

    /// Reads the GitHub API answer: the newer release, or nil when the
    /// running version is current (or newer, e.g. a local build).
    public static func newerRelease(in json: Data, running: String) throws(Failure) -> Release? {
        struct Answer: Decodable {
            let tag_name: String
            let html_url: String?
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: json), let latest = SemanticVersion(answer.tag_name)
        else { throw .unreadableResponse }
        guard isNewer(tag: answer.tag_name, than: running) else { return nil }
        return Release(version: latest, page: page(tag: answer.tag_name, htmlURL: answer.html_url))
    }

    /// A release found by an earlier check, if it is still newer than the
    /// running version (it is not after updating).
    public static func pendingRelease(tag: String?, page: String?, running: String) -> Release? {
        guard let tag, let version = SemanticVersion(tag), isNewer(tag: tag, than: running) else { return nil }
        return Release(version: version, page: Self.page(tag: tag, htmlURL: page))
    }
}
