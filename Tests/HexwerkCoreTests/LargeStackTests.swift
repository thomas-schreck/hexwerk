import Foundation
import Testing
import HexwerkCore

@Suite struct LargeStackTests {
    /// Waiting for large-stack work must not occupy cooperative pool threads
    /// (#28): with more waiters than pool threads, work that needs the pool
    /// to make progress would otherwise starve.
    @Test func asyncVariantDoesNotBlockThePool() async {
        let n = ProcessInfo.processInfo.activeProcessorCount * 2
        let gate = DispatchSemaphore(value: 0)
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< n {
                group.addTask { await onLargeStackAsync { gate.wait(timeout: .now() + 5) == .success } }
            }
            // Runs on the pool: only possible if the waiters above suspended.
            group.addTask {
                for _ in 0 ..< n { gate.signal() }
                return true
            }
            return await group.reduce(into: [Bool]()) { $0.append($1) }
        }
        #expect(results.count == n + 1 && results.allSatisfy { $0 })
    }

    @Test func asyncVariantHasLargeStack() async {
        // 8 MiB on the stack would overflow a 512 KiB task thread.
        let sum = await onLargeStackAsync {
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 8 << 20) { buf in
                buf.initialize(repeating: 1)
                return buf.reduce(0) { $0 + Int($1) }
            }
        }
        #expect(sum == 8 << 20)
    }
}
