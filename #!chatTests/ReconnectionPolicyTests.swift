import Foundation
import Testing
@testable import __chat

struct ReconnectionPolicyTests {
    @Test func `Retries at once, then after pauses that double up to the maximum`() {
        var policy = ReconnectionPolicy(firstDelay: .seconds(10), maximumDelay: .seconds(60))
        let server = UUID()
        let attempts = (1...7).map { _ in policy.nextAttempt(for: server) }
        #expect(attempts.map { $0.attempt } == Array(1...7))
        #expect(attempts.map { $0.delay } ==
                [.zero, .seconds(10), .seconds(20), .seconds(40), .seconds(60), .seconds(60), .seconds(60)])
    }

    @Test func `It never gives up`() {
        var policy = ReconnectionPolicy(firstDelay: .seconds(10), maximumDelay: .seconds(300))
        let server = UUID()
        for _ in 1..<1000 { _ = policy.nextAttempt(for: server) }
        let thousandth = policy.nextAttempt(for: server)
        #expect(thousandth.attempt == 1000)
        #expect(thousandth.delay == .seconds(300))
    }

    @Test func `A reset starts the count over`() {
        var policy = ReconnectionPolicy(firstDelay: .seconds(10), maximumDelay: .seconds(60))
        let server = UUID()
        for _ in 1...3 { _ = policy.nextAttempt(for: server) }
        policy.reset(for: server)
        let next = policy.nextAttempt(for: server)
        #expect(next.attempt == 1)
        #expect(next.delay == .zero)
    }

    @Test func `Each server has its own count`() {
        var policy = ReconnectionPolicy(firstDelay: .seconds(10), maximumDelay: .seconds(60))
        let first = UUID(), second = UUID()
        _ = policy.nextAttempt(for: first)
        let secondServersFirst = policy.nextAttempt(for: second)
        let firstServersSecond = policy.nextAttempt(for: first)
        #expect(secondServersFirst.attempt == 1)
        #expect(secondServersFirst.delay == .zero)
        #expect(firstServersSecond.attempt == 2)
        #expect(firstServersSecond.delay == .seconds(10))
    }

    @Test func `By default, ten seconds doubling up to five minutes`() {
        #expect(ReconnectionPolicy.default.firstDelay == .seconds(10))
        #expect(ReconnectionPolicy.default.maximumDelay == .seconds(300))
    }
}
