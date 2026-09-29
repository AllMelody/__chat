import NIOCore
import NIOEmbedded
import Testing
@testable import __chat

struct IRCLineDecoderTests {
    private func makeChannel() throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(IRCLineDecoder(), maximumBufferSize: 64))
        return channel
    }

    @Test func emitsCompleteLinesAcrossChunks() throws {
        let channel = try makeChannel()
        try channel.writeInbound(ByteBuffer(string: "PING :a\r\nPRIV"))
        try channel.writeInbound(ByteBuffer(string: "MSG #c :hi\r\n"))
        #expect(try channel.readInbound(as: ByteBuffer.self) == ByteBuffer(string: "PING :a\r\n"))
        #expect(try channel.readInbound(as: ByteBuffer.self) == ByteBuffer(string: "PRIVMSG #c :hi\r\n"))
        #expect(try channel.readInbound(as: ByteBuffer.self) == nil)
    }

    @Test func unterminatedFloodIsRejected() throws {
        let channel = try makeChannel()
        #expect(throws: ByteToMessageDecoderError.PayloadTooLargeError.self) {
            try channel.writeInbound(ByteBuffer(string: String(repeating: "x", count: 200)))
        }
    }
}
