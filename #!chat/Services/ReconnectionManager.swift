import Foundation

protocol ReconnectionManagerDelegate: AnyObject {
    func reconnectionManager(_ manager: ReconnectionManager, shouldReconnect serverID: UUID)
    func reconnectionManager(_ manager: ReconnectionManager, didScheduleReconnect serverID: UUID, attempt: Int, delay: TimeInterval)
    func reconnectionManager(_ manager: ReconnectionManager, didExhaustAttempts serverID: UUID, maxAttempts: Int)
}

final class ReconnectionManager {

    struct Policy {
        let maxAttempts: Int
        let retryInterval: TimeInterval  // Used for attempts after the first

        static let `default` = Policy(
            maxAttempts: 5,
            retryInterval: 10.0
        )
    }

    weak var delegate: ReconnectionManagerDelegate?

    private var attempts: [UUID: Int] = [:]
    private var timers: [UUID: Timer] = [:]
    private var policies: [UUID: Policy] = [:]

    // MARK: - Public API

    /// Schedule a reconnection attempt for the given server.
    /// Returns true if scheduled, false if max attempts exhausted.
    @discardableResult
    func scheduleReconnection(for serverID: UUID, policy: Policy = .default) -> Bool {
        // Cancel any existing timer
        cancelReconnection(for: serverID)

        // Store policy for this server
        policies[serverID] = policy

        // Increment attempt counter
        let attempt = (attempts[serverID] ?? 0) + 1
        attempts[serverID] = attempt

        // Check if we've exhausted attempts
        guard attempt <= policy.maxAttempts else {
            delegate?.reconnectionManager(self, didExhaustAttempts: serverID, maxAttempts: policy.maxAttempts)
            return false
        }

        // First attempt is immediate, subsequent attempts use the retry interval
        let delay: TimeInterval = (attempt == 1) ? 0 : policy.retryInterval

        // Notify delegate about scheduled reconnection
        delegate?.reconnectionManager(self, didScheduleReconnect: serverID, attempt: attempt, delay: delay)

        // For immediate reconnection, call directly; otherwise schedule a timer
        if delay == 0 {
            delegate?.reconnectionManager(self, shouldReconnect: serverID)
        } else {
            let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.delegate?.reconnectionManager(self, shouldReconnect: serverID)
                }
            }
            timers[serverID] = timer
        }

        return true
    }

    /// Cancel any pending reconnection for the given server.
    func cancelReconnection(for serverID: UUID) {
        timers[serverID]?.invalidate()
        timers.removeValue(forKey: serverID)
    }

    /// Reset the attempt counter for the given server.
    /// Call this after a successful connection.
    func resetAttempts(for serverID: UUID) {
        attempts.removeValue(forKey: serverID)
        policies.removeValue(forKey: serverID)
    }

    /// Cancel reconnection and reset attempts.
    func reset(for serverID: UUID) {
        cancelReconnection(for: serverID)
        resetAttempts(for: serverID)
    }

    /// Cancel all pending reconnections.
    func cancelAll() {
        for timer in timers.values {
            timer.invalidate()
        }
        timers.removeAll()
    }

    /// Get the current attempt count for a server.
    func currentAttempt(for serverID: UUID) -> Int {
        attempts[serverID] ?? 0
    }

    /// Check if a reconnection is scheduled for the given server.
    func isReconnectionScheduled(for serverID: UUID) -> Bool {
        timers[serverID] != nil
    }

    deinit {
        cancelAll()
    }
}
