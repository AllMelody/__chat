import Testing
@testable import __chat

struct CTCPMessageTests {
    @Test(arguments: [
        ("\u{1}ACTION waves hello\u{1}", CTCPMessage(command: "ACTION", parameters: "waves hello")),
        ("\u{1}ACTION waves", CTCPMessage(command: "ACTION", parameters: "waves")),      // closing \u{1} is optional
        ("\u{1}VERSION\u{1}", CTCPMessage(command: "VERSION")),
        ("\u{1}ping 1700000000 42\u{1}", CTCPMessage(command: "PING", parameters: "1700000000 42")),
        ("\u{1}ACTION \u{1}", CTCPMessage(command: "ACTION", parameters: "")),
    ])
    func parses(text: String, expected: CTCPMessage) {
        #expect(CTCPMessage(parsing: text) == expected)
    }

    @Test(arguments: ["hello", "", "\u{1}", "\u{1}\u{1}", "\u{1} leading space\u{1}", "not \u{1}ACTION\u{1} first"])
    func `Not CTCP`(text: String) {
        #expect(CTCPMessage(parsing: text) == nil)
    }

    @Test func `Encodes with both delimiters`() {
        #expect(CTCPMessage(command: "VERSION", parameters: "IRC Client").text == "\u{1}VERSION IRC Client\u{1}")
        #expect(CTCPMessage(command: "PING").text == "\u{1}PING\u{1}")
    }

    @Test func `Wire formats for actions and replies`() {
        #expect(IRCMessage.action(to: "#swift", "waves").wireFormat == "PRIVMSG #swift :\u{1}ACTION waves\u{1}")
        #expect(IRCMessage.ctcpReply(to: "bob", CTCPMessage(command: "VERSION", parameters: "IRC Client")).wireFormat ==
                "NOTICE bob :\u{1}VERSION IRC Client\u{1}")
    }
}
