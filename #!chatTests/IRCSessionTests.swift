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

    @Test(arguments: ["433", "432", "436", "437", "464", "465"])
    func `Rejections before registration fail it`(numeric: String) {
        var session = session(registered: false)
        #expect(session.handle(line(":srv \(numeric) * alice :Nope")).events == [.registrationFailed(reason: "Nope")])
    }

    @Test func `Nickname in use after registration is not a registration failure`() {
        var session = session()
        #expect(session.handle(line(":srv 433 alice bob :Nickname is already in use")) == .init())
    }

    @Test(arguments: ["421 * CAP :Unknown command", "451 * :You have not registered", "461 CAP :Not enough parameters"])
    func `Servers that don't speak CAP still register`(reply: String) {
        var session = session(registered: false)
        #expect(session.handle(line(":srv \(reply)")) == .init())
        #expect(session.handle(line(":srv 001 alice :Welcome")).events == [.registered(nickname: "alice")])
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
        #expect(session.handle(line(":bob!u@h PART #a :bye")).events == [.parted(channel: "#a", nick: "bob", isSelf: false)])
        #expect(session.handle(line(":alice!u@h PART #b")).events == [.parted(channel: "#b", nick: "alice", isSelf: true)])
    }

    @Test func `Quit with and without a reason`() {
        var session = session()
        #expect(session.handle(line(":bob!u@h QUIT :Ping timeout")).events == [.quit(nick: "bob", reason: "Ping timeout")])
        #expect(session.handle(line(":bob!u@h QUIT")).events == [.quit(nick: "bob", reason: nil)])
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

    @Test func `Names lose their status prefixes`() {
        var session = session()
        #expect(session.handle(line(":srv 353 alice = #swift :@op +voice ~@owner plain")).events ==
                [.names(channel: "#swift", nicks: ["op", "voice", "owner", "plain"])])
        #expect(session.handle(line(":srv 353 alice &local :@op")).events ==   // RFC 1459 form, no symbol
                [.names(channel: "&local", nicks: ["op"])])
    }

    @Test func `WHO replies, including an IPv6 host`() {
        var session = session()
        #expect(session.handle(line(":srv 352 alice #swift ~u 2001:db8::1 srv bob H :0 Bob")).events ==
                [.whoReply(channel: "#swift", nick: "bob")])
    }

    // MARK: - Messages

    @Test func `Channel messages, ours and others'`() throws {
        var session = session()
        let time = try #require(line("@time=2011-10-19T16:40:51Z PING x").serverTime)
        #expect(session.handle(line("@time=2011-10-19T16:40:51Z :bob!u@h PRIVMSG #swift :hi alice")).events ==
                [.channelMessage(channel: "#swift", sender: "bob", text: "hi alice", isOwn: false, time: time)])
        #expect(session.handle(line(":alice!u@h PRIVMSG #swift :\u{1}ACTION waves\u{1}")).events ==
                [.channelMessage(channel: "#swift", sender: "alice", text: "\u{1}ACTION waves\u{1}", isOwn: true, time: nil)])
    }

    @Test func `Private messages are filed under the other person`() {
        var session = session()
        #expect(session.handle(line(":bob!u@h PRIVMSG Alice :psst")).events ==
                [.privateMessage(peer: "bob", sender: "bob", text: "psst", isOwn: false, time: nil)])
        // Our own message to bob, echoed back by a bouncer (znc.in/self-message).
        #expect(session.handle(line(":alice!u@h PRIVMSG bob :hey")).events ==
                [.privateMessage(peer: "bob", sender: "alice", text: "hey", isOwn: true, time: nil)])
        // ZNC modules talk from names that aren't valid nicknames.
        #expect(session.handle(line(":*status!znc@znc.in PRIVMSG alice :Connected!")).events ==
                [.privateMessage(peer: "*status", sender: "*status", text: "Connected!", isOwn: false, time: nil)])
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
                [.notice(text: "*** Looking up your hostname...", time: nil)])
        #expect(session.handle(line("NOTICE AUTH :*** Processing connection")).events ==
                [.notice(text: "*** Processing connection", time: nil)])
    }
}
