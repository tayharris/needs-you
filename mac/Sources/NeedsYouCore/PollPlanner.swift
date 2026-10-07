import Foundation

/// Decides whether the next poll is incremental (`since`) or a full snapshot.
///
/// An incremental poll (`since` = the hub's last `server_time`) returns everything that
/// changed, closed items included, so resolves arrive at once. A periodic full poll (no
/// `since`) is still treated as authoritative and drops anything no longer open, as a
/// resync (an older hub, a missed page). Full polls also happen first, after a wake, and
/// after an error.
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
