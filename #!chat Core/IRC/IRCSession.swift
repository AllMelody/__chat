import Foundation

/// The IRC protocol for one connection, as a state machine with no I/O: hand it each message
/// from the server and it returns the replies to send and the events to report.
///
/// It registers (RFC 2812 §3.1) after negotiating IRCv3 capabilities (CAP 302) and, when asked
/// to, logging in with SASL PLAIN; answers PINGs and the mandatory CTCP queries; tracks our
/// nickname; and turns server messages into `IRCEvent`s.
nonisolated struct IRCSession {
    /// What handling one message produced.
    struct Output: Equatable {
        var replies: [IRCMessage] = []
        var events: [IRCEvent] = []
    }

    /// Our nickname: the one we asked for until the server confirms or changes it.
    private(set) var nickname: String
    private(set) var isRegistered = false
    /// Why the server is closing the connection, once it has said so (its ERROR message).
    private(set) var closingReason: String?

    private let preferredNickname: String
    private let password: String?
    /// The password is our account's, to log in with over SASL, and not the server's.
    private let usesSASL: Bool
    private var isNegotiatingCapabilities = true
    /// What the server offers, by name, with the value it gave (`sasl=PLAIN,EXTERNAL`) or "".
    private var offeredCapabilities: [String: String] = [:]
    /// We've named our SASL mechanism and the exchange isn't over.
    private var isAuthenticating = false
    private var isAuthenticated = false
    private var nicknameFallbacks = 0
    /// Channel-member statuses the server lets messages target, like `@` in `@#chan`
    /// (ISUPPORT STATUSMSG). None until the server advertises some.
    private var statusMessagePrefixes: Set<Character> = []
    private var messageOfTheDay = ""
    /// The server has finished greeting us: what it says from here on answers something.
    private var hasBeenGreeted = false
    /// Members collected so far for channels whose NAMES reply is still arriving.
    private var pendingNames: [String: [String]] = [:]

    init(nickname: String, password: String?, usesSASL: Bool = false) {
        self.nickname = nickname
        self.preferredNickname = nickname
        self.password = password
        self.usesSASL = usesSASL
    }

    /// The messages that start registration, to send as soon as the connection is up.
    /// `CAP LS` comes first, so a server that supports capabilities holds registration
    /// until we end negotiation; one that doesn't simply ignores it.
    func registrationMessages() -> [IRCMessage] {
        var messages = [IRCMessage.capabilityList()]
        if let password, !password.isEmpty, !usesSASL { messages.append(.pass(password)) }
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
            return negotiateCapabilities(parameters)
        case "ERROR":
            closingReason = parameters.last
            return Output()

        case "AUTHENTICATE": // `+`: the server is ready for our credentials
            guard isAuthenticating, parameters.first == "+" else { return Output() }
            return Output(replies: IRCMessage.plainAuthentication(account: preferredNickname, password: password ?? ""))
        case "903": // RPL_SASLSUCCESS
            guard isAuthenticating else { return Output() }
            isAuthenticating = false
            isAuthenticated = true
            isNegotiatingCapabilities = false
            return Output(replies: [.capabilityEnd()])
        case "902", "904", "905", "906": // nick locked, wrong credentials, too long, aborted
            guard !isRegistered else { return otherReply(message) }
            return registrationFailure(parameters.last ?? "SASL authentication failed")

        case "001": // RPL_WELCOME <nick> :<text>
            guard !isRegistered else {
                // A bouncer that reconnected to its server passes on that server's greeting.
                hasBeenGreeted = false
                return Output()
            }
            // A server without capabilities never gave us the chance to log in.
            guard !usesSASL || isAuthenticated else { return registrationFailure(Self.noSASL) }
            isRegistered = true
            isNegotiatingCapabilities = false
            nickname = parameters.first ?? nickname
            return Output(events: [.registered(nickname: nickname)])
        case "433", "436", "437": // nickname in use, collision, temporarily unavailable
            guard !isRegistered else { return errorReply(message) }
            // Fall back to nick_, nick__, nick___ before giving up.
            guard nicknameFallbacks < Self.maximumNicknameFallbacks else {
                return registrationFailure(parameters.last ?? message.command)
            }
            nicknameFallbacks += 1
            nickname = preferredNickname + String(repeating: "_", count: nicknameFallbacks)
            return Output(replies: [.nick(nickname)])
        case "432",               // erroneous nickname: no variation of it will do
             "463", "464", "465": // not allowed: host, password, banned
            guard !isRegistered else { return errorReply(message) }
            return registrationFailure(parameters.last ?? message.command)
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
            hasBeenGreeted = true
            return Output(events: messageOfTheDay.isEmpty ? [] : [.messageOfTheDay(messageOfTheDay)])

        case "NICK":
            guard let sender, let newNick = parameters.first else { return Output() }
            guard isSelf(sender) else { return Output(events: [.nickChanged(from: sender, to: newNick)]) }
            nickname = newNick
            return Output(events: [.nicknameChanged(newNick)])
        case "JOIN":
            guard let sender, let channels = parameters.first else { return Output() }
            // Some servers and bouncers send no message of the day; in a channel, the greeting is over.
            if isSelf(sender) { hasBeenGreeted = true }
            return Output(events: channels.split(separator: ",").map {
                .joined(channel: String($0), nick: sender, isSelf: isSelf(sender))
            })
        case "PART": // PART <channels> [:<reason>]
            guard let sender, let channels = parameters.first else { return Output() }
            let reason = parameters.count > 1 && !parameters[1].isEmpty ? parameters[1] : nil
            return Output(events: channels.split(separator: ",").map {
                .parted(channel: String($0), nick: sender, reason: reason, isSelf: isSelf(sender))
            })
        case "QUIT":
            guard let sender else { return Output() }
            return Output(events: [.quit(nick: sender, reason: parameters.first)])
        case "KICK": // KICK <channel> <nick> [:<reason>]
            guard parameters.count >= 2 else { return Output() }
            let reason = parameters.count > 2 && !parameters[2].isEmpty ? parameters[2] : nil
            return Output(events: [.kicked(channel: parameters[0], nick: parameters[1], kicker: sender,
                                           reason: reason, isSelf: isSelf(parameters[1]))])
        case "MODE": // MODE <channel or nick> <changes> [<arguments>…]
            guard parameters.count >= 2 else { return Output() }
            return Output(events: [.modeChanged(target: parameters[0], modes: parameters.dropFirst().joined(separator: " "),
                                                setter: sender)])
        case "INVITE": // INVITE <nick> <channel>
            guard let sender, parameters.count >= 2, isSelf(parameters[0]) else { return Output() }
            return Output(events: [.invited(channel: parameters[1], sender: sender)])

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
            let channel = statusMessageTarget(parameters[0])?.channel ?? (IRCName.isChannel(parameters[0]) ? parameters[0] : nil)
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

        case "301": // RPL_AWAY <nick> <who> :<their away message>
            guard parameters.count >= 3 else { return otherReply(message) }
            return Output(events: [.reply(arguments: [parameters[1], "is away: \(parameters[2])"], isGreeting: false)])
        case "341": // RPL_INVITING <nick> <who> <channel>
            guard parameters.count >= 3 else { return otherReply(message) }
            return Output(events: [.reply(arguments: [parameters[1], "has been invited to \(parameters[2])"], isGreeting: false)])

        default:
            guard message.command.count == 3, let code = Int(message.command) else { return Output() }
            // 4xx and 5xx numerics are error replies (RFC 2812 §5.2). Before registration
            // they're only answers to things like CAP on servers without it.
            guard (400...599).contains(code) else { return otherReply(message) }
            return isRegistered ? errorReply(message) : Output()
        }
    }

    /// The server refused something we sent: `<nick> [<subject>] :<explanation>`.
    private func errorReply(_ message: IRCMessage) -> Output {
        let parameters = message.parameters
        let subject = parameters.count > 2 ? parameters[1] : nil
        let text = parameters.count > 1 ? parameters[parameters.count - 1] : message.command
        return Output(events: [.errorReply(subject: subject, text: text)])
    }

    /// A numeric reply with no handling of its own, `<nick> <argument>… [:<text>]`: reported
    /// as it reads, so that commands like WHOIS have somewhere to answer.
    private func otherReply(_ message: IRCMessage) -> Output {
        guard !Self.unshownReplies.contains(message.command), message.parameters.count > 1 else { return Output() }
        let arguments = Self.repliesSaidInTheirText.contains(message.command)
            ? message.parameters.suffix(1)
            : message.parameters.dropFirst()
        return Output(events: [.reply(arguments: Array(arguments), isGreeting: !hasBeenGreeted)])
    }

    private func registrationFailure(_ reason: String) -> Output {
        Output(events: [.registrationFailed(reason: reason)])
    }

    /// Replies with nothing in them for a person: which mode letters the server knows (004),
    /// and when a channel was created (329) or its topic set (333), as raw timestamps.
    private static let unshownReplies: Set<String> = ["004", "329", "333"]
    /// Replies whose arguments only repeat, as bare values, what the text after them says:
    /// user counts (250, 265, 266), and the account we've logged in to (900).
    private static let repliesSaidInTheirText: Set<String> = ["250", "265", "266", "900"]

    // MARK: - Capability negotiation

    /// Answers the server's side of `CAP <target> <subcommand> [*] [:<capabilities>]`:
    /// requests what we want from the advertised list, then ends negotiation once the
    /// server has answered the request (or there's nothing to request). With SASL, logging
    /// in comes between the two, and registration fails where it can't happen.
    private mutating func negotiateCapabilities(_ parameters: [String]) -> Output {
        guard isNegotiatingCapabilities, parameters.count >= 2 else { return Output() }
        switch parameters[1].uppercased() {
        case "LS":
            // `name` or `name=value`, possibly spread over several lines.
            let advertised = parameters.count > 2 ? parameters[parameters.count - 1] : ""
            for capability in advertised.split(separator: " ") {
                let name = capability.prefix { $0 != "=" }
                offeredCapabilities[String(name)] = String(capability.dropFirst(name.count + 1))
            }
            let isContinued = parameters.count > 3 && parameters[2] == "*"
            guard !isContinued else { return Output() }
            if usesSASL, !isOfferedPlainSASL { return registrationFailure(Self.noSASL) }
            let wanted = capabilitiesToRequest()
            guard !wanted.isEmpty else { return endNegotiation() }
            return Output(replies: [.capabilityRequest(wanted)])
        case "ACK":
            guard usesSASL else { return endNegotiation() }
            guard parameters[parameters.count - 1].split(separator: " ").contains("sasl") else {
                return registrationFailure(Self.noSASL)
            }
            isAuthenticating = true
            return Output(replies: [.authenticate("PLAIN")])
        case "NAK":
            return usesSASL ? registrationFailure(Self.noSASL) : endNegotiation()
        default:
            return Output()
        }
    }

    private mutating func endNegotiation() -> Output {
        isNegotiatingCapabilities = false
        return Output(replies: [.capabilityEnd()])
    }

    /// Timestamps for replayed history (`server-time`, or ZNC's older name for it), the
    /// private messages we send from our other clients on the same bouncer
    /// (`znc.in/self-message`), and `sasl` when we're to log in with it. Not `echo-message`:
    /// the app shows its own lines as it sends them.
    private func capabilitiesToRequest() -> [String] {
        let serverTime = ["server-time", "znc.in/server-time-iso"].first { offeredCapabilities[$0] != nil }
        let selfMessage = offeredCapabilities["znc.in/self-message"] != nil ? "znc.in/self-message" : nil
        return [serverTime, selfMessage, usesSASL ? "sasl" : nil].compactMap(\.self)
    }

    /// Whether the server offers SASL with the PLAIN mechanism. Servers that don't list
    /// their mechanisms (CAP before 3.2) are taken at their word.
    private var isOfferedPlainSASL: Bool {
        guard let mechanisms = offeredCapabilities["sasl"] else { return false }
        return mechanisms.isEmpty || mechanisms.split(separator: ",").contains { $0.uppercased() == "PLAIN" }
    }

    private static let noSASL = "The server doesn't offer SASL PLAIN authentication"

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
