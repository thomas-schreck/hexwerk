import Foundation
import Testing

@testable import HexwerkCore

/// Version comparison and decisions of the app's update check (#119).
struct UpdateCheckTests {
    func v(_ s: String) -> SemanticVersion { SemanticVersion(s)! }

    @Test func parsesTagsAndRejectsGarbage() {
        #expect(v("v1.2.3").description == "1.2.3")
        #expect(v("0.1.0-beta.1+build.7").description == "0.1.0-beta.1")
        for bad in ["dev", "", "1.2", "1.2.3.4", "v", "1.x.3", "1.2.3-", "1.2.3-a..b", "-1.2.3"] {
            #expect(SemanticVersion(bad) == nil, "\(bad)")
        }
    }

    /// Precedence example from semver.org 2.0, item 11.
    @Test func ordersLikeSemver() {
        let ordered = [
            "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11",
            "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "1.10.0", "2.0.0",
        ].map(v)
        for (a, b) in zip(ordered, ordered.dropFirst()) { #expect(a < b, "\(a) < \(b)") }
        #expect(v("0.1.0-beta.1") < v("0.1.0"))
        #expect(v("1.0.0+a") == v("1.0.0+b"))
    }

    @Test func isNewer() {
        #expect(UpdateCheck.isNewer(tag: "v0.2.0", than: "0.1.0"))
        #expect(UpdateCheck.isNewer(tag: "v0.1.0", than: "0.1.0-beta.1"))
        #expect(!UpdateCheck.isNewer(tag: "v0.1.0", than: "0.1.0"))
        #expect(!UpdateCheck.isNewer(tag: "v0.1.0", than: "0.2.0"))
        #expect(!UpdateCheck.isNewer(tag: "v9.0.0", than: "dev"))
        #expect(!UpdateCheck.isNewer(tag: "nightly", than: "0.1.0"))
    }

    @Test func checksAtMostOncePerDay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func due(_ running: String = "0.1.0", enabled: Bool = true, ago: TimeInterval?) -> Bool {
            UpdateCheck.shouldCheck(running: running, enabled: enabled, lastCheck: ago.map { now.addingTimeInterval(-$0) }, now: now)
        }
        #expect(due(ago: nil))
        #expect(!due(ago: 60))
        #expect(!due(ago: UpdateCheck.interval - 1))
        #expect(due(ago: UpdateCheck.interval))
        #expect(due(ago: -3600), "last check in the future (clock set back)")
        #expect(!due(enabled: false, ago: nil))
        #expect(!due("dev", ago: nil))
    }

    @Test func readsGitHubAnswer() throws {
        let json = Data(
            #"{"tag_name":"v0.3.0","html_url":"https://github.com/thomas-schreck/hexwerk/releases/tag/v0.3.0","body":"x"}"#.utf8)
        let r = try UpdateCheck.newerRelease(in: json, running: "0.2.0")
        #expect(r?.version == v("0.3.0"))
        #expect(r?.page.absoluteString == "https://github.com/thomas-schreck/hexwerk/releases/tag/v0.3.0")
        #expect(try UpdateCheck.newerRelease(in: json, running: "0.3.0") == nil)
        #expect(try UpdateCheck.newerRelease(in: json, running: "0.4.0") == nil)
        #expect(throws: UpdateCheck.Failure.unreadableResponse) {
            try UpdateCheck.newerRelease(in: Data(#"{"message":"Not Found"}"#.utf8), running: "0.2.0")
        }
    }

    /// The hint only links to this repository's release pages.
    @Test func foreignLinkFallsBackToTagPage() throws {
        let json = Data(#"{"tag_name":"v0.3.0","html_url":"https://evil.example/x"}"#.utf8)
        let r = try UpdateCheck.newerRelease(in: json, running: "0.2.0")
        #expect(r?.page.absoluteString == "https://github.com/thomas-schreck/hexwerk/releases/tag/v0.3.0")
    }

    @Test func pendingReleaseDisappearsAfterUpdating() {
        #expect(UpdateCheck.pendingRelease(tag: "v0.3.0", page: nil, running: "0.2.0")?.version == v("0.3.0"))
        #expect(UpdateCheck.pendingRelease(tag: "v0.3.0", page: nil, running: "0.3.0") == nil)
        #expect(UpdateCheck.pendingRelease(tag: nil, page: nil, running: "0.2.0") == nil)
    }
}
