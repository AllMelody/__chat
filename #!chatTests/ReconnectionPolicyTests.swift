import Foundation
import Testing
@testable import __chat

struct ReconnectionPolicyTests {
    @Test func `Retries at once, then after the interval, then gives up`() {
        var policy = ReconnectionPolicy(maxAttempts: 3, retryInterval: .seconds(10))
        let server = UUID()
        let decisions = (1...5).map { _ in policy.nextAttempt(for: server) }
        #expect(decisions == [
            .retry(attempt: 1, after: .zero),
            .retry(attempt: 2, after: .seconds(10)),
            .retry(attempt: 3, after: .seconds(10)),
            .giveUp,
            .giveUp,   // stays given up until reset
        ])
    }

    @Test func `A reset starts the count over`() {
        var policy = ReconnectionPolicy(maxAttempts: 2, retryInterval: .seconds(10))
        let server = UUID()
        for _ in 1...3 { _ = policy.nextAttempt(for: server) }
        policy.reset(for: server)
        let next = policy.nextAttempt(for: server)
        #expect(next == .retry(attempt: 1, after: .zero))
    }

    @Test func `Each server has its own count`() {
        var policy = ReconnectionPolicy(maxAttempts: 5, retryInterval: .seconds(10))
        let first = UUID(), second = UUID()
        _ = policy.nextAttempt(for: first)
        let secondServersFirst = policy.nextAttempt(for: second)
        let firstServersSecond = policy.nextAttempt(for: first)
        #expect(secondServersFirst == .retry(attempt: 1, after: .zero))
        #expect(firstServersSecond == .retry(attempt: 2, after: .seconds(10)))
    }

    @Test func `By default, five attempts ten seconds apart`() {
        #expect(ReconnectionPolicy.default.maxAttempts == 5)
        #expect(ReconnectionPolicy.default.retryInterval == .seconds(10))
    }
}
