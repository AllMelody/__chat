import XCTest
@testable import __chat

@MainActor
final class FormattingTests: XCTestCase {
    func testTodayUsesTimeOnly() {
        // Today -> "HH:mm": exactly 5 chars, has a colon, no comma.
        let s = Formatting.timeString(Date())
        XCTAssertEqual(s.count, 5)
        XCTAssertTrue(s.contains(":"))
        XCTAssertFalse(s.contains(","))
    }

    func testEarlierThisYearUsesMonthDayTime() {
        // "MMM d, HH:mm" — guarded so it only asserts when the sample date is genuinely
        // this year and not today (avoids year-rollover / same-day flakiness).
        let cal = Calendar.current
        let now = Date()
        guard let candidate = cal.date(byAdding: .day, value: -60, to: now) else {
            return XCTFail("could not compute candidate date")
        }
        guard cal.component(.year, from: candidate) == cal.component(.year, from: now),
              !cal.isDateInToday(candidate) else {
            return // skip near Jan/Feb where 60 days ago is last year
        }
        let s = Formatting.timeString(candidate)
        XCTAssertTrue(s.contains(","))
    }

    func testPreviousYearIncludesYear() {
        // "MMM d yyyy, HH:mm" — fully deterministic.
        var comps = DateComponents()
        comps.year = 2000; comps.month = 3; comps.day = 5; comps.hour = 14; comps.minute = 30
        let d = Calendar.current.date(from: comps)!
        let s = Formatting.timeString(d)
        XCTAssertTrue(s.contains("2000"))
        XCTAssertTrue(s.contains(","))
    }
}
