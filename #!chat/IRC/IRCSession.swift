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

    private let preferredNickname: String
    private let password: String?
    private var isNegotiatingCapabilities = true
    private var offeredCapabilities: Set<String> = []
    private var nicknameFallbacks = 0
    /// Channel-member statuses the server lets messages target, like `@` in `@#chan`
    /// (ISUPPORT STATUSMSG). None until the server advertises some.
    private var statusMessagePrefixes: Set<Character> = []
    private var messageOfTheDay = ""
    /// Members collected so far for channels whose NAMES reply is still arriving.
    private var pendingNames: [String: [String]] = [:]

    init(nickname: String, password: String?) {
        self.nickname = nickname
        self.preferredNickname = nickname
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
        case "433", "436", "437": // nickname in use, collision, temporarily unavailable
            guard !isRegistered else { return errorReply(message) }
            // Fall back to nick_, nick__, nick___ before giving up.
            guard nicknameFallbacks < Self.maximumNicknameFallbacks else {
                return Output(events: [.registrationFailed(reason: parameters.last ?? message.command)])
            }
            nicknameFallbacks += 1
            nickname = preferredNickname + String(repeating: "_", count: nicknameFallbacks)
            return Output(replies: [.nick(nickname)])
        case "432",               // erroneous nickname: no variation of it will do
             "463", "464", "465": // not allowed: host, password, banned
            guard !isRegistered else { return errorReply(message) }
            return Output(events: [.registrationFailed(reason: parameters.last ?? message.command)])
        case "005": // RPL_ISUPPORT <nick> <token>… :are supported by this server
            for token in parameters.dropFirst().dropLast() {
                if token.hasPrefix("STATUSMSG=") { statusMessagePrefixes = Set(token.dropFirst("STATUSMSG=".count)) }
                if token == "-STATUSMSG" { statusMessagePrefixes = [] }
            }
            return Output()

        case "375": // RPL_MOTDSTART
            messageOfTheDay = (parameters.last ?? "") + "\n"
            return Output()
        case "372": // RPL_MOTD
            messageOfTheDay += (parameters.last ?? "") + "\n"
            return Output()
        case "376", "422": // RPL_ENDOFMOTD, or ERR_NOMOTD, which is routine rather than an error
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
            let channel = IRCName.isChannel(parameters[0]) ? parameters[0] : nil
            return Output(events: [.notice(sender: sender, channel: channel, text: parameters[1], time: message.serverTime)])

        case "332": // RPL_TOPIC <nick> <channel> :<topic>
            guard parameters.count >= 3 else { return Output() }
            return Output(events: [.topic(channel: parameters[1], topic: parameters[2], setBy: nil)])
        case "TOPIC":
            guard parameters.count >= 2 else { return Output() }
            return Output(events: [.topic(channel: parameters[0], topic: parameters[1], setBy: sender)])
        case "353": // RPL_NAMREPLY <nick> [<symbol>] <channel> :<prefixed nicks>
            guard parameters.count >= 3 else { return Output() }
            let nicks = parameters[parameters.count - 1].split(separator: " ")
                .map { String($0.drop { Self.memberStatusPrefixes.contains($0) }) }
                .filter { !$0.isEmpty }
            pendingNames[parameters[parameters.count - 2], default: []] += nicks
            return Output()
        case "366": // RPL_ENDOFNAMES <nick> <channel> :End of /NAMES list
            guard parameters.count >= 2 else { return Output() }
            let channel = parameters[1]
            return Output(events: [.names(channel: channel, nicks: pendingNames.removeValue(forKey: channel) ?? [])])

        default:
            // Other 4xx and 5xx numerics are error replies too (RFC 2812 §5.2). Before
            // registration they're only answers to things like CAP on servers without it.
            guard isRegistered, let code = Int(message.command), (400...599).contains(code) else { return Output() }
            return errorReply(message)
        }
    }

    /// The server refused something we sent: `<nick> [<subject>] :<explanation>`.
    private func errorReply(_ message: IRCMessage) -> Output {
        let parameters = message.parameters
        let subject = parameters.count > 2 ? parameters[1] : nil
        let text = parameters.count > 1 ? parameters[parameters.count - 1] : message.command
        return Output(events: [.errorReply(subject: subject, text: text)])
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

    /// Sorts a PRIVMSG into its conversation: a channel (possibly addressed to some of its
    /// members only, like `@#chan`), or a private chat with `peer`. A private message between
    /// two other people (which the server never sends) is dropped.
    private func messageEvent(from sender: String, to target: String, text: String, isAction: Bool = false, time: Date?) -> IRCEvent? {
        var message = IRCEvent.Message(sender: sender, text: text, isAction: isAction, isOwn: isSelf(sender), time: time)
        if let (prefix, channel) = statusMessageTarget(target) {
            message.statusPrefix = prefix
            return .channelMessage(channel: channel, message)
        } else if IRCName.isChannel(target) {
            return .channelMessage(channel: target, message)
        } else if isSelf(target) {
            message.isOwn = false
            return .privateMessage(peer: sender, message)
        } else if isSelf(sender) {
            return .privateMessage(peer: target, message)
        } else {
            return nil
        }
    }

    /// Splits a STATUSMSG target like `@#chan` into its status prefix and channel, when the
    /// server has advertised that prefix.
    private func statusMessageTarget(_ target: String) -> (prefix: Character, channel: String)? {
        guard let prefix = target.first, statusMessagePrefixes.contains(prefix) else { return nil }
        let channel = String(target.dropFirst())
        return IRCName.isChannel(channel) ? (prefix, channel) : nil
    }

    private static let maximumNicknameFallbacks = 3

    /// Channel-member status prefixes in RPL_NAMREPLY: owner, admin, op, half-op, voice.
    private static let memberStatusPrefixes: Set<Character> = ["~", "&", "@", "%", "+"]
}
