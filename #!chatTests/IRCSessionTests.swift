import Foundation
import Testing
@testable import __chat

struct IRCSessionTests {
    /// A session for `alice`, optionally already registered.
    private func session(registered: Bool = true) -> IRCSession {
        var session = IRCSession(nickname: "alice", password: nil)
        if registered { _ = session.handle(line(":srv 001 alice :Welcome")) }
        return session
    }

    private func line(_ text: String) -> IRCMessage {
        IRCMessage(text)!
    }

    // MARK: - Registration

    @Test func `Registration opens with CAP LS, then PASS, NICK and USER`() {
        let withPassword = IRCSession(nickname: "alice", password: "secret")
        #expect(withPassword.registrationMessages().map(\.wireFormat) ==
                ["CAP LS 302", "PASS secret", "NICK alice", "USER alice 0 * alice"])

        let withoutPassword = IRCSession(nickname: "alice", password: "")
        #expect(withoutPassword.registrationMessages().map(\.wireFormat) ==
                ["CAP LS 302", "NICK alice", "USER alice 0 * alice"])
    }

    @Test func `Welcome registers under the nickname the server confirms`() {
        var session = session(registered: false)
        #expect(!session.isRegistered)
        #expect(session.handle(line(":srv 001 alice_ :Welcome")).events == [.registered(nickname: "alice_")])
        #expect(session.isRegistered)
        #expect(session.nickname == "alice_")
        #expect(session.handle(line(":srv 001 alice_ :Welcome")).events == [])   // only once
    }

    @Test(arguments: ["432", "463", "464", "465"])
    func `Rejections before registration fail it`(numeric: String) {
        var session = session(registered: false)
        #expect(session.handle(line(":srv \(numeric) * alice :Nope")).events == [.registrationFailed(reason: "Nope")])
    }

    @Test(arguments: ["433", "436", "437"])
    func `A taken nickname falls back to nick_ up to three times`(numeric: String) {
        var session = session(registered: false)
        for fallback in ["alice_", "alice__", "alice___"] {
            #expect(session.handle(line(":srv \(numeric) * \(session.nickname) :Taken")) == .init(replies: [.nick(fallback)]))
            #expect(session.nickname == fallback)
        }
        #expect(session.handle(line(":srv \(numeric) * alice___ :Taken")).events == [.registrationFailed(reason: "Taken")])
    }

    @Test func `Registers under the fallback nickname`() {
        var session = session(registered: false)
        _ = session.handle(line(":srv 433 * alice :Nickname is already in use"))
        #expect(session.handle(line(":srv 001 alice_ :Welcome")).events == [.registered(nickname: "alice_")])
        #expect(session.handle(line(":bob!u@h PRIVMSG alice_ :hi")).events ==
                [.privateMessage(peer: "bob", .init(sender: "bob", text: "hi"))])
    }

    @Test func `After registration, a taken nickname is only an error reply`() {
        var session = session()
        #expect(session.handle(line(":srv 433 alice bob :Nickname is already in use")) ==
                .init(events: [.errorReply(subject: "bob", text: "Nickname is already in use")]))
    }

    @Test(arguments: [
        (":srv 404 alice #swift :Cannot send to channel", IRCEvent.errorReply(subject: "#swift", text: "Cannot send to channel")),
        (":srv 401 alice bob :No such nick/channel", .errorReply(subject: "bob", text: "No such nick/channel")),
        (":srv 481 alice :Permission Denied", .errorReply(subject: nil, text: "Permission Denied")),
    ])
    func `Error replies say what was refused and why`(reply: String, event: IRCEvent) {
        var session = session()
        #expect(session.handle(line(reply)).events == [event])
    }

    @Test(arguments: ["421 * CAP :Unknown command", "451 * :You have not registered", "461 CAP :Not enough parameters"])
    func `Servers that don't speak CAP still register`(reply: String) {
        var session = session(registered: false)
        #expect(session.handle(line(":srv \(reply)")) == .init())
        #expect(session.handle(line(":srv 001 alice :Welcome")).events == [.registered(nickname: "alice")])
    }

    // MARK: - SASL

    /// A session that is to log `alice` in with SASL.
    private func saslSession() -> IRCSession {
        IRCSession(nickname: "alice", password: "secret", usesSASL: true)
    }

    private static let noSASL = IRCEvent.registrationFailed(reason: "The server doesn't offer SASL PLAIN authentication")

    @Test func `With SASL, the password isn't sent as the server's`() {
        #expect(saslSession().registrationMessages().map(\.wireFormat) == ["CAP LS 302", "NICK alice", "USER alice 0 * alice"])
    }

    @Test func `Logs in with SASL PLAIN before ending negotiation`() {
        var session = saslSession()
        #expect(session.handle(line(":srv CAP * LS :sasl=PLAIN,EXTERNAL server-time")).replies.map(\.wireFormat) ==
                ["CAP REQ :server-time sasl"])
        #expect(session.handle(line(":srv CAP * ACK :server-time sasl")).replies.map(\.wireFormat) == ["AUTHENTICATE PLAIN"])
        // base64 of "alice\0alice\0secret"
        #expect(session.handle(line("AUTHENTICATE +")).replies.map(\.wireFormat) == ["AUTHENTICATE YWxpY2UAYWxpY2UAc2VjcmV0"])
        #expect(session.handle(line(":srv 900 alice alice!u@h alice :You are now logged in as alice")).events ==
                [.reply(arguments: ["You are now logged in as alice"], isGreeting: true)])
        #expect(session.handle(line(":srv 903 alice :SASL authentication successful")).replies.map(\.wireFormat) == ["CAP END"])
        #expect(session.handle(line(":srv 001 alice :Welcome")).events == [.registered(nickname: "alice")])
    }

    @Test func `Logs in to the account's name even under a fallback nickname`() {
        var session = saslSession()
        _ = session.handle(line(":srv CAP * LS :sasl"))   // no mechanisms listed: taken at its word
        _ = session.handle(line(":srv 433 * alice :Nickname is already in use"))
        #expect(session.nickname == "alice_")
        _ = session.handle(line(":srv CAP * ACK :sasl"))
        #expect(session.handle(line("AUTHENTICATE +")).replies.map(\.wireFormat) == ["AUTHENTICATE YWxpY2UAYWxpY2UAc2VjcmV0"])
    }

    @Test(arguments: ["902", "904", "905", "906"])
    func `A refused login fails registration`(numeric: String) {
        var session = saslSession()
        _ = session.handle(line(":srv CAP * LS :sasl=PLAIN"))
        _ = session.handle(line(":srv CAP * ACK :sasl"))
        _ = session.handle(line("AUTHENTICATE +"))
        #expect(session.handle(line(":srv \(numeric) alice :SASL authentication failed")).events ==
                [.registrationFailed(reason: "SASL authentication failed")])
    }

    @Test(arguments: ["CAP * LS :server-time multi-prefix", "CAP * LS :sasl=EXTERNAL,SCRAM-SHA-256", "001 alice :Welcome"])
    func `Registration fails where SASL PLAIN isn't offered`(reply: String) {
        var session = saslSession()
        #expect(session.handle(line(":srv \(reply)")) == .init(events: [Self.noSASL]))
        #expect(!session.isRegistered)
    }

    @Test func `A refused capability request fails a SASL login too`() {
        var session = saslSession()
        _ = session.handle(line(":srv CAP * LS :sasl"))
        #expect(session.handle(line(":srv CAP * NAK :sasl")) == .init(events: [Self.noSASL]))
    }

    @Test func `Without SASL, an offer of it is left alone`() {
        var session = IRCSession(nickname: "alice", password: "secret")
        #expect(session.handle(line(":srv CAP * LS :sasl=PLAIN server-time")).replies.map(\.wireFormat) == ["CAP REQ server-time"])
        #expect(session.handle(line("AUTHENTICATE +")) == .init())
    }

    @Test func `Long credentials go out in pieces of 400 characters`() {
        // 300 bytes of credentials make exactly 400 characters of base64: a lone + says that was all.
        let exact = IRCMessage.plainAuthentication(account: "a", password: String(repeating: "x", count: 296))
        #expect(exact.map { $0.parameters[0].count } == [400, 1])
        #expect(exact.last?.wireFormat == "AUTHENTICATE +")

        let longer = IRCMessage.plainAuthentication(account: "a", password: String(repeating: "x", count: 297))
        #expect(longer.map { $0.parameters[0].count } == [400, 4])
    }

    // MARK: - Capability negotiation

    @Test func `Requests wanted capabilities, then ends negotiation on ACK`() {
        var session = session(registered: false)
        let ls = session.handle(line(":srv CAP * LS :multi-prefix sasl=PLAIN,EXTERNAL server-time znc.in/self-message"))
        #expect(ls.replies.map(\.wireFormat) == ["CAP REQ :server-time znc.in/self-message"])
        #expect(session.handle(line(":srv CAP * ACK :server-time znc.in/self-message")).replies.map(\.wireFormat) == ["CAP END"])
    }

    @Test func `NAK also ends negotiation`() {
        var session = session(registered: false)
        _ = session.handle(line(":srv CAP * LS :server-time"))
        #expect(session.handle(line(":srv CAP * NAK :server-time")).replies.map(\.wireFormat) == ["CAP END"])
    }

    @Test func `Falls back to ZNC's server-time capability`() {
        var session = session(registered: false)
        #expect(session.handle(line(":srv CAP * LS :znc.in/server-time-iso")).replies.map(\.wireFormat) ==
                ["CAP REQ znc.in/server-time-iso"])
    }

    @Test func `Ends negotiation at once when nothing is wanted`() {
        var session = session(registered: false)
        #expect(session.handle(line(":srv CAP * LS :multi-prefix sasl")).replies.map(\.wireFormat) == ["CAP END"])
        #expect(session.handle(line(":srv CAP * LS :server-time")) == .init())   // negotiation is over
    }

    @Test func `Waits for the last line of a multi-line LS`() {
        var session = session(registered: false)
        #expect(session.handle(line(":srv CAP * LS * :multi-prefix sasl")) == .init())
        #expect(session.handle(line(":srv CAP * LS :znc.in/self-message server-time")).replies.map(\.wireFormat) ==
                ["CAP REQ :server-time znc.in/self-message"])
    }

    @Test func `A nickname that looks like a subcommand doesn't confuse CAP`() {
        var session = IRCSession(nickname: "LS", password: nil)
        #expect(session.handle(line(":srv CAP LS LS :server-time")).replies.map(\.wireFormat) == ["CAP REQ server-time"])
    }

    @Test(arguments: ["CAP alice NEW :sasl", "CAP alice DEL :sasl", "CAP alice ACK :away-notify"])
    func `CAP after negotiation is ignored`(text: String) {
        var session = session()
        #expect(session.handle(line(":srv \(text)")) == .init())
    }

    // MARK: - Keep-alive

    @Test(arguments: [
        ("PING :irc.example.net", "PONG irc.example.net"),
        ("PING :token with space", "PONG :token with space"),
        ("PING srv1 :token", "PONG token"),
    ])
    func `Answers PING with the token`(ping: String, pong: String) {
        var session = session(registered: false)
        #expect(session.handle(line(ping)).replies.map(\.wireFormat) == [pong])
    }

    @Test func `Reports PONG`() {
        var session = session()
        #expect(session.handle(line(":srv PONG srv :1759500000.123")).events == [.pong])
    }

    @Test func `Remembers why the server is closing the connection`() {
        var session = session()
        #expect(session.closingReason == nil)
        #expect(session.handle(line("ERROR :Closing Link: 203.0.113.7 (Excess Flood)")) == .init())
        #expect(session.closingReason == "Closing Link: 203.0.113.7 (Excess Flood)")
    }

    // MARK: - Other replies

    @Test func `What the server says in greeting is told apart from answers`() {
        var session = session()
        #expect(session.handle(line(":srv 002 alice :Your host is srv")).events ==
                [.reply(arguments: ["Your host is srv"], isGreeting: true)])
        #expect(session.handle(line(":srv 252 alice 34 :IRC Operators online")).events ==
                [.reply(arguments: ["34", "IRC Operators online"], isGreeting: true)])
        // The numbers in front only repeat what the text says.
        #expect(session.handle(line(":srv 265 alice 30 40 :Current local users 30, max 40")).events ==
                [.reply(arguments: ["Current local users 30, max 40"], isGreeting: true)])

        _ = session.handle(line(":srv 376 alice :End of /MOTD command."))
        #expect(session.handle(line(":srv 311 alice bob ~b host.example * :Bob Real")).events ==
                [.reply(arguments: ["bob", "~b", "host.example", "*", "Bob Real"], isGreeting: false)])
        #expect(session.handle(line(":srv 331 alice #swift :No topic is set.")).events ==
                [.reply(arguments: ["#swift", "No topic is set."], isGreeting: false)])
    }

    @Test func `Without a message of the day, being in a channel ends the greeting`() {
        var session = session()
        _ = session.handle(line(":alice!u@h JOIN #swift"))
        #expect(session.handle(line(":srv 324 alice #swift +nt")).events ==
                [.reply(arguments: ["#swift", "+nt"], isGreeting: false)])
    }

    @Test func `A bouncer passing on a new greeting from its server starts one again`() {
        var session = session()
        _ = session.handle(line(":srv 376 alice :End of /MOTD command."))
        #expect(session.handle(line(":srv 001 alice :Welcome back")) == .init())   // we're registered already
        #expect(session.handle(line(":srv 251 alice :There are 4 users")).events ==
                [.reply(arguments: ["There are 4 users"], isGreeting: true)])
        _ = session.handle(line(":srv 422 alice :MOTD File is missing"))
        #expect(session.handle(line(":srv 305 alice :You are no longer marked as being away")).events ==
                [.reply(arguments: ["You are no longer marked as being away"], isGreeting: false)])
    }

    @Test func `Away and invitation replies read as sentences`() {
        var session = session()
        #expect(session.handle(line(":srv 301 alice bob :gone fishing")).events ==
                [.reply(arguments: ["bob", "is away: gone fishing"], isGreeting: false)])
        #expect(session.handle(line(":srv 341 alice bob #swift")).events ==
                [.reply(arguments: ["bob", "has been invited to #swift"], isGreeting: false)])
    }

    @Test(arguments: [
        "004 alice srv ircd-1.0 iow biklmnopstv",   // mode letters the server knows
        "329 alice #swift 1700000000",              // when the channel was created
        "333 alice #swift bob!u@h 1700000000",      // who set the topic, and when
        "305 alice",                                // nothing after our nickname
    ])
    func `Replies with nothing to read are dropped`(reply: String) {
        var session = session()
        #expect(session.handle(line(":srv \(reply)")) == .init())
    }

    @Test func `Mode changes on channels and on us`() {
        var session = session()
        #expect(session.handle(line(":op!u@h MODE #swift +o-v bob carol")).events ==
                [.modeChanged(target: "#swift", modes: "+o-v bob carol", setter: "op")])
        #expect(session.handle(line(":alice MODE alice :+iw")).events ==
                [.modeChanged(target: "alice", modes: "+iw", setter: "alice")])
    }

    @Test func `Invitations to us`() {
        var session = session()
        #expect(session.handle(line(":bob!u@h INVITE Alice #swift")).events == [.invited(channel: "#swift", sender: "bob")])
        #expect(session.handle(line(":bob!u@h INVITE carol #swift")) == .init())   // someone else's
    }

    // MARK: - Message of the day

    @Test func `Collects the message of the day`() {
        var session = session()
        _ = session.handle(line(":srv 375 alice :- srv Message of the Day -"))
        _ = session.handle(line(":srv 372 alice :- Hello"))
        _ = session.handle(line(":srv 372 alice :- World"))
        #expect(session.handle(line(":srv 376 alice :End of /MOTD command.")).events ==
                [.messageOfTheDay("- srv Message of the Day -\n- Hello\n- World\n")])
        #expect(session.handle(line(":srv 376 alice :End of /MOTD command.")).events == [])   // buffer was reset
    }

    @Test func `No MOTD means no event`() {
        var session = session()
        #expect(session.handle(line(":srv 422 alice :MOTD File is missing")) == .init())
    }

    // MARK: - Nicknames

    @Test func `Own nick change, including a change of case`() {
        var session = session()
        #expect(session.handle(line(":alice!u@h NICK :alice2")).events == [.nicknameChanged("alice2")])
        #expect(session.handle(line(":ALICE2!u@h NICK :Alice2")).events == [.nicknameChanged("Alice2")])
        #expect(session.nickname == "Alice2")
    }

    @Test func `Someone else's nick change`() {
        var session = session()
        #expect(session.handle(line(":bob!u@h NICK bobby")).events == [.nickChanged(from: "bob", to: "bobby")])
        #expect(session.nickname == "alice")
    }

    // MARK: - Channels

    @Test func `Joins and parts, ours and others'`() {
        var session = session()
        #expect(session.handle(line(":Alice!u@h JOIN #a,#b")).events ==
                [.joined(channel: "#a", nick: "Alice", isSelf: true), .joined(channel: "#b", nick: "Alice", isSelf: true)])
        #expect(session.handle(line(":bob!u@h JOIN #a * :Bob Real")).events ==   // extended-join form
                [.joined(channel: "#a", nick: "bob", isSelf: false)])
        #expect(session.handle(line(":bob!u@h PART #a :bye")).events ==
                [.parted(channel: "#a", nick: "bob", reason: "bye", isSelf: false)])
        #expect(session.handle(line(":alice!u@h PART #b")).events ==
                [.parted(channel: "#b", nick: "alice", reason: nil, isSelf: true)])
    }

    @Test func `Quit with and without a reason`() {
        var session = session()
        #expect(session.handle(line(":bob!u@h QUIT :Ping timeout")).events == [.quit(nick: "bob", reason: "Ping timeout")])
        #expect(session.handle(line(":bob!u@h QUIT")).events == [.quit(nick: "bob", reason: nil)])
    }

    @Test func `Kicks, ours and others'`() {
        var session = session()
        #expect(session.handle(line(":op!u@h KICK #swift Alice :behave")).events ==
                [.kicked(channel: "#swift", nick: "Alice", kicker: "op", reason: "behave", isSelf: true)])
        #expect(session.handle(line(":op!u@h KICK #swift bob :")).events ==
                [.kicked(channel: "#swift", nick: "bob", kicker: "op", reason: nil, isSelf: false)])
    }

    @Test func `Topic on join and topic changes`() {
        var session = session()
        #expect(session.handle(line(":srv 332 alice #swift :Swift talk")).events ==
                [.topic(channel: "#swift", topic: "Swift talk", setBy: nil)])
        #expect(session.handle(line(":bob!u@h TOPIC #swift :New topic")).events ==
                [.topic(channel: "#swift", topic: "New topic", setBy: "bob")])
        #expect(session.handle(line(":bob!u@h TOPIC #swift :")).events ==
                [.topic(channel: "#swift", topic: "", setBy: "bob")])
    }

    @Test func `Names arrive as one list, without status prefixes`() {
        var session = session()
        #expect(session.handle(line(":srv 353 alice = #swift :@op +voice")) == .init())
        #expect(session.handle(line(":srv 353 alice = #swift :~@owner plain")) == .init())
        #expect(session.handle(line(":srv 366 alice #swift :End of /NAMES list.")).events ==
                [.names(channel: "#swift", nicks: ["op", "voice", "owner", "plain"])])

        _ = session.handle(line(":srv 353 alice &local :@op"))   // RFC 1459 form, no symbol
        #expect(session.handle(line(":srv 366 alice &local :End of /NAMES list.")).events ==
                [.names(channel: "&local", nicks: ["op"])])
    }

    @Test func `A channel with no visible members has an empty list`() {
        var session = session()
        #expect(session.handle(line(":srv 366 alice #secret :End of /NAMES list.")).events ==
                [.names(channel: "#secret", nicks: [])])
    }

    // MARK: - Messages

    @Test func `Channel messages, ours and others'`() throws {
        var session = session()
        let time = try #require(line("@time=2011-10-19T16:40:51Z PING x").serverTime)
        #expect(session.handle(line("@time=2011-10-19T16:40:51Z :bob!u@h PRIVMSG #swift :hi alice")).events ==
                [.channelMessage(channel: "#swift", .init(sender: "bob", text: "hi alice", isOwn: false, time: time))])
        #expect(session.handle(line(":alice!u@h PRIVMSG #swift :\u{1}ACTION waves\u{1}")).events ==
                [.channelMessage(channel: "#swift", .init(sender: "alice", text: "waves", isAction: true, isOwn: true, time: nil))])
    }

    @Test func `Private messages are filed under the other person`() {
        var session = session()
        #expect(session.handle(line(":bob!u@h PRIVMSG Alice :psst")).events ==
                [.privateMessage(peer: "bob", .init(sender: "bob", text: "psst", isOwn: false, time: nil))])
        // Our own message to bob, sent from another client on the same bouncer (znc.in/self-message).
        #expect(session.handle(line(":alice!u@h PRIVMSG bob :hey")).events ==
                [.privateMessage(peer: "bob", .init(sender: "alice", text: "hey", isOwn: true, time: nil))])
        // ZNC modules talk from names that aren't valid nicknames.
        #expect(session.handle(line(":*status!znc@znc.in PRIVMSG alice :Connected!")).events ==
                [.privateMessage(peer: "*status", .init(sender: "*status", text: "Connected!", isOwn: false, time: nil))])
    }

    @Test func `Messages for some channel members only, as the server advertises`() {
        var session = session()
        // Before the server advertises STATUSMSG, "@#swift" is just an unknown target.
        #expect(session.handle(line(":bob!u@h PRIVMSG @#swift :ops?")) == .init())

        _ = session.handle(line(":srv 005 alice STATUSMSG=@+ CHANTYPES=# :are supported by this server"))
        #expect(session.handle(line(":bob!u@h PRIVMSG @#swift :ops only")).events ==
                [.channelMessage(channel: "#swift", .init(sender: "bob", text: "ops only", statusPrefix: "@"))])
        #expect(session.handle(line(":bob!u@h PRIVMSG +#swift :\u{1}ACTION whispers\u{1}")).events ==
                [.channelMessage(channel: "#swift", .init(sender: "bob", text: "whispers", isAction: true, statusPrefix: "+"))])
        // A "+" channel isn't a status message when what follows isn't a channel.
        #expect(session.handle(line(":bob!u@h PRIVMSG +modeless :hi")).events ==
                [.channelMessage(channel: "+modeless", .init(sender: "bob", text: "hi"))])
    }

    @Test(arguments: [
        ":bob!u@h PRIVMSG carol :not for us",   // between two other people
        "PRIVMSG #swift :no source",
        ":bob!u@h PRIVMSG #swift",              // no text
    ])
    func `Messages that belong nowhere are dropped`(text: String) {
        var session = session()
        #expect(session.handle(line(text)) == .init())
    }

    @Test func `Notices from servers and users`() {
        var session = session(registered: false)
        #expect(session.handle(line(":srv NOTICE * :*** Looking up your hostname...")).events ==
                [.notice(sender: "srv", channel: nil, text: "*** Looking up your hostname...", time: nil)])
        #expect(session.handle(line("NOTICE AUTH :*** Processing connection")).events ==
                [.notice(sender: nil, channel: nil, text: "*** Processing connection", time: nil)])

        _ = session.handle(line(":srv 001 alice :Welcome"))
        #expect(session.handle(line(":NickServ!s@services NOTICE alice :This nickname is registered")).events ==
                [.notice(sender: "NickServ", channel: nil, text: "This nickname is registered", time: nil)])
        #expect(session.handle(line(":bot!b@h NOTICE #swift :Meeting in five")).events ==
                [.notice(sender: "bot", channel: "#swift", text: "Meeting in five", time: nil)])

        // One for a channel's operators only is still the channel's.
        _ = session.handle(line(":srv 005 alice STATUSMSG=@+ :are supported by this server"))
        #expect(session.handle(line(":op!o@h NOTICE @#swift :ops, look at this")).events ==
                [.notice(sender: "op", channel: "#swift", text: "ops, look at this", time: nil)])
    }

    // MARK: - CTCP

    @Test func `Actions in channels and private conversations`() {
        var session = session()
        #expect(session.handle(line(":bob!u@h PRIVMSG #swift :\u{1}ACTION waves at alice\u{1}")).events ==
                [.channelMessage(channel: "#swift", .init(sender: "bob", text: "waves at alice", isAction: true, isOwn: false, time: nil))])
        #expect(session.handle(line(":bob!u@h PRIVMSG alice :\u{1}ACTION hugs you")).events ==   // no closing \u{1}
                [.privateMessage(peer: "bob", .init(sender: "bob", text: "hugs you", isAction: true, isOwn: false, time: nil))])
        // Our own action from another client on the bouncer.
        #expect(session.handle(line(":alice!u@h PRIVMSG bob :\u{1}ACTION shrugs\u{1}")).events ==
                [.privateMessage(peer: "bob", .init(sender: "alice", text: "shrugs", isAction: true, isOwn: true, time: nil))])
    }

    @Test func `Answers VERSION, even when asked in a channel, privately`() {
        var session = session()
        for query in [":bob!u@h PRIVMSG alice :\u{1}VERSION\u{1}", ":bob!u@h PRIVMSG #swift :\u{1}VERSION\u{1}"] {
            #expect(session.handle(line(query)) ==
                    .init(replies: [IRCMessage("NOTICE", ["bob", "\u{1}VERSION IRC Client\u{1}"])]))
        }
    }

    @Test func `Answers PING with the same parameters`() {
        var session = session()
        #expect(session.handle(line(":bob!u@h PRIVMSG alice :\u{1}PING 1700000000 42\u{1}")) ==
                .init(replies: [IRCMessage("NOTICE", ["bob", "\u{1}PING 1700000000 42\u{1}"])]))
    }

    @Test func `Leaves queries from our own other clients to them`() {
        var session = session()
        #expect(session.handle(line(":alice!u@h PRIVMSG bob :\u{1}VERSION\u{1}")) == .init())
        #expect(session.handle(line(":alice!u@h PRIVMSG bob :\u{1}PING 1\u{1}")) == .init())
    }

    @Test(arguments: ["TIME", "CLIENTINFO", "DCC SEND file 1 2 3", "FINGER", "SOURCE", "USERINFO", "SOMETHINGELSE"])
    func `Ignores CTCP the spec doesn't require`(query: String) {
        var session = session()
        #expect(session.handle(line(":bob!u@h PRIVMSG alice :\u{1}\(query)\u{1}")) == .init())
    }

    @Test func `Ignores CTCP replies`() {
        var session = session()
        #expect(session.handle(line(":bob!u@h NOTICE alice :\u{1}VERSION Other Client 1.0\u{1}")) == .init())
    }
}
