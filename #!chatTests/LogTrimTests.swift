import XCTest
@testable import __chat

@MainActor
final class LogTrimTests: XCTestCase {
    private func makeMessages(_ n: Int) -> [ChatMessage] {
        (0..<n).map { ChatMessage(time: Date(), text: "line \($0)") }
    }

    func testWithinSlackDoesNotTrim() {
        // Slack exists to batch the O(n) front removal: at or below cap + slack, no trim.
        let log = makeMessages(110)
        XCTAssertNil(ChatStore.trimOverflow(of: log, cap: 100, slack: 10))
        XCTAssertNil(ChatStore.trimOverflow(of: makeMessages(100), cap: 100, slack: 10))
        XCTAssertNil(ChatStore.trimOverflow(of: [], cap: 100, slack: 10))
    }

    func testOverflowKeepsNewestCapMessages() {
        let log = makeMessages(150)
        guard let t = ChatStore.trimOverflow(of: log, cap: 100, slack: 10) else {
            return XCTFail("expected a trim at 150 > cap 100 + slack 10")
        }
        XCTAssertEqual(t.kept.count, 100)
        XCTAssertEqual(t.dropped.count, 50)
        // Oldest messages are dropped, newest kept, order preserved, nothing lost.
        XCTAssertEqual(t.dropped, Array(log.prefix(50)))
        XCTAssertEqual(t.kept, Array(log.suffix(100)))
        XCTAssertEqual(t.dropped + t.kept, log)
    }

    func testZeroSlackTrimsImmediatelyPastCap() {
        let log = makeMessages(101)
        guard let t = ChatStore.trimOverflow(of: log, cap: 100, slack: 0) else {
            return XCTFail("expected a trim at 101 > cap 100 + slack 0")
        }
        XCTAssertEqual(t.kept.count, 100)
        XCTAssertEqual(t.dropped.count, 1)
    }

    func testDegenerateCapIsClampedToOne() {
        // cap <= 0 must not empty the log entirely; it behaves like cap 1.
        let log = makeMessages(10)
        guard let t = ChatStore.trimOverflow(of: log, cap: 0, slack: 0) else {
            return XCTFail("expected a trim at 10 > cap 1 + slack 0")
        }
        XCTAssertEqual(t.kept, [log.last!])
        XCTAssertEqual(t.dropped.count, 9)
    }
}
