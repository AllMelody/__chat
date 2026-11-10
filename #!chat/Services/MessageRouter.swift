import Foundation

/// Composer slash commands. Parsing is pure, so it's unit-tested on its own;
/// ChatStore.handleInputFromComposer carries the commands out.
enum MessageRouter {
    /// Result of parsing a composer input line. Pure data — no side effects — so it can be
    /// unit-tested independently of connections and view state.
    enum ParsedCommand: Equatable {
        case text(String)                       // plain message (may be empty); "//" sends a leading "/"
        case join(channels: [String], keys: [String])   // keys go with the channels in order, as far as they reach
        case part(target: String?)              // nil = part the currently-selected channel
        case nick(String)
        case msg(target: String, message: String)
        case query(nick: String, message: String?)   // open a private conversation, with a first message or without
        case me(String)                         // an action: "/me waves" shows as "* nick waves"
        case quit
        case names
        case topic(String?)                     // nil = request the current topic
        case raw(String)                        // a line for the server: what follows "/raw", or a command the app doesn't know
        case usage(String)                      // usage error; payload is the command name
    }

    /// Pure parser: maps a raw composer line to a `ParsedCommand` with no side effects.
    static func parse(_ raw: String) -> ParsedCommand {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.hasPrefix("/") else { return .text(input) }
        // "//" escapes a leading slash: "//shrug" sends the text "/shrug".
        if input.hasPrefix("//") { return .text(String(input.dropFirst())) }

        let noSlash = String(input.dropFirst())
        var parts = noSlash.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        // A bare "/" says nothing.
        guard let cmd = parts.first?.lowercased() else { return .text("") }
        parts = Array(parts.dropFirst())

        switch cmd {
        case "join":
            guard let names = parts.first else { return .usage("join") }
            let keys = parts.count >= 2 ? parts[1].split(separator: ",").map(String.init) : []
            return .join(channels: channelNames(names), keys: keys)
        case "part":
            return .part(target: parts.first.map { channelName($0) })
        case "nick":
            guard let n = parts.first else { return .usage("nick") }
            return .nick(n)
        case "msg":
            guard parts.count >= 2 else { return .usage("msg") }
            return .msg(target: parts[0], message: parts[1])
        case "query":
            guard let nick = parts.first else { return .usage("query") }
            return .query(nick: nick, message: parts.count >= 2 ? parts[1] : nil)
        case "me":
            guard !parts.isEmpty else { return .usage("me") }
            return .me(parts.joined(separator: " "))
        case "quit":
            return .quit
        case "names":
            return .names
        case "topic":
            return .topic(parts.isEmpty ? nil : parts.joined(separator: " "))
        case "raw", "quote":
            guard !parts.isEmpty else { return .usage("raw") }
            return .raw(parts.joined(separator: " "))
        default:
            // Anything else is the server's to understand: /whois nick, /mode #chan +o nick, …
            return .raw(serverLine(cmd, parts.joined(separator: " ")))
        }
    }

    /// The channels in a list as typed, like `#swift,help`: each name without a channel prefix
    /// gets the usual `#`.
    static func channelNames(_ list: String) -> [String] {
        list.split(separator: ",").map { channelName(String($0)) }
    }

    private static func channelName(_ name: String) -> String {
        IRCName.isChannel(name) ? name : "#" + name
    }

    /// Server commands that end in free text, with the number of one-word parameters before
    /// it, so that `/away back in an hour` sends all of the message and not just `back`.
    private static let freeTextCommands = ["away": 0, "kick": 2, "notice": 1]

    /// The protocol line for a command the app passes on, parameters as typed.
    private static func serverLine(_ command: String, _ arguments: String) -> String {
        guard let leading = freeTextCommands[command] else {
            return arguments.isEmpty ? command : "\(command) \(arguments)"
        }
        var words = arguments.split(separator: " ", maxSplits: leading, omittingEmptySubsequences: true).map(String.init)
        if words.count > leading, !words[leading].hasPrefix(":") { words[leading] = ":" + words[leading] }
        return ([command] + words).joined(separator: " ")
    }
}
