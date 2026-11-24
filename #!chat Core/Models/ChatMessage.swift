import CoreGraphics
import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let text: String
    // Optional metadata for rendering & behavior
    let senderNick: String?
    let isPrivmsg: Bool
    let isFromMe: Bool
    /// Someone else's message that mentions our nick — rendered highlighted and eligible
    /// for a user notification. Determined once at creation (nick at time of receipt).
    let isHighlight: Bool
    /// A `/me` action: `text` is what `senderNick` did, shown as "* nick text".
    let isAction: Bool
    /// For a channel message sent only to members with some status, the target it was sent
    /// to, like `@#chan` for operators only.
    let statusTarget: String?
    /// The server's reply to a command, ours or another client's: shown less prominently than
    /// what people say.
    let isReply: Bool
    /// `time` is the server's (IRCv3 server-time): when the server, or a bouncer, first had the
    /// line, rather than when it arrived here.
    let hasServerTime: Bool

    init(time: Date, text: String, senderNick: String? = nil, isPrivmsg: Bool = false, isFromMe: Bool = false, isHighlight: Bool = false, isAction: Bool = false, statusTarget: String? = nil, isReply: Bool = false, hasServerTime: Bool = false) {
        self.time = time
        self.text = text
        self.senderNick = senderNick
        self.isPrivmsg = isPrivmsg
        self.isFromMe = isFromMe
        self.isHighlight = isHighlight
        self.isAction = isAction
        self.statusTarget = statusTarget
        self.isReply = isReply
        self.hasServerTime = hasServerTime
    }
}

struct MessageThumbnail {
    let url: String
    /// Nil until it has loaded. Up to 600 pixels either way; the log fits it into 200 points.
    var image: CGImage?
}