import Foundation
import Testing
@testable import __chat

struct FormattingTests {
    @Test func `Today uses time only`() {
        // Today -> "HH:mm": exactly 5 chars, has a colon, no comma.
        let s = Formatting.timeString(Date())
        #expect(s.count == 5)
        #expect(s.contains(":"))
        #expect(!s.contains(","))
    }

    @Test func `Earlier this year uses month, day and time`() throws {
        // "MMM d, HH:mm" — cancelled (not silently passed) when the sample date isn't
        // genuinely this year and not today, to avoid year-rollover / same-day flakiness.
        let cal = Calendar.current
        let now = Date()
        let candidate = try #require(cal.date(byAdding: .day, value: -60, to: now),
                                     "could not compute candidate date")
        guard cal.component(.year, from: candidate) == cal.component(.year, from: now),
              !cal.isDateInToday(candidate) else {
            // Near Jan/Feb, 60 days ago falls in the previous year.
            try Test.cancel("60 days ago falls outside the current year")
        }
        #expect(Formatting.timeString(candidate).contains(","))
    }

    @Test func `Previous year includes year`() throws {
        // "MMM d yyyy, HH:mm" — fully deterministic.
        var comps = DateComponents()
        comps.year = 2000; comps.month = 3; comps.day = 5; comps.hour = 14; comps.minute = 30
        let d = try #require(Calendar.current.date(from: comps))
        #expect(Formatting.timeString(d) == "Mar 5 2000, 14:30")
    }

    @Test func `Exact formats`() throws {
        // Pin the POSIX, 24-hour formats so a formatter refactor can't change output.
        var comps = DateComponents()
        comps.year = 2001; comps.month = 11; comps.day = 23; comps.hour = 9; comps.minute = 7
        let d = try #require(Calendar.current.date(from: comps))
        #expect(d.formatted(Formatting.timeOnly) == "09:07")
        #expect(d.formatted(Formatting.dateTime) == "Nov 23, 09:07")
        #expect(d.formatted(Formatting.yearDateTime) == "Nov 23 2001, 09:07")
    }
}
