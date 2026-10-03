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

    /// A PRIVMSG to a channel. `isOwn` marks our own message, echoed back by the server.
    case channelMessage(channel: String, sender: String, text: String, isOwn: Bool, time: Date?)
    /// A PRIVMSG in a private conversation with `peer`. That's the sender of a message to
    /// us, or the recipient of our own message to someone else when the server echoes it
    /// back (`isOwn`).
    case privateMessage(peer: String, sender: String, text: String, isOwn: Bool, time: Date?)
    case notice(text: String, time: Date?)

    // MARK: Channels and users

    case joined(channel: String, nick: String, isSelf: Bool)
    case parted(channel: String, nick: String, isSelf: Bool)
    case quit(nick: String, reason: String?)
    /// Someone else changed their nickname. (Ours is `nicknameChanged`.)
    case nickChanged(from: String, to: String)
    /// The channel topic: the current one when joining (`setBy` nil), or a change.
    case topic(channel: String, topic: String, setBy: String?)
    /// A batch of channel members (RPL_NAMREPLY), with status prefixes like `@` removed.
    case names(channel: String, nicks: [String])
    /// One channel member from a WHO reply.
    case whoReply(channel: String, nick: String)
}
