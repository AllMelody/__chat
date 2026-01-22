import Foundation
import AppKit

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let text: String
    // Optional metadata for rendering & behavior
    let senderNick: String?
    let isPrivmsg: Bool
    let isFromMe: Bool

    init(time: Date, text: String, senderNick: String? = nil, isPrivmsg: Bool = false, isFromMe: Bool = false) {
        self.time = time
        self.text = text
        self.senderNick = senderNick
        self.isPrivmsg = isPrivmsg
        self.isFromMe = isFromMe
    }
}

struct MessageThumbnail {
    let url: String
    var image: NSImage?
}