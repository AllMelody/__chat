import Foundation
import SwiftUI

/// A sidebar row: a server, or one of its channels or private conversations.
struct SidebarItem: Identifiable {
    enum Kind { case server, channel(IRCChannel), privateConversation(IRCPrivateConversation) }
    /// The server this row is, or belongs to.
    let server: IRCServer
    let kind: Kind

    var id: UUID {
        switch kind {
        case .server: server.id
        case .channel(let c): c.id
        case .privateConversation(let pm): pm.id
        }
    }
    var name: String {
        switch kind {
        case .server: server.name
        case .channel(let c): c.name
        case .privateConversation(let pm): pm.nickname
        }
    }
    var systemImageName: String {
        switch kind {
        case .channel: "rectangle.3.group.bubble"
        case .privateConversation: "person.2"
        case .server:
            switch server.connectionStatus {
            case .connected: "network"
            case .connecting: "network.badge.shield.half.filled"
            case .reconnecting: "arrow.clockwise.circle"
            case .connectionTimeout, .disconnected: "network.slash"
            }
        }
    }
    /// Whether the row is a channel or private conversation, rather than a server.
    var isConversation: Bool {
        if case .server = kind { false } else { true }
    }
    /// The row's channel, when it is one.
    var channel: IRCChannel? {
        guard case .channel(let channel) = kind else { return nil }
        return channel
    }
    /// The log shown while the row is selected.
    var log: [ChatMessage] {
        switch kind {
        case .server: server.log
        case .channel(let c): c.log
        case .privateConversation(let pm): pm.log
        }
    }
    /// Where text typed while the row is selected goes; nil for a server, which only takes
    /// commands.
    var messageTarget: MessageTarget? {
        switch kind {
        case .server: nil
        case .channel(let c): .channel(c)
        case .privateConversation(let pm): .privateConversation(pm)
        }
    }
}

extension IRCServer.ConnectionStatus {
    /// The color of a server's icon in the sidebar while it's in this state.
    var color: Color {
        switch self {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .connectionTimeout: .red
        case .disconnected: .secondary
        }
    }
}
