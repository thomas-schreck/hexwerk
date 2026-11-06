import Foundation
import Testing
@testable import HexwerkCore

/// #33: progress reports and settings writes are rate-limited.
@Suite struct ThrottleTests {
    @Test func progressThrottleLetsOneReportPerInterval() {
        var t = ProgressThrottle(interval: .milliseconds(100))
        let t0 = ContinuousClock.now
        let reports = [0, 10, 99, 100, 150].map { t.shouldReport(now: t0 + .milliseconds($0)) }
        #expect(reports == [true, false, false, true, false])
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        func add(_ v: Int) { lock.withLock { values.append(v) } }
        var all: [Int] { lock.withLock { values } }
    }

    @Test func debouncerRunsOnlyTheLastAction() async throws {
        let d = Debouncer(delay: .milliseconds(50))
        let c = Counter()
        for i in 0 ..< 100 { d.schedule { c.add(i) } }
        #expect(c.all.isEmpty)                       // nothing written synchronously
        try await Task.sleep(for: .milliseconds(300))
        #expect(c.all == [99])
    }

    @Test func flushRunsPendingActionOnce() async throws {
        let d = Debouncer(delay: .seconds(10))
        let c = Counter()
        d.schedule { c.add(1) }
        d.schedule { c.add(2) }
        d.flush()
        #expect(c.all == [2])
        d.flush()                                    // nothing pending
        #expect(c.all == [2])
    }
}
