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

    // MARK: - Nick mention (highlight) detection

    /// Characters that can be part of an IRC nickname (RFC 2812: letters, digits, and
    /// []\`_^{|}- specials). A candidate match is a real mention only when the characters
    /// around it are NOT nick characters — "AllMelody:" mentions AllMelody, but
    /// "AllMelody_" is somebody else entirely.
    private static let nickCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "[]\\`_^{|}-")
        return set
    }()

    private static func isNickCharacter(_ ch: Character) -> Bool {
        ch.unicodeScalars.allSatisfy { nickCharacters.contains($0) }
    }

    /// True when `text` mentions `nick` as a standalone word (case-insensitive).
    static func mentionsNick(_ nick: String, in text: String) -> Bool {
        guard !nick.isEmpty else { return false }
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: nick, options: [.caseInsensitive], range: searchRange) {
            let beforeOK = found.lowerBound == text.startIndex
                || !isNickCharacter(text[text.index(before: found.lowerBound)])
            let afterOK = found.upperBound == text.endIndex
                || !isNickCharacter(text[found.upperBound])
            if beforeOK && afterOK { return true }
            guard found.upperBound < text.endIndex else { break }
            searchRange = text.index(after: found.lowerBound)..<text.endIndex
        }
        return false
    }
}