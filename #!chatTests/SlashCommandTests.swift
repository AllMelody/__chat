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
        ("/part", .part(target: nil)),                                              // target optional
        ("/part #foo", .part(target: "#foo")),
        ("/part foo", .part(target: "#foo")),                                       // adds '#', like /join
        ("/topic", .topic(nil)),                                                    // requests current
        ("/topic new topic here", .topic("new topic here")),                        // joins remainder
        ("/QUIT", .quit),                                                           // case-insensitive
        ("/wat", .unknown("wat")),
        ("/", .unknown("")),                                                        // bare slash
        ("//join swift", .text("/join swift")),                                     // "//" escapes the slash
        ("//", .text("/")),
        ("///", .text("//")),                                                       // only one slash is dropped
    ] as [(String, MessageRouter.ParsedCommand)])
    func `Parses composer input`(input: String, expected: MessageRouter.ParsedCommand) {
        #expect(MessageRouter.parse(input) == expected)
    }

    @Test func `Channel lists get their prefixes one by one`() {
        #expect(MessageRouter.channelNames("swift,#help,&local") == ["#swift", "#help", "&local"])
        #expect(MessageRouter.channelNames(",") == [])
    }
}
