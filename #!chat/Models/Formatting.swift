import Foundation

enum Formatting {
    static let timeOnlyFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "HH:mm"
        return df
    }()

    static let dateTimeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "MMM d, HH:mm"
        return df
    }()

    static let yearDateTimeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "MMM d yyyy, HH:mm"
        return df
    }()

    /// Formats a date for display in chat messages.
    /// - Today: shows just time (HH:mm)
    /// - This year: shows date and time (MMM d, HH:mm)
    /// - Previous years: shows full date with year (MMM d yyyy, HH:mm)
    static func timeString(_ date: Date = Date()) -> String {
        let calendar = Calendar.current
        let now = Date()

        if calendar.isDateInToday(date) {
            return timeOnlyFormatter.string(from: date)
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return dateTimeFormatter.string(from: date)
        } else {
            return yearDateTimeFormatter.string(from: date)
        }
    }
}