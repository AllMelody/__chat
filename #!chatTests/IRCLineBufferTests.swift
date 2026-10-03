import Testing
@testable import __chat

struct IRCLineBufferTests {
    @Test func `Emits complete lines across chunks`() throws {
        var buffer = IRCLineBuffer()
        #expect(try buffer.append(Array("PING :a\r\nPRIV".utf8)) == ["PING :a"])
        #expect(try buffer.append(Array("MSG #c :hi\r\n".utf8)) == ["PRIVMSG #c :hi"])
        #expect(try buffer.append([]) == [])
    }

    @Test func `Accepts bare LF and skips empty lines`() throws {
        var buffer = IRCLineBuffer()
        #expect(try buffer.append(Array("A\n\r\n\nB\r\n".utf8)) == ["A", "B"])
    }

    @Test func `Reassembles UTF-8 split across chunks`() throws {
        var buffer = IRCLineBuffer()
        let bytes = Array("PRIVMSG #c :héllo\r\n".utf8)
        let split = bytes.firstIndex(of: 0xC3)! + 1   // between the two bytes of "é"
        #expect(try buffer.append(bytes[..<split]) == [])
        #expect(try buffer.append(bytes[split...]) == ["PRIVMSG #c :héllo"])
    }

    @Test func `Invalid UTF-8 is replaced, not dropped`() throws {
        var buffer = IRCLineBuffer()
        let bytes = Array("PRIVMSG #c :".utf8) + [0xFF, 0xFE] + Array("\r\nPING :x\r\n".utf8)
        #expect(try buffer.append(bytes) == ["PRIVMSG #c :\u{FFFD}\u{FFFD}", "PING :x"])
    }

    @Test func `Unterminated flood is rejected`() throws {
        var buffer = IRCLineBuffer()
        #expect(throws: IRCLineBuffer.LineTooLong.self) {
            try buffer.append(Array(repeating: UInt8(ascii: "x"), count: IRCLineBuffer.maximumLineLength + 1))
        }
    }

    @Test func `Long lines are fine once terminated`() throws {
        var buffer = IRCLineBuffer()
        let long = String(repeating: "x", count: IRCLineBuffer.maximumLineLength)
        #expect(try buffer.append(Array(long.utf8)) == [])
        #expect(try buffer.append(Array("\n".utf8)) == [long])
    }
}
