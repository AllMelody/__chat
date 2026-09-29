import NIOCore

/// Frames the inbound byte stream into complete IRC lines (each including its
/// trailing `\n`) so `IRCChannelHandler`'s parser only ever sees whole lines.
///
/// Install it wrapped in `ByteToMessageHandler(_:maximumBufferSize:)`: a peer that
/// never sends a newline then fails the channel instead of growing a buffer forever.
nonisolated struct IRCLineDecoder: ByteToMessageDecoder {
  typealias InboundOut = ByteBuffer

  /// IRCv3 allows 8191 bytes of tags plus a 512-byte message; leave headroom.
  static let maximumLineLength = 16 * 1024

  mutating func decode(context: ChannelHandlerContext,
                       buffer: inout ByteBuffer) throws -> DecodingState
  {
    // ByteBufferView indices are reader-index based.
    guard let newline = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")),
          let line = buffer.readSlice(length: newline - buffer.readerIndex + 1)
    else { return .needMoreData }

    context.fireChannelRead(wrapInboundOut(line))
    return .continue
  }

  mutating func decodeLast(context: ChannelHandlerContext,
                           buffer: inout ByteBuffer,
                           seenEOF: Bool) throws -> DecodingState
  {
    // Deliver any complete lines; an unterminated tail is dropped, as before.
    while try decode(context: context, buffer: &buffer) == .continue {}
    return .needMoreData
  }
}
