import Foundation

/// Something that happened on an IRC connection, as reported to the app. `IRCSession`
/// produces the protocol events; `IRCClient` adds `lineReceived` and `disconnected`.
nonisolated enum IRCEvent: Equatable, Sendable {
    /// A line arrived from the server. Reported verbatim, before it's interpreted, for
    /// debug logging.
    case lineReceived(String)

    // MARK: Registration and connection

    /// The server accepted us (RPL_WELCOME) under `nickname`.
    case registered(nickname: String)
    /// The server turned registration down (`reason` is its explanation, e.g. "Nickname is
    /// already in use"). The client has closed the connection; nothing else follows.
    case registrationFailed(reason: String)
    /// The connection ended without the app closing it: dropped, rejected by TLS, or ended by
    /// the server. (One that can't be established yet keeps trying until the app gives up.)
    /// Nothing else follows.
    case disconnected(reason: String)
    /// Our own nickname changed.
    case nicknameChanged(String)
    /// The message of the day, once complete.
    case messageOfTheDay(String)
    /// A reply to a PING, i.e. the server is still there.
    case pong

    // MARK: Messages

    /// A PRIVMSG to a channel, including one sent only to its members with some status
    /// (`message.statusPrefix`).
    case channelMessage(channel: String, Message)
    /// A PRIVMSG in a private conversation with `peer`: the sender of a message to us, or the
    /// recipient of one we sent from another client (`isOwn`, relayed by a bouncer thanks to
    /// znc.in/self-message).
    case privateMessage(peer: String, Message)
    case notice(text: String, time: Date?)

    /// What a PRIVMSG says, wherever it was sent.
    struct Message: Equatable, Sendable {
        var sender: String
        var text: String
        /// A `/me` (CTCP ACTION): `text` is the action itself.
        var isAction = false
        /// One we sent from another client sharing our bouncer connection, or one in replayed
        /// backlog. Lines this client sends never come back.
        var isOwn = false
        /// For a channel message sent only to members with this status or higher (STATUSMSG,
        /// e.g. `PRIVMSG @#chan`): the prefix, like `@` for operators.
        var statusPrefix: Character?
        /// When the server says it was originally sent (IRCv3 server-time), e.g. for backlog.
        var time: Date?
    }

    // MARK: Channels and users

    case joined(channel: String, nick: String, isSelf: Bool)
    case parted(channel: String, nick: String, isSelf: Bool)
    /// `nick` was removed from `channel` by `kicker` (nil when the server did it).
    case kicked(channel: String, nick: String, kicker: String?, reason: String?, isSelf: Bool)
    case quit(nick: String, reason: String?)
    /// Someone else changed their nickname. (Ours is `nicknameChanged`.)
    case nickChanged(from: String, to: String)
    /// The channel topic: the current one when joining (`setBy` nil), or a change.
    case topic(channel: String, topic: String, setBy: String?)
    /// Everyone in a channel, from a complete NAMES reply (sent when we join, or for /names),
    /// with status prefixes like `@` removed.
    case names(channel: String, nicks: [String])
}
