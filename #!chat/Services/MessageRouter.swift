import Foundation

/// Composer slash commands. Parsing is pure, so it's unit-tested on its own;
/// ChatStore.handleInputFromComposer carries the commands out.
enum MessageRouter {
    /// Result of parsing a composer input line. Pure data — no side effects — so it can be
    /// unit-tested independently of connections and view state.
    enum ParsedCommand: Equatable {
        case text(String)                       // non-slash plain message (may be empty)
        case join(channel: String, key: String?)
        case part(target: String?)              // nil = part the currently-selected channel
        case nick(String)
        case msg(target: String, message: String)
        case me(String)                         // an action: "/me waves" shows as "* nick waves"
        case quit
        case names
        case topic(String?)                     // nil = request the current topic
        case usage(String)                      // usage error; payload is the command name
        case unknown(String)                    // unrecognized command (empty = bare "/")
    }

    /// Pure parser: maps a raw composer line to a `ParsedCommand` with no side effects.
    static func parse(_ raw: String) -> ParsedCommand {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.hasPrefix("/") else { return .text(input) }

        let noSlash = String(input.dropFirst())
        var parts = noSlash.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard let cmd = parts.first?.lowercased() else { return .unknown("") }
        parts = Array(parts.dropFirst())

        switch cmd {
        case "join":
            guard let rawCh = parts.first else { return .usage("join") }
            let name = IRCName.isChannel(rawCh) ? rawCh : "#" + rawCh
            return .join(channel: name, key: parts.count >= 2 ? parts[1] : nil)
        case "part":
            return .part(target: parts.first)
        case "nick":
            guard let n = parts.first else { return .usage("nick") }
            return .nick(n)
        case "msg":
            guard parts.count >= 2 else { return .usage("msg") }
            return .msg(target: parts[0], message: parts[1])
        case "me":
            guard !parts.isEmpty else { return .usage("me") }
            return .me(parts.joined(separator: " "))
        case "quit":
            return .quit
        case "names":
            return .names
        case "topic":
            return .topic(parts.isEmpty ? nil : parts.joined(separator: " "))
        default:
            return .unknown(cmd)
        }
    }
}
