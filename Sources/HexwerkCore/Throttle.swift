import Foundation

/// Lets through at most one progress report per interval, so a scan that
/// reports every chunk does not flood the main thread with UI updates.
public struct ProgressThrottle: Sendable {
    public let interval: Duration
    private var last: ContinuousClock.Instant?

    public init(interval: Duration = .milliseconds(100)) { self.interval = interval }

    /// True if a report at `now` should reach the UI.
    public mutating func shouldReport(now: ContinuousClock.Instant = .now) -> Bool {
        if let last, now - last < interval { return false }
        last = now
        return true
    }
}

/// Runs the latest scheduled action once things have been quiet for
/// `delay` (e.g. writing settings while the user types). Thread-safe;
/// actions run on a private serial queue.
public final class Debouncer: @unchecked Sendable {
    private let delay: DispatchTimeInterval
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: (@Sendable () -> Void)?
    private var generation = 0

    public init(delay: DispatchTimeInterval, label: String = "hexwerk.debouncer") {
        self.delay = delay
        queue = DispatchQueue(label: label)
    }

    /// Replaces any pending action with `action`, run after the delay.
    public func schedule(_ action: @escaping @Sendable () -> Void) {
        let gen: Int = lock.withLock {
            pending = action
            generation += 1
            return generation
        }
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            // Only the latest scheduling runs, and only if not flushed meanwhile.
            let action: (@Sendable () -> Void)? = lock.withLock {
                guard gen == generation else { return nil }
                defer { pending = nil }
                return pending
            }
            action?()
        }
    }

    /// Runs a pending action now and waits for it (before quitting).
    public func flush() {
        let action: (@Sendable () -> Void)? = lock.withLock {
            defer { pending = nil }
            return pending
        }
        guard let action else { return }
        queue.sync { action() }
    }
}
