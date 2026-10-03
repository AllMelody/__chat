import Foundation
import Testing
@testable import __chat

struct IRCMessageTests {
    // MARK: - Parsing

    @Test func `Parses tags, source, command and trailing parameter`() throws {
        let message = try #require(IRCMessage("@time=2011-10-19T16:40:51.620Z;msgid=abc :nick!user@host PRIVMSG #chan :héllo wörld"))
        #expect(message.tags == ["time": "2011-10-19T16:40:51.620Z", "msgid": "abc"])
        #expect(message.source == IRCSource(nick: "nick", user: "user", host: "host"))
        #expect(message.command == "PRIVMSG")
        #expect(message.parameters == ["#chan", "héllo wörld"])
    }

    @Test(arguments: [
        ("PING", "PING", [String]()),                                   // no parameters
        ("ping :token", "PING", ["token"]),                             // command is uppercased
        (":srv 001 me :Welcome to IRC", "001", ["me", "Welcome to IRC"]),
        (":srv 005 me CHANTYPES=# NICKLEN=30 :are supported", "005", ["me", "CHANTYPES=#", "NICKLEN=30", "are supported"]),
        ("TOPIC #c :", "TOPIC", ["#c", ""]),                            // empty trailing
        ("PRIVMSG #c ::-)", "PRIVMSG", ["#c", ":-)"]),                   // trailing starting with ':'
        ("JOIN   #a    key  ", "JOIN", ["#a", "key"]),                  // extra spaces
        ("NOTICE * :a  b ", "NOTICE", ["*", "a  b "]),                  // trailing keeps its spaces
    ])
    func `Parses commands and parameters`(line: String, command: String, parameters: [String]) throws {
        let message = try #require(IRCMessage(line))
        #expect(message.command == command)
        #expect(message.parameters == parameters)
    }

    @Test(arguments: ["", "   ", "@tag=only", ":source.only", "@a=b :src"])
    func `Lines without a command are rejected`(line: String) {
        #expect(IRCMessage(line) == nil)
    }

    @Test func `Server source has no user or host`() throws {
        let message = try #require(IRCMessage(":irc.example.net NOTICE * :hi"))
        #expect(message.source == IRCSource(nick: "irc.example.net"))
    }

    @Test(arguments: [
        ("nick!user@host", IRCSource(nick: "nick", user: "user", host: "host")),
        ("nick@host", IRCSource(nick: "nick", host: "host")),
        ("nick!user", IRCSource(nick: "nick", user: "user")),
        ("irc.example.net", IRCSource(nick: "irc.example.net")),
    ])
    func `Source forms`(raw: String, expected: IRCSource) {
        #expect(IRCSource(raw) == expected)
    }

    @Test func `Tag values are unescaped`() throws {
        let message = try #require(IRCMessage(#"@a=one\:two\sthree\\four\r\n;b;c=;d=x\yz\;e=é\s PING"#))
        #expect(message.tags["a"] == "one;two three\\four\r\n")
        #expect(message.tags["b"] == "")       // no value
        #expect(message.tags["c"] == "")       // empty value
        #expect(message.tags["d"] == "xyz")    // unknown escape is the character itself; lone trailing '\' dropped
        #expect(message.tags["e"] == "é ")
    }

    @Test func `Repeated tag keeps the last value`() throws {
        let message = try #require(IRCMessage("@k=1;k=2 PING"))
        #expect(message.tags["k"] == "2")
    }

    // MARK: - Serialization

    @Test(arguments: [
        (IRCMessage.nick("alice"), "NICK alice"),
        (.privateMessage(to: "#swift", "hello there"), "PRIVMSG #swift :hello there"),
        (.privateMessage(to: "bob", "hi"), "PRIVMSG bob hi"),
        (.privateMessage(to: "bob", ":)"), "PRIVMSG bob ::)"),
        (.topic("#swift", ""), "TOPIC #swift :"),                     // clears the topic
        (.topic("#swift"), "TOPIC #swift"),                           // asks for the topic
        (.join("#swift", key: "hunter2"), "JOIN #swift hunter2"),
        (.user("guest", realName: "A Guest"), "USER guest 0 * :A Guest"),
        (.capabilityRequest(["server-time", "multi-prefix"]), "CAP REQ :server-time multi-prefix"),
        (.quit(), "QUIT"),
    ])
    func `Wire format`(message: IRCMessage, line: String) {
        #expect(message.wireFormat == line)
    }

    @Test func `Line breaks cannot inject a second command`() {
        let message = IRCMessage.privateMessage(to: "#c", "hi\r\nQUIT :bye\0")
        #expect(message.wireFormat == "PRIVMSG #c :hi  QUIT :bye ")
    }

    @Test func `Parsing round-trips the wire format`() throws {
        let original = IRCMessage("PRIVMSG", ["#c", ": spaced : text"])
        #expect(IRCMessage(original.wireFormat) == original)
    }

    // MARK: - server-time

    @Test func `Server time with and without fractional seconds`() throws {
        let withMillis = try #require(IRCMessage("@time=2011-10-19T16:40:51.620Z PING x"))
        let withoutMillis = try #require(IRCMessage("@time=2011-10-19T16:40:51Z PING x"))
        let garbage = try #require(IRCMessage("@time=yesterday PING x"))
        let untagged = try #require(IRCMessage("PING x"))

        let millis = try #require(withMillis.serverTime).timeIntervalSince1970
        #expect(abs(millis - 1_319_042_451.620) < 0.001)
        #expect(withoutMillis.serverTime == Date(timeIntervalSince1970: 1_319_042_451))
        #expect(garbage.serverTime == nil)
        #expect(untagged.serverTime == nil)
    }
}
