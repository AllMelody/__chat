import Foundation

enum Formatting {
    // Fixed POSIX, 24-hour formats (not user-locale dependent). Format styles are
    // Sendable value types, unlike DateFormatter.
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// HH:mm
    static let timeOnly = Date.VerbatimFormatStyle(
        format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
        locale: posix, timeZone: .autoupdatingCurrent, calendar: .autoupdatingCurrent)

    /// MMM d, HH:mm
    static let dateTime = Date.VerbatimFormatStyle(
        format: "\(month: .abbreviated) \(day: .defaultDigits), \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
        locale: posix, timeZone: .autoupdatingCurrent, calendar: .autoupdatingCurrent)

    /// MMM d yyyy, HH:mm
    static let yearDateTime = Date.VerbatimFormatStyle(
        format: "\(month: .abbreviated) \(day: .defaultDigits) \(year: .defaultDigits), \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
        locale: posix, timeZone: .autoupdatingCurrent, calendar: .autoupdatingCurrent)

    /// Formats a date for display in chat messages.
    /// - Today: shows just time (HH:mm)
    /// - This year: shows date and time (MMM d, HH:mm)
    /// - Previous years: shows full date with year (MMM d yyyy, HH:mm)
    static func timeString(_ date: Date = .now) -> String {
        let calendar = Calendar.current
        let now = Date.now

        if calendar.isDateInToday(date) {
            return date.formatted(timeOnly)
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(dateTime)
        } else {
            return date.formatted(yearDateTime)
        }
    }

    // MARK: - Links

    // Link-only data detectors can't fail to initialize.
    private static let linkDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// The web links in `text` and where they are: what the log makes clickable and what gets a
    /// thumbnail.
    ///
    /// Only http and https count. The detector also finds mail addresses and links such as
    /// `ssh://` or `file://`, which a click on something a stranger said shouldn't open. And a
    /// name written without its scheme is a link only when it looks like one (`www.example.com`,
    /// `example.com/page`): `main.rs` and `foo.pl` are host names too, but in chat they're files.
    static func webLinks(in text: String) -> [(range: NSRange, url: URL)] {
        let string = text as NSString
        var links: [(range: NSRange, url: URL)] = []
        linkDetector.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: string.length)) { match, _, _ in
            guard let match, let url = match.url, let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme) else { return }
            let written = string.substring(with: match.range).lowercased()
            guard written.hasPrefix("\(scheme)://") || written.hasPrefix("www.") || written.contains("/") else { return }
            links.append((match.range, url))
        }
        return links
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