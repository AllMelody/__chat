import Foundation

protocol ReconnectionManagerDelegate: AnyObject {
    func reconnectionManager(_ manager: ReconnectionManager, shouldReconnect serverID: UUID)
    func reconnectionManager(_ manager: ReconnectionManager, didScheduleReconnect serverID: UUID, attempt: Int, delay: Duration)
    func reconnectionManager(_ manager: ReconnectionManager, didExhaustAttempts serverID: UUID, maxAttempts: Int)
}

final class ReconnectionManager {

    struct Policy {
        let maxAttempts: Int
        let retryInterval: Duration  // Used for attempts after the first

        static let `default` = Policy(
            maxAttempts: 5,
            retryInterval: .seconds(10)
        )
    }

    weak var delegate: ReconnectionManagerDelegate?

    private var attempts: [UUID: Int] = [:]
    private var tasks: [UUID: Task<Void, any Error>] = [:]

    // MARK: - Public API

    /// Schedule a reconnection attempt for the given server, or report exhaustion to the
    /// delegate once `Policy.default.maxAttempts` is used up.
    func scheduleReconnection(for serverID: UUID) {
        let policy = Policy.default

        // Cancel any pending attempt
        cancelReconnection(for: serverID)

        // Increment attempt counter
        let attempt = (attempts[serverID] ?? 0) + 1
        attempts[serverID] = attempt

        // Check if we've exhausted attempts
        guard attempt <= policy.maxAttempts else {
            delegate?.reconnectionManager(self, didExhaustAttempts: serverID, maxAttempts: policy.maxAttempts)
            return
        }

        // First attempt is immediate, subsequent attempts use the retry interval
        let delay: Duration = (attempt == 1) ? .zero : policy.retryInterval

        // Notify delegate about scheduled reconnection
        delegate?.reconnectionManager(self, didScheduleReconnect: serverID, attempt: attempt, delay: delay)

        // For immediate reconnection, call directly; otherwise schedule a delayed task.
        // Task.sleep only throws on cancellation, which simply ends the task.
        if delay == .zero {
            delegate?.reconnectionManager(self, shouldReconnect: serverID)
        } else {
            tasks[serverID] = Task { [weak self] in
                try await Task.sleep(for: delay)
                // A cancel can land after the sleep finished but before we resumed on main.
                try Task.checkCancellation()
                guard let self else { return }
                self.tasks[serverID] = nil
                self.delegate?.reconnectionManager(self, shouldReconnect: serverID)
            }
        }
    }

    /// Cancel any pending reconnection for the given server.
    func cancelReconnection(for serverID: UUID) {
        tasks.removeValue(forKey: serverID)?.cancel()
    }

    /// Reset the attempt counter for the given server.
    /// Call this after a successful connection.
    func resetAttempts(for serverID: UUID) {
        attempts.removeValue(forKey: serverID)
    }

    deinit {
        for task in tasks.values {
            task.cancel()
        }
    }
}
