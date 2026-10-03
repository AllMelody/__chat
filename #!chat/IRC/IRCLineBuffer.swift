/// Reassembles the inbound byte stream into protocol lines. Lines end in CR-LF (RFC 1459
/// §2.3); a bare LF is accepted too. Text is decoded as UTF-8, with invalid bytes replaced
/// by U+FFFD so a line in a legacy encoding still arrives, just imperfectly.
nonisolated struct IRCLineBuffer {
    /// IRCv3 allows 8191 bytes of tags plus a 512-byte message; leave headroom.
    static let maximumLineLength = 16 * 1024

    /// The peer sent more than `maximumLineLength` bytes without ending the line.
    struct LineTooLong: Error {}

    private var pending: [UInt8] = []

    /// Adds received bytes and returns the lines they completed, skipping empty ones.
    /// Throws rather than buffer without bound when a line never ends.
    mutating func append(_ bytes: some Sequence<UInt8>) throws(LineTooLong) -> [String] {
        pending.append(contentsOf: bytes)

        var lines: [String] = []
        var lineStart = pending.startIndex
        while let newline = pending[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
            var line = pending[lineStart..<newline]
            if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
            lineStart = newline + 1
        }
        pending.removeSubrange(..<lineStart)

        guard pending.count <= Self.maximumLineLength else { throw LineTooLong() }
        return lines
    }
}
