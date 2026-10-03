import Foundation

/// When to retry a connection that dropped or never came up: the first retry right away, each
/// later one after `retryInterval`, and none after `maxAttempts` in a row. Only keeps count —
/// IRCConnectionService runs the timers and the connects.
nonisolated struct ReconnectionPolicy {
    /// What to do about a server's next reconnection.
    enum Decision: Equatable {
        /// Make attempt number `attempt` (counting from 1) once `delay` has passed.
        case retry(attempt: Int, after: Duration)
        /// `maxAttempts` attempts in a row have failed; stop until the count is reset.
        case giveUp
    }

    static let `default` = ReconnectionPolicy(maxAttempts: 5, retryInterval: .seconds(10))

    let maxAttempts: Int
    let retryInterval: Duration
    private var attempts: [UUID: Int] = [:]

    init(maxAttempts: Int, retryInterval: Duration) {
        self.maxAttempts = maxAttempts
        self.retryInterval = retryInterval
    }

    /// Counts another attempt for `serverID` and decides whether, and when, to make it.
    mutating func nextAttempt(for serverID: UUID) -> Decision {
        let attempt = attempts[serverID, default: 0] + 1
        attempts[serverID] = attempt
        guard attempt <= maxAttempts else { return .giveUp }
        return .retry(attempt: attempt, after: attempt == 1 ? .zero : retryInterval)
    }

    /// Starts the count over: the connection proved stable, or the user asked to connect.
    mutating func reset(for serverID: UUID) {
        attempts[serverID] = nil
    }
}
