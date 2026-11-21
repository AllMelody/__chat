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

    init(time: Date, text: String, senderNick: String? = nil, isPrivmsg: Bool = false, isFromMe: Bool = false, isHighlight: Bool = false, isAction: Bool = false, statusTarget: String? = nil) {
        self.time = time
        self.text = text
        self.senderNick = senderNick
        self.isPrivmsg = isPrivmsg
        self.isFromMe = isFromMe
        self.isHighlight = isHighlight
        self.isAction = isAction
        self.statusTarget = statusTarget
    }
}

struct MessageThumbnail {
    let url: String
    /// Nil until it has loaded. Its size in pixels is the size to show it at, in points.
    var image: CGImage?
}