import NIOCore
import Testing
@testable import __chat

struct IRCMessageParserTests {
    private func parse(_ chunks: [[UInt8]]) -> [(IRCParserError?, IRCMessage?)] {
        var parser = IRCMessageParser()
        var results: [(IRCParserError?, IRCMessage?)] = []
        for chunk in chunks {
            parser.feed(ByteBuffer(bytes: chunk)) { results.append($0) }
        }
        return results
    }

    @Test func parsesUTF8LineSplitAcrossChunks() throws {
        let line = Array("@time=2011-10-19T16:40:51.620Z :nick!u@h PRIVMSG #chan :héllo wörld\r\n".utf8)
        let results = parse([Array(line[..<20]), Array(line[20...])])
        #expect(results.count == 1)
        let message = try #require(results.first?.1)
        #expect(message.origin == "nick!u@h")
        #expect(message.tags?["time"] == "2011-10-19T16:40:51.620Z")
        guard case .PRIVMSG(let recipients, let text) = message.command else {
            Issue.record("Expected PRIVMSG, got \(message.command)")
            return
        }
        #expect(recipients.map(\.stringValue) == ["#chan"])
        #expect(text == "héllo wörld")
    }

    @Test func invalidUTF8YieldsErrorAndParsingContinues() {
        let bad: [UInt8] = Array(":nick PRIVMSG #chan :".utf8) + [0xFF, 0xFE] + Array("\r\n".utf8)
        let good = Array("PING :token\r\n".utf8)
        let results = parse([bad + good])
        #expect(results.count == 2)
        #expect(results.first?.0 != nil)
        #expect(results.last?.1 != nil)
    }
}
