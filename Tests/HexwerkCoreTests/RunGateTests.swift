import Testing
@testable import HexwerkCore

@Suite struct RunGateTests {
    @Test func resultOfUneditedRunIsCurrent() {
        var g = RunGate()
        let t = g.begin()
        #expect(g.isRunning)
        #expect(g.finish(t) == .current)
        #expect(!g.isRunning)
    }

    /// An edit while the job runs: the result describes the old content.
    @Test func editDuringRunMakesResultStale() {
        var g = RunGate()
        let t = g.begin()
        g.contentChanged()
        #expect(g.verdict(for: t) == .stale)
        #expect(g.finish(t) == .stale)
        #expect(!g.isRunning)
    }

    /// Edits before the run started do not matter.
    @Test func editBeforeRunDoesNotCount() {
        var g = RunGate()
        g.contentChanged()
        g.contentChanged()
        let t = g.begin()
        #expect(g.finish(t) == .current)
    }

    /// Two runs in parallel: only the newer one may deliver, and the late
    /// arrival of the older one does not end the newer run.
    @Test func newerRunSupersedesOlder() {
        var g = RunGate()
        let old = g.begin()
        let new = g.begin()
        #expect(g.finish(old) == .superseded)
        #expect(g.isRunning)
        #expect(g.finish(new) == .current)
        #expect(!g.isRunning)
    }

    @Test func cancelledRunIsSuperseded() {
        var g = RunGate()
        let t = g.begin()
        g.cancel()
        #expect(!g.isRunning)
        #expect(g.finish(t) == .superseded)
        #expect(!g.isRunning)
    }

    /// A finished ticket cannot deliver twice.
    @Test func ticketDeliversOnce() {
        var g = RunGate()
        let t = g.begin()
        #expect(g.finish(t) == .current)
        #expect(g.finish(t) == .superseded)
    }
}
