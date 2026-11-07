import Testing

@testable import HexwerkCore

struct BuildInfoTests {
    @Test func fullInfoPlist() {
        let info = BuildInfo(infoDictionary: [
            "CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "12", "HexwerkCommit": "f0ff933",
        ])
        #expect(info == BuildInfo(version: "0.2.0", build: "12", commit: "f0ff933"))
        #expect(info.summary == "0.2.0 (\(L("build %@", "12")), f0ff933)")
    }

    /// `swift build` without the Makefile has no Info.plist at all.
    @Test func missingInfoPlistIsDev() {
        let info = BuildInfo(infoDictionary: nil)
        #expect(info.summary == "dev")
        #expect(info.details == nil)
    }

    /// An empty commit (no git checkout, e.g. a source tarball) is left out.
    @Test func emptyCommitIsOmitted() {
        let info = BuildInfo(infoDictionary: ["CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "3", "HexwerkCommit": ""])
        #expect(info.commit == nil)
        #expect(info.summary == "0.2.0 (\(L("build %@", "3")))")
    }
}
