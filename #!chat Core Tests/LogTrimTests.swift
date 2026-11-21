import Foundation
import Testing
@testable import __chat

struct LogTrimTests {
    private func makeMessages(_ n: Int) -> [ChatMessage] {
        (0..<n).map { ChatMessage(time: Date(), text: "line \($0)") }
    }

    @Test func `Within slack does not trim`() {
        // Slack exists to batch the O(n) front removal: at or below cap + slack, no trim.
        #expect(ChatStore.trimOverflow(of: makeMessages(110), cap: 100, slack: 10) == nil)
        #expect(ChatStore.trimOverflow(of: makeMessages(100), cap: 100, slack: 10) == nil)
        #expect(ChatStore.trimOverflow(of: [], cap: 100, slack: 10) == nil)
    }

    @Test func `Overflow keeps newest cap messages`() throws {
        let log = makeMessages(150)
        let t = try #require(ChatStore.trimOverflow(of: log, cap: 100, slack: 10),
                             "expected a trim at 150 > cap 100 + slack 10")
        #expect(t.kept.count == 100)
        #expect(t.dropped.count == 50)
        // Oldest messages are dropped, newest kept, order preserved, nothing lost.
        #expect(t.dropped == Array(log.prefix(50)))
        #expect(t.kept == Array(log.suffix(100)))
        #expect(t.dropped + t.kept == log)
    }

    @Test func `Zero slack trims immediately past cap`() throws {
        let t = try #require(ChatStore.trimOverflow(of: makeMessages(101), cap: 100, slack: 0),
                             "expected a trim at 101 > cap 100 + slack 0")
        #expect(t.kept.count == 100)
        #expect(t.dropped.count == 1)
    }

    @Test func `Degenerate cap is clamped to one`() throws {
        // cap <= 0 must not empty the log entirely; it behaves like cap 1.
        let log = makeMessages(10)
        let t = try #require(ChatStore.trimOverflow(of: log, cap: 0, slack: 0),
                             "expected a trim at 10 > cap 1 + slack 0")
        #expect(t.kept == [try #require(log.last)])
        #expect(t.dropped.count == 9)
    }
}
