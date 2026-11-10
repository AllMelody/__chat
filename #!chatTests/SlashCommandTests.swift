import Testing
@testable import __chat

struct SlashCommandTests {
    @Test(arguments: [
        ("hello", .text("hello")),                                                  // plain text
        ("/join swift", .join(channels: ["#swift"], keys: [])),                     // adds '#'
        ("/join #swift hunter2", .join(channels: ["#swift"], keys: ["hunter2"])),   // keeps '#' and key
        ("/join &local", .join(channels: ["&local"], keys: [])),                    // other channel prefixes too
        ("/join #a,b,&c k1,k2", .join(channels: ["#a", "#b", "&c"], keys: ["k1", "k2"])),   // lists, as in the protocol
        ("/me waves at everyone", .me("waves at everyone")),
        ("/me", .usage("me")),                                                      // action required
        ("/join", .usage("join")),                                                  // missing args
        ("/msg alice hello there world", .msg(target: "alice", message: "hello there world")),
        ("/msg alice", .usage("msg")),                                              // message required
        ("/query bob", .query(nick: "bob", message: nil)),                          // just opens the conversation
        ("/query bob hello there", .query(nick: "bob", message: "hello there")),
        ("/query", .usage("query")),
        ("/part", .part(target: nil)),                                              // target optional
        ("/part #foo", .part(target: "#foo")),
        ("/part foo", .part(target: "#foo")),                                       // adds '#', like /join
        ("/topic", .topic(nil)),                                                    // requests current
        ("/topic new topic here", .topic("new topic here")),                        // joins remainder
        ("/QUIT", .quit),                                                           // case-insensitive
        ("/", .text("")),                                                           // bare slash says nothing
        ("//join swift", .text("/join swift")),                                     // "//" escapes the slash
        ("//", .text("/")),
        ("///", .text("//")),                                                       // only one slash is dropped
    ] as [(String, MessageRouter.ParsedCommand)])
    func `Parses composer input`(input: String, expected: MessageRouter.ParsedCommand) {
        #expect(MessageRouter.parse(input) == expected)
    }

    @Test(arguments: [
        ("/whois bob", "whois bob"),                                    // a command the app doesn't know
        ("/MODE #swift +o bob", "mode #swift +o bob"),
        ("/away", "away"),
        ("/away back in an hour", "away :back in an hour"),             // free text stays in one piece
        ("/away :back in an hour", "away :back in an hour"),            // also when typed the protocol's way
        ("/kick #swift bob", "kick #swift bob"),
        ("/kick #swift bob stop that", "kick #swift bob :stop that"),
        ("/notice bob hi there", "notice bob :hi there"),
        ("/raw PRIVMSG #swift :hello there", "PRIVMSG #swift :hello there"),
        ("/quote WHOIS bob", "WHOIS bob"),
    ])
    func `Other commands go to the server`(input: String, line: String) {
        #expect(MessageRouter.parse(input) == .raw(line))
    }

    @Test func `A line for the server needs a line`() {
        #expect(MessageRouter.parse("/raw") == .usage("raw"))
    }

    @Test func `Passed-on commands reach the wire whole`() throws {
        guard case .raw(let line) = MessageRouter.parse("/away back in an hour") else {
            Issue.record("Expected a line for the server")
            return
        }
        #expect(try #require(IRCMessage(line)).wireFormat == "AWAY :back in an hour")
    }

    @Test func `Channel lists get their prefixes one by one`() {
        #expect(MessageRouter.channelNames("swift,#help,&local") == ["#swift", "#help", "&local"])
        #expect(MessageRouter.channelNames(",") == [])
    }
}
