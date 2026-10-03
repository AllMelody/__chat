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
    /// Sets the topic, or with no `topic` asks the server for the current one.
    static func topic(_ channel: String, _ topic: String? = nil) -> IRCMessage {
        IRCMessage("TOPIC", [channel] + (topic.map { [$0] } ?? []))
    }
    static func names(_ channel: String) -> IRCMessage { IRCMessage("NAMES", [channel]) }
    static func who(_ mask: String) -> IRCMessage { IRCMessage("WHO", [mask]) }
    static func quit(_ reason: String? = nil) -> IRCMessage { IRCMessage("QUIT", reason.map { [$0] } ?? []) }
}
