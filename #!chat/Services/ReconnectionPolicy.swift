import Foundation

/// When to retry a connection that dropped or never came up: the first retry right away, the
/// second after `firstDelay`, and each later one after twice the wait before it, up to
/// `maximumDelay`. It never gives up: an outage can last longer than any number of attempts,
/// and the user can always cancel. Only keeps count — IRCConnectionService runs the timers and
/// the connects.
nonisolated struct ReconnectionPolicy {
    static let `default` = ReconnectionPolicy(firstDelay: .seconds(10), maximumDelay: .seconds(300))

    let firstDelay: Duration
    let maximumDelay: Duration
    private var attempts: [UUID: Int] = [:]

    init(firstDelay: Duration, maximumDelay: Duration) {
        self.firstDelay = firstDelay
        self.maximumDelay = maximumDelay
    }

    /// Counts another attempt for `serverID` (the first is number 1) and says how long to wait
    /// before making it.
    mutating func nextAttempt(for serverID: UUID) -> (attempt: Int, delay: Duration) {
        let attempt = attempts[serverID, default: 0] + 1
        attempts[serverID] = attempt
        return (attempt, delay(before: attempt))
    }

    /// Starts the count over: the connection proved stable, or the user asked to connect.
    mutating func reset(for serverID: UUID) {
        attempts[serverID] = nil
    }

    private func delay(before attempt: Int) -> Duration {
        guard attempt > 1 else { return .zero }
        var delay = firstDelay
        for _ in 2..<attempt where delay < maximumDelay { delay *= 2 }
        return min(delay, maximumDelay)
    }
}
