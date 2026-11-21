/// Where a message came from (RFC 1459 §2.3.1 "prefix"): `nick!user@host` for users, a
/// bare name for servers.
nonisolated struct IRCSource: Hashable, Sendable {
    /// The nickname, or the server name for server-originated messages.
    var nick: String
    var user: String?
    var host: String?

    init(nick: String, user: String? = nil, host: String? = nil) {
        self.nick = nick
        self.user = user
        self.host = host
    }

    /// Parses a source as it appears on the wire, without its leading colon.
    init(_ raw: String) {
        let userAndHost = raw.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let nickAndUser = userAndHost[0].split(separator: "!", maxSplits: 1, omittingEmptySubsequences: false)
        self.init(nick: String(nickAndUser[0]),
                  user: nickAndUser.count > 1 ? String(nickAndUser[1]) : nil,
                  host: userAndHost.count > 1 ? String(userAndHost[1]) : nil)
    }
}
