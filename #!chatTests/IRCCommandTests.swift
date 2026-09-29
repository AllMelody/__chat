import Testing
@testable import __chat

struct IRCCommandTests {
    @Test func capArgumentsDoNotCrash() {
        #expect(IRCCommand.CAP(.REQ, ["server-time", "multi-prefix"]).arguments
                == ["REQ", "server-time multi-prefix"])
        #expect(IRCCommand.CAP(.END, []).arguments == ["END"])
    }

    @Test func capArgumentsRoundTripThroughParser() throws {
        let original = IRCCommand.CAP(.REQ, ["server-time", "multi-prefix"])
        let parsed = try IRCCommand("CAP", arguments: original.arguments)
        guard case .CAP(let subcmd, let ids) = parsed else {
            Issue.record("Expected CAP, got \(parsed)")
            return
        }
        #expect(subcmd == .REQ)
        #expect(ids == ["server-time", "multi-prefix"])
    }
}
