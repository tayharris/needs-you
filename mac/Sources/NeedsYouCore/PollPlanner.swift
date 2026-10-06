import Foundation

/// Decides whether the next poll is incremental (`since`) or a full snapshot.
///
/// `GET /v1/items?status=open&since=` only returns *open* items, so an incremental poll
/// can never tell the Mac that a sender resolved something. A periodic full poll (no
/// `since`) is treated as authoritative and drops anything no longer open. Full polls
/// also happen first, after a wake, and after an error.
public struct PollPlanner: Sendable {
    public var fullEvery: Int
    private var incrementalSinceFull: Int?

    public init(fullEvery: Int = 10) {
        self.fullEvery = max(1, fullEvery)
    }

    /// The `since` to send, or nil for a full snapshot. Call once per poll.
    public mutating func nextSince(latest: Date?) -> Date? {
        guard let count = incrementalSinceFull, let latest, count + 1 < fullEvery else {
            incrementalSinceFull = 0
            return nil
        }
        incrementalSinceFull = count + 1
        return latest
    }

    /// Make the next poll a full snapshot (wake from sleep, error, settings change).
    public mutating func forceFull() { incrementalSinceFull = nil }
}
