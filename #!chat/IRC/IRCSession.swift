import Foundation

/// The IRC protocol for one connection, as a state machine with no I/O: hand it each message
/// from the server and it returns the replies to send and the events to report.
///
/// It registers (RFC 2812 §3.1) after negotiating IRCv3 capabilities (CAP 302), answers
/// PINGs and the mandatory CTCP queries, tracks our nickname, and turns server messages
/// into `IRCEvent`s.
nonisolated struct IRCSession {
    /// What handling one message produced.
    struct Output: Equatable {
        var replies: [IRCMessage] = []
        var events: [IRCEvent] = []
    }

    /// Our nickname: the one we asked for until the server confirms or changes it.
    private(set) var nickname: String
    private(set) var isRegistered = false

    private let password: String?
    private var isNegotiatingCapabilities = true
    private var offeredCapabilities: Set<String> = []
    private var messageOfTheDay = ""

    init(nickname: String, password: String?) {
        self.nickname = nickname
        self.password = password
    }

    /// The messages that start registration, to send as soon as the connection is up.
    /// `CAP LS` comes first, so a server that supports capabilities holds registration
    /// until we end negotiation; one that doesn't simply ignores it.
    func registrationMessages() -> [IRCMessage] {
        var messages = [IRCMessage.capabilityList()]
        if let password, !password.isEmpty { messages.append(.pass(password)) }
        messages.append(.nick(nickname))
        messages.append(.user(nickname, realName: nickname))
        return messages
    }

    /// Interprets one message from the server.
    mutating func handle(_ message: IRCMessage) -> Output {
        let parameters = message.parameters
        let sender = message.source?.nick

        switch message.command {
        case "PING":
            return Output(replies: [.pong(parameters.last ?? "")])
        case "PONG":
            return Output(events: [.pong])
        case "CAP":
            return Output(replies: negotiateCapabilities(parameters))

        case "001": // RPL_WELCOME <nick> :<text>
            guard !isRegistered else { return Output() }
            isRegistered = true
            isNegotiatingCapabilities = false
            nickname = parameters.first ?? nickname
            return Output(events: [.registered(nickname: nickname)])
        case "432", "433", "436", "437", // bad nickname: erroneous, in use, collision, unavailable
             "463", "464", "465":        // not allowed: host, password, banned
            guard !isRegistered else { return Output() }
            return Output(events: [.registrationFailed(reason: parameters.last ?? message.command)])

        case "375": // RPL_MOTDSTART
            messageOfTheDay = (parameters.last ?? "") + "\n"
            return Output()
        case "372": // RPL_MOTD
            messageOfTheDay += (parameters.last ?? "") + "\n"
            return Output()
        case "376": // RPL_ENDOFMOTD
            defer { messageOfTheDay = "" }
            return Output(events: messageOfTheDay.isEmpty ? [] : [.messageOfTheDay(messageOfTheDay)])

        case "NICK":
            guard let sender, let newNick = parameters.first else { return Output() }
            guard isSelf(sender) else { return Output(events: [.nickChanged(from: sender, to: newNick)]) }
            nickname = newNick
            return Output(events: [.nicknameChanged(newNick)])
        case "JOIN":
            guard let sender, let channels = parameters.first else { return Output() }
            return Output(events: channels.split(separator: ",").map {
                .joined(channel: String($0), nick: sender, isSelf: isSelf(sender))
            })
        case "PART":
            guard let sender, let channels = parameters.first else { return Output() }
            return Output(events: channels.split(separator: ",").map {
                .parted(channel: String($0), nick: sender, isSelf: isSelf(sender))
            })
        case "QUIT":
            guard let sender else { return Output() }
            return Output(events: [.quit(nick: sender, reason: parameters.first)])
        case "KICK": // KICK <channel> <nick> [:<reason>]
            guard parameters.count >= 2 else { return Output() }
            let reason = parameters.count > 2 && !parameters[2].isEmpty ? parameters[2] : nil
            return Output(events: [.kicked(channel: parameters[0], nick: parameters[1], kicker: sender,
                                           reason: reason, isSelf: isSelf(parameters[1]))])

        case "PRIVMSG":
            guard let sender, parameters.count >= 2 else { return Output() }
            if let ctcp = CTCPMessage(parsing: parameters[1]) {
                return handleCTCP(ctcp, from: sender, to: parameters[0], time: message.serverTime)
            }
            let event = messageEvent(from: sender, to: parameters[0], text: parameters[1], time: message.serverTime)
            return Output(events: [event].compactMap(\.self))
        case "NOTICE":
            // A CTCP reply: we never send CTCP queries, so there's nothing to match it to.
            guard parameters.count >= 2, CTCPMessage(parsing: parameters[1]) == nil else { return Output() }
            return Output(events: [.notice(text: parameters[1], time: message.serverTime)])

        case "332": // RPL_TOPIC <nick> <channel> :<topic>
            guard parameters.count >= 3 else { return Output() }
            return Output(events: [.topic(channel: parameters[1], topic: parameters[2], setBy: nil)])
        case "TOPIC":
            guard parameters.count >= 2 else { return Output() }
            return Output(events: [.topic(channel: parameters[0], topic: parameters[1], setBy: sender)])
        case "353": // RPL_NAMREPLY <nick> [<symbol>] <channel> :<prefixed nicks>
            guard parameters.count >= 3 else { return Output() }
            let nicks = parameters[parameters.count - 1].split(separator: " ").map {
                String($0.drop { Self.memberStatusPrefixes.contains($0) })
            }
            return Output(events: [.names(channel: parameters[parameters.count - 2], nicks: nicks)])
        case "352": // RPL_WHOREPLY <nick> <channel> <user> <host> <server> <member nick> <flags> :<hops> <real name>
            guard parameters.count >= 6 else { return Output() }
            return Output(events: [.whoReply(channel: parameters[1], nick: parameters[5])])

        default:
            return Output()
        }
    }

    // MARK: - Capability negotiation

    /// Answers the server's side of `CAP <target> <subcommand> [*] [:<capabilities>]`:
    /// requests what we want from the advertised list, then ends negotiation once the
    /// server has answered the request (or there's nothing to request).
    private mutating func negotiateCapabilities(_ parameters: [String]) -> [IRCMessage] {
        guard isNegotiatingCapabilities, parameters.count >= 2 else { return [] }
        switch parameters[1].uppercased() {
        case "LS":
            // `name` or `name=value`, possibly spread over several lines.
            let advertised = parameters.count > 2 ? parameters[parameters.count - 1] : ""
            offeredCapabilities.formUnion(advertised.split(separator: " ").map { String($0.prefix { $0 != "=" }) })
            let isContinued = parameters.count > 3 && parameters[2] == "*"
            guard !isContinued else { return [] }
            let wanted = Self.capabilitiesToRequest(from: offeredCapabilities)
            guard !wanted.isEmpty else {
                isNegotiatingCapabilities = false
                return [.capabilityEnd()]
            }
            return [.capabilityRequest(wanted)]
        case "ACK", "NAK":
            isNegotiatingCapabilities = false
            return [.capabilityEnd()]
        default:
            return []
        }
    }

    /// Timestamps for replayed history (`server-time`, or ZNC's older name for it), and the
    /// private messages we send from our other clients on the same bouncer
    /// (`znc.in/self-message`). Not `echo-message`: the app shows its own lines as it sends them.
    private static func capabilitiesToRequest(from offered: Set<String>) -> [String] {
        let serverTime = ["server-time", "znc.in/server-time-iso"].first(where: offered.contains)
        let selfMessage = offered.contains("znc.in/self-message") ? "znc.in/self-message" : nil
        return [serverTime, selfMessage].compactMap(\.self)
    }

    // MARK: - CTCP

    /// Implements exactly the CTCP messages the spec makes mandatory: shows ACTIONs (`/me`)
    /// and answers VERSION and PING. Everything else, including what the spec only
    /// recommends (TIME, CLIENTINFO), is ignored without a reply. Queries a bouncer relays
    /// from our own other clients aren't ours to answer.
    private func handleCTCP(_ ctcp: CTCPMessage, from sender: String, to target: String, time: Date?) -> Output {
        switch ctcp.command {
        case "ACTION":
            let event = messageEvent(from: sender, to: target, text: ctcp.parameters ?? "", isAction: true, time: time)
            return Output(events: [event].compactMap(\.self))
        case "VERSION" where !isSelf(sender):
            return Output(replies: [.ctcpReply(to: sender, CTCPMessage(command: "VERSION", parameters: Self.version))])
        case "PING" where !isSelf(sender):
            return Output(replies: [.ctcpReply(to: sender, ctcp)])   // the spec wants the parameters back unchanged
        default:
            return Output()
        }
    }

    /// Our answer to CTCP VERSION.
    private static let version = "IRC Client"

    // MARK: - Helpers

    private func isSelf(_ nick: String) -> Bool {
        IRCName.equal(nick, nickname)
    }

    /// Sorts a PRIVMSG into its conversation: a channel, or a private chat with `peer`. A
    /// private message between two other people (which the server never sends) is dropped.
    private func messageEvent(from sender: String, to target: String, text: String, isAction: Bool = false, time: Date?) -> IRCEvent? {
        if IRCName.isChannel(target) {
            .channelMessage(channel: target, sender: sender, text: text, isAction: isAction, isOwn: isSelf(sender), time: time)
        } else if isSelf(target) {
            .privateMessage(peer: sender, sender: sender, text: text, isAction: isAction, isOwn: false, time: time)
        } else if isSelf(sender) {
            .privateMessage(peer: target, sender: sender, text: text, isAction: isAction, isOwn: true, time: time)
        } else {
            nil
        }
    }

    /// Channel-member status prefixes in RPL_NAMREPLY: owner, admin, op, half-op, voice.
    private static let memberStatusPrefixes: Set<Character> = ["~", "&", "@", "%", "+"]
}
