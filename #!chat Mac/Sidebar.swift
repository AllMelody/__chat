import AppKit
import SwiftUI

struct SidebarRowBase<Content: View>: View {
    let isSelected: Bool
    let indent: CGFloat
    let rowHeight: CGFloat
    let activeState: ControlActiveState
    @ViewBuilder var content: Content
    var body: some View {
        let isKey = (activeState == .key)
        let bgColor: Color = if !isSelected { .clear }
            else if isKey { Color(nsColor: .selectedContentBackgroundColor) }
            else { Color(nsColor: .unemphasizedSelectedContentBackgroundColor) }
        let fgColor: Color = isSelected && isKey ? .white : .primary
        ZStack {
            bgColor
            HStack(spacing: 6) {
                Color.clear.frame(width: indent)
                HStack(spacing: 6) { content.frame(height: rowHeight) }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(fgColor)
        }
        .contentShape(Rectangle())
    }
}

struct ServerRow: View {
    let server: IRCServer
    let isSelected: Bool
    let rowHeight: CGFloat
    let iconColWidth: CGFloat
    let activeState: ControlActiveState
    let select: () -> Void
    let connect: () -> Void
    let disconnect: () -> Void
    let joinChannelPrompt: () -> Void
    let editServer: () -> Void
    let deleteServer: () -> Void

    private var isConnecting: Bool {
        server.connectionStatus == .connecting || server.connectionStatus == .reconnecting
    }

    var body: some View {
        let item = SidebarItem(server: server, kind: .server)
        SidebarRowBase(isSelected: isSelected, indent: 0, rowHeight: rowHeight, activeState: activeState) {
            Image(systemName: item.systemImageName)
                .frame(width: iconColWidth, alignment: .center)
                .foregroundStyle(server.connectionStatus.color)
            Text(item.name).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            
            // Status indicator for connecting/reconnecting states
            if isConnecting {
                Image(systemName: "ellipsis")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .symbolEffect(.variableColor.iterative, isActive: true)
            }
        }
        .contextMenu {
            if server.isConnected {
                Button("Disconnect", action: disconnect)
                Button("Join Channel…", action: joinChannelPrompt)
            } else if isConnecting {
                Button("Cancel Connection", action: disconnect)
            } else {
                Button("Connect", action: connect)
            }
            Divider()
            Button("Edit Server…", action: editServer)
            Divider()
            Button("Delete Server…", role: .destructive, action: deleteServer)
        }
        .onTapGesture(perform: select)
    }
}

/// Sidebar row for a channel or private message: icon with unread badge, name, and a
/// single context-menu action (Part / Close).
struct ConversationRow: View {
    let item: SidebarItem
    let unreadCount: Int
    /// Some of what's unread was meant for us (a mention, a private message): the badge is red.
    let wantsAttention: Bool
    /// A channel we're not in right now: disconnected, kicked, or not let in.
    let isDimmed: Bool
    let isSelected: Bool
    let rowHeight: CGFloat
    let iconColWidth: CGFloat
    let indentWidth: CGFloat
    let activeState: ControlActiveState
    let menuTitle: String
    let select: () -> Void
    let menuAction: () -> Void
    var body: some View {
        SidebarRowBase(isSelected: isSelected, indent: indentWidth, rowHeight: rowHeight, activeState: activeState) {
            Image(systemName: item.systemImageName)
                .opacity(isDimmed ? 0.5 : 1)
                .frame(width: iconColWidth, alignment: .center)
                .overlay(alignment: .topTrailing) {
                    if unreadCount > 0 {
                        Circle()
                            .fill(wantsAttention ? Color.red : Color.accentColor)
                            .frame(width: 6, height: 6)
                            .offset(x: 2, y: -2)
                    }
                }
            Text(item.name).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                .opacity(isDimmed ? 0.5 : 1)
        }
        .contextMenu { Button(menuTitle, action: menuAction) }
        .onTapGesture(perform: select)
    }
}
