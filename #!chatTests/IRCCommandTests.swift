import Foundation
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

    @Test func repeatedModeLettersDoNotChangeMeaning() {
        #expect(IRCUserMode("ii") == .invisible)
        #expect(IRCChannelMode("oo") == .channelOperator)
        #expect(IRCChannelMode(String(repeating: "k", count: 100)) == .password)
    }

    @Test func serverTimeParsesWithAndWithoutFractionalSeconds() throws {
        let withMillis = IRCMessage(command: .PING(server: "x", server2: nil),
                                    tags: ["time": "2011-10-19T16:40:51.620Z"])
        let withoutMillis = IRCMessage(command: .PING(server: "x", server2: nil),
                                       tags: ["time": "2011-10-19T16:40:51Z"])
        let garbage = IRCMessage(command: .PING(server: "x", server2: nil),
                                 tags: ["time": "yesterday"])
        let millis = try #require(withMillis.serverTime).timeIntervalSince1970
        #expect(abs(millis - 1_319_042_451.620) < 0.001)
        #expect(withoutMillis.serverTime == Date(timeIntervalSince1970: 1_319_042_451))
        #expect(garbage.serverTime == nil)
    }

    @Test func recipientEqualityIsCaseInsensitive() throws {
        let a = try #require(IRCMessageRecipient("#Swift"))
        let b = try #require(IRCMessageRecipient("#swift"))
        #expect(a == b)
        #expect(Set([a, b]).count == 1)
        #expect(IRCMessageRecipient.everything != a)
    }
}
