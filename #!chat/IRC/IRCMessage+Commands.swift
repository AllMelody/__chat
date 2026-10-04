/// Constructors for the client commands the app sends (RFC 2812 §3, IRCv3 capability
/// negotiation), so call sites read `client.send(.join("#swift"))`.
nonisolated extension IRCMessage {
    static func capabilityList() -> IRCMessage { IRCMessage("CAP", ["LS", "302"]) }
    static func capabilityRequest(_ capabilities: [String]) -> IRCMessage {
        IRCMessage("CAP", ["REQ", capabilities.joined(separator: " ")])
    }
    static func capabilityEnd() -> IRCMessage { IRCMessage("CAP", ["END"]) }

    static func pass(_ password: String) -> IRCMessage { IRCMessage("PASS", [password]) }
    static func nick(_ nickname: String) -> IRCMessage { IRCMessage("NICK", [nickname]) }
    /// `USER <username> 0 * :<real name>` (RFC 2812 §3.1.3; mode 0 requests no user modes).
    static func user(_ username: String, realName: String) -> IRCMessage {
        IRCMessage("USER", [username, "0", "*", realName])
    }

    static func ping(_ token: String) -> IRCMessage { IRCMessage("PING", [token]) }
    static func pong(_ token: String) -> IRCMessage { IRCMessage("PONG", [token]) }

    static func join(_ channel: String, key: String? = nil) -> IRCMessage {
        IRCMessage("JOIN", [channel] + (key.map { [$0] } ?? []))
    }
    static func part(_ channel: String) -> IRCMessage { IRCMessage("PART", [channel]) }
    static func privateMessage(to target: String, _ text: String) -> IRCMessage {
        IRCMessage("PRIVMSG", [target, text])
    }
    /// `/me <text>`: a CTCP ACTION.
    static func action(to target: String, _ text: String) -> IRCMessage {
        .privateMessage(to: target, CTCPMessage(command: "ACTION", parameters: text).text)
    }
    /// The answer to a CTCP query. Replies go out as NOTICEs, which are never answered.
    static func ctcpReply(to target: String, _ reply: CTCPMessage) -> IRCMessage {
        IRCMessage("NOTICE", [target, reply.text])
    }
    /// Sets the topic, or with no `topic` asks the server for the current one.
    static func topic(_ channel: String, _ topic: String? = nil) -> IRCMessage {
        IRCMessage("TOPIC", [channel] + (topic.map { [$0] } ?? []))
    }
    static func names(_ channel: String) -> IRCMessage { IRCMessage("NAMES", [channel]) }
    static func quit(_ reason: String? = nil) -> IRCMessage { IRCMessage("QUIT", reason.map { [$0] } ?? []) }
}

// MARK: - Long messages

nonisolated extension IRCMessage {
    /// The most bytes of text a PRIVMSG (or with `asAction`, a `/me`) to `target` can carry and
    /// still reach everyone whole. A line is at most 512 bytes (RFC 2812 §2.3), and the copy the
    /// server relays carries our `nick!user@host` in front. The user and host aren't known here,
    /// so this leaves room for the longest usual ones.
    static func maximumTextLength(to target: String, from nickname: String, asAction: Bool = false) -> Int {
        let empty = asAction ? action(to: target, "") : privateMessage(to: target, "")
        // ":nick!user@host PRIVMSG <target> :<text>\r\n"
        let overhead = 1 + nickname.utf8.count + longestUserAndHost + 1 + empty.wireFormat.utf8.count + 2
        return maximumLineLength - overhead
    }

    /// Splits `text` into pieces of at most `maximumLength` UTF-8 bytes, breaking between words
    /// where it can and never inside a character.
    static func split(_ text: String, maximumLength: Int) -> [String] {
        var pieces: [String] = []
        var rest = text[...]
        while rest.utf8.count > maximumLength {
            // The longest run of whole characters that fits. It ends before `rest` does.
            var end = rest.startIndex
            var length = 0
            while length + rest[end].utf8.count <= maximumLength {
                length += rest[end].utf8.count
                end = rest.index(after: end)
            }
            // Break at the run's last space, or the one just after it, dropping the space.
            if let space = rest[...end].lastIndex(of: " "), space > rest.startIndex {
                pieces.append(String(rest[..<space]))
                rest = rest[rest.index(after: space)...]
            } else {
                // No space to break at: cut the word. A character too long to fit goes alone.
                if end == rest.startIndex { end = rest.index(after: end) }
                pieces.append(String(rest[..<end]))
                rest = rest[end...]
            }
        }
        pieces.append(String(rest))
        return pieces
    }

    private static let maximumLineLength = 512
    /// `!user@host` at the usual limits of 10 characters for the user and 63 for the host.
    private static let longestUserAndHost = 1 + 10 + 1 + 63
}
