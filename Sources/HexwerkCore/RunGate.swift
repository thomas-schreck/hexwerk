/// Bookkeeping for one kind of background job of a document window (search,
/// diff, checksums, parse, scan). Results arrive asynchronously, possibly
/// after the user edited the document or started another run; `finish`
/// tells whether a result still describes the current content.
///
/// The gate is plain state owned by the main actor; the background task only
/// carries its `Ticket`.
public struct RunGate: Sendable {
    /// Handed to a run when it starts; identifies it when its result arrives.
    public struct Ticket: Equatable, Sendable {
        let run: UInt64
        let revision: UInt64
    }

    public enum Verdict: Equatable, Sendable {
        /// Latest run and the content is unchanged: the result is valid.
        case current
        /// Latest run, but the content was edited since it started: offsets
        /// and values describe bytes that no longer exist.
        case stale
        /// A newer run started or the run was cancelled: drop the result.
        case superseded
    }

    /// Content revision; bumped by every edit.
    public private(set) var revision: UInt64 = 0
    private var lastRun: UInt64 = 0
    private var active: UInt64?

    public init() {}

    /// True between `begin` and the `finish` or `cancel` of the latest run.
    public var isRunning: Bool { active != nil }

    /// Starts a run; any earlier run is superseded.
    public mutating func begin() -> Ticket {
        lastRun &+= 1
        active = lastRun
        return Ticket(run: lastRun, revision: revision)
    }

    /// Records an edit of the document content.
    public mutating func contentChanged() { revision &+= 1 }

    /// Drops the running job: its result will be `superseded`.
    public mutating func cancel() { active = nil }

    public func verdict(for ticket: Ticket) -> Verdict {
        guard ticket.run == active else { return .superseded }
        return ticket.revision == revision ? .current : .stale
    }

    /// Called when a run's result arrives. Ends the run unless it was
    /// superseded (then a newer run is still going, or none at all).
    @discardableResult
    public mutating func finish(_ ticket: Ticket) -> Verdict {
        let v = verdict(for: ticket)
        if v != .superseded { active = nil }
        return v
    }
}
