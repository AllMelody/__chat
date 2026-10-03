import Foundation

/// One IRC protocol message: optional IRCv3 tags and source, a command, and its parameters.
///
///     @time=2026-01-01T12:00:00.000Z :nick!user@host PRIVMSG #swift :hello there
///
/// Inbound lines are parsed with `init?(_:)`. Outbound messages are usually built with the
/// constructors in IRCMessage+Commands.swift and written with `wireFormat`.
nonisolated struct IRCMessage: Equatable, Sendable {
    /// IRCv3 message tags with their values unescaped. A tag sent without a value maps to "".
    var tags: [String: String]
    /// Who sent the message: a user (`nick!user@host`) or a server. Absent on messages we send.
    var source: IRCSource?
    /// The command name in uppercase (`PRIVMSG`), or a three-digit numeric reply (`001`).
    var command: String
    var parameters: [String]

    init(_ command: String, _ parameters: [String] = [], source: IRCSource? = nil, tags: [String: String] = [:]) {
        self.command = command.uppercased()
        self.parameters = parameters
        self.source = source
        self.tags = tags
    }
}

// MARK: - Parsing

nonisolated extension IRCMessage {
    /// Parses one line, without its line terminator (RFC 1459 §2.3.1 plus IRCv3 message
    /// tags). Returns nil when the line has no command.
    init?(_ line: String) {
        var rest = ArraySlice(line.utf8).drop { $0 == .space }

        /// Removes and returns the next space-delimited token.
        func nextToken() -> ArraySlice<UInt8> {
            let end = rest.firstIndex(of: .space) ?? rest.endIndex
            defer { rest = rest[end...].drop { $0 == .space } }
            return rest[..<end]
        }

        let tags = rest.first == .at ? Self.parseTags(nextToken().dropFirst()) : [:]
        let source = rest.first == .colon ? IRCSource(String(decoding: nextToken().dropFirst(), as: UTF8.self)) : nil
        let command = nextToken()
        guard !command.isEmpty else { return nil }

        var parameters: [String] = []
        while let first = rest.first {
            if first == .colon {
                // Trailing parameter: everything after the colon, spaces included.
                parameters.append(String(decoding: rest.dropFirst(), as: UTF8.self))
                break
            }
            parameters.append(String(decoding: nextToken(), as: UTF8.self))
        }

        self.init(String(decoding: command, as: UTF8.self), parameters, source: source, tags: tags)
    }

    /// `key=value;key2;vendor/key3=value` → dictionary. A repeated key keeps its last value.
    private static func parseTags(_ raw: ArraySlice<UInt8>) -> [String: String] {
        var tags: [String: String] = [:]
        for tag in raw.split(separator: .semicolon) {
            let equals = tag.firstIndex(of: .equals) ?? tag.endIndex
            let key = String(decoding: tag[..<equals], as: UTF8.self)
            tags[key] = unescapeTagValue(tag[equals...].dropFirst())
        }
        return tags
    }

    /// Undoes IRCv3 tag-value escaping: `\:` is `;`, `\s` a space, `\\` a backslash, `\r`
    /// and `\n` CR and LF. Any other escaped character stands for itself, and a trailing
    /// lone backslash is dropped.
    private static func unescapeTagValue(_ escaped: ArraySlice<UInt8>) -> String {
        var bytes: [UInt8] = []
        var iterator = escaped.makeIterator()
        while let byte = iterator.next() {
            guard byte == .backslash else {
                bytes.append(byte)
                continue
            }
            switch iterator.next() {
            case UInt8(ascii: ":"): bytes.append(.semicolon)
            case UInt8(ascii: "s"): bytes.append(.space)
            case UInt8(ascii: "r"): bytes.append(UInt8(ascii: "\r"))
            case UInt8(ascii: "n"): bytes.append(UInt8(ascii: "\n"))
            case let other?: bytes.append(other)
            case nil: break
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - Serialization

nonisolated extension IRCMessage {
    /// The message as one protocol line, without the CR-LF terminator. The last parameter
    /// goes out as a trailing (`:`-prefixed) parameter when it has to: when it's empty,
    /// contains a space, or starts with a colon.
    ///
    /// CR, LF and NUL can't appear inside a line, so they're replaced with spaces; text
    /// can never smuggle a second command onto the wire. Tags and source aren't written.
    var wireFormat: String {
        var line = command
        for (index, parameter) in parameters.enumerated() {
            let parameter = parameter.components(separatedBy: Self.lineBreakingCharacters).joined(separator: " ")
            let needsColon = parameter.isEmpty || parameter.contains(" ") || parameter.hasPrefix(":")
            let isLast = index == parameters.count - 1
            line += isLast && needsColon ? " :\(parameter)" : " \(parameter)"
        }
        return line
    }

    private static let lineBreakingCharacters = CharacterSet(charactersIn: "\r\n\0")
}

// MARK: - IRCv3 server-time

nonisolated extension IRCMessage {
    /// When the server says the message was originally sent (the IRCv3 `time` tag), e.g. for
    /// backlog a bouncer replays on connect. Nil when the tag is absent or malformed.
    var serverTime: Date? {
        guard let value = tags["time"] else { return nil }
        // The spec mandates millisecond precision, but not every server sends it.
        return (try? Self.timeWithFractionalSeconds.parse(value)) ?? (try? Self.timeWithoutFractionalSeconds.parse(value))
    }

    private static let timeWithFractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let timeWithoutFractionalSeconds = Date.ISO8601FormatStyle()
}

private nonisolated extension UInt8 {
    static let space = UInt8(ascii: " ")
    static let colon = UInt8(ascii: ":")
    static let semicolon = UInt8(ascii: ";")
    static let equals = UInt8(ascii: "=")
    static let at = UInt8(ascii: "@")
    static let backslash = UInt8(ascii: "\\")
}
