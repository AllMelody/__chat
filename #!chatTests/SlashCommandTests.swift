import Testing
@testable import __chat

struct SlashCommandTests {
    @Test(arguments: [
        ("hello", .text("hello")),                                                  // plain text
        ("/join swift", .join(channel: "#swift", key: nil)),                        // adds '#'
        ("/join #swift hunter2", .join(channel: "#swift", key: "hunter2")),         // keeps '#' and key
        ("/join &local", .join(channel: "&local", key: nil)),                       // other channel prefixes too
        ("/me waves at everyone", .me("waves at everyone")),
        ("/me", .usage("me")),                                                      // action required
        ("/join", .usage("join")),                                                  // missing args
        ("/msg alice hello there world", .msg(target: "alice", message: "hello there world")),
        ("/msg alice", .usage("msg")),                                              // message required
        ("/part", .part(target: nil)),                                              // target optional
        ("/part #foo", .part(target: "#foo")),
        ("/topic", .topic(nil)),                                                    // requests current
        ("/topic new topic here", .topic("new topic here")),                        // joins remainder
        ("/QUIT", .quit),                                                           // case-insensitive
        ("/wat", .unknown("wat")),
        ("/", .unknown("")),                                                        // bare slash
    ] as [(String, MessageRouter.ParsedCommand)])
    func parse(input: String, expected: MessageRouter.ParsedCommand) {
        #expect(MessageRouter.parse(input) == expected)
    }
}
