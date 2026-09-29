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

    func testEarlierThisYearUsesMonthDayTime() throws {
        // "MMM d, HH:mm" — guarded so it only asserts when the sample date is genuinely
        // this year and not today (avoids year-rollover / same-day flakiness).
        let cal = Calendar.current
        let now = Date()
        guard let candidate = cal.date(byAdding: .day, value: -60, to: now) else {
            return XCTFail("could not compute candidate date")
        }
        guard cal.component(.year, from: candidate) == cal.component(.year, from: now),
              !cal.isDateInToday(candidate) else {
            // Near Jan/Feb, 60 days ago falls in the previous year; skip visibly
            // instead of silently passing without asserting anything.
            throw XCTSkip("60 days ago falls outside the current year")
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
        XCTAssertEqual(s, "Mar 5 2000, 14:30")
    }

    func testExactFormats() {
        // Pin the POSIX, 24-hour formats so a formatter refactor can't change output.
        var comps = DateComponents()
        comps.year = 2001; comps.month = 11; comps.day = 23; comps.hour = 9; comps.minute = 7
        let d = Calendar.current.date(from: comps)!
        XCTAssertEqual(d.formatted(Formatting.timeOnly), "09:07")
        XCTAssertEqual(d.formatted(Formatting.dateTime), "Nov 23, 09:07")
        XCTAssertEqual(d.formatted(Formatting.yearDateTime), "Nov 23 2001, 09:07")
    }
}
