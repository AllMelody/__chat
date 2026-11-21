import SwiftUI

struct SidebarView: View {
    @Environment(ChatStore.self) private var store
    @Binding var isPresentingSettings: Bool

    var body: some View {
        List(selection: selection) {
            ForEach(store.servers) { server in
                Section {
                    if server.connectionStatus == .disconnected || server.connectionStatus == .connectionTimeout {
                        // A tap shows what can be done, Connect first, rather than an empty log.
                        Menu { ServerActions(server: server, offersLog: true) } label: { ServerRow(server: server) }
                            .tint(.primary)   // the name as in any row, not in the accent color
                    } else {
                        ServerRow(server: server)
                            .tag(server.id)
                            .contextMenu { ServerActions(server: server) }
                            // Swiping disconnects, as it trashes a mail: all the way across does it
                            // at once. Red but not destructive, which would take the row away as if
                            // deleted; disconnecting keeps it.
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(server.isConnected ? "Disconnect" : "Cancel", systemImage: "bolt.horizontal.circle") {
                                    store.disconnect(server)
                                }
                                .tint(.red)
                            }
                    }
                    ForEach(server.channels) { channel in
                        ConversationRow(item: SidebarItem(server: server, kind: .channel(channel)),
                                        unreadCount: channel.unreadCount,
                                        wantsAttention: channel.mentionCount > 0,
                                        isDimmed: !channel.joined)
                            .tag(channel.id)
                    }
                    ForEach(server.privateConversations) { pm in
                        ConversationRow(item: SidebarItem(server: server, kind: .privateConversation(pm)),
                                        unreadCount: pm.unreadCount,
                                        wantsAttention: pm.unreadCount > 0,   // all of it was said to us
                                        isDimmed: false)
                            .tag(pm.id)
                    }
                }
            }
        }
        .navigationTitle("#!chat")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gear") { isPresentingSettings = true }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Add Server", systemImage: "plus") { store.isPresentingAddServer = true }
            }
        }
        .overlay {
            if store.servers.isEmpty {
                ContentUnavailableView {
                    Label("No Servers", systemImage: "network")
                } description: {
                    Text("Add an IRC server to chat on.")
                } actions: {
                    Button("Add Server…") { store.isPresentingAddServer = true }
                }
            }
        }
    }

    /// Choosing a row selects it as the Mac's sidebar does, which marks a conversation read.
    private var selection: Binding<UUID?> {
        Binding {
            store.selectedItemID
        } set: { id in
            if let item = store.sidebarItem(withID: id) {
                store.select(item)
            } else {
                store.selectedItemID = id
            }
        }
    }
}

/// A server's row: its name, and its state in the icon's color and a spinner while connecting.
private struct ServerRow: View {
    let server: IRCServer

    var body: some View {
        Label {
            HStack {
                Text(server.name)
                    .fontWeight(.semibold)
                if server.connectionStatus == .connecting || server.connectionStatus == .reconnecting {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        } icon: {
            Image(systemName: SidebarItem(server: server, kind: .server).systemImageName)
                .foregroundStyle(server.connectionStatus.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)   // the whole row takes the tap
    }
}

/// A channel or private conversation, with a dot for what's unread: red when some of it was
/// meant for us (a mention, a private message).
private struct ConversationRow: View {
    @Environment(ChatStore.self) private var store
    let item: SidebarItem
    let unreadCount: Int
    let wantsAttention: Bool
    /// A channel we're not in right now: disconnected, kicked, or not let in.
    let isDimmed: Bool

    var body: some View {
        Label {
            Text(item.name)
        } icon: {
            Image(systemName: item.systemImageName)
                .overlay(alignment: .topTrailing) {
                    if unreadCount > 0 {
                        Circle()
                            .fill(wantsAttention ? Color.red : Color.accentColor)
                            .frame(width: 8, height: 8)
                            .offset(x: 3, y: -3)
                    }
                }
        }
        .opacity(isDimmed ? 0.5 : 1)
        // No confirmation, as in the Mac's sidebar menu; a full swipe would be too easy to make
        // by mistake, though.
        .contextMenu { closeButton }
        .swipeActions(allowsFullSwipe: false) { closeButton }
    }

    private var closeButton: some View {
        Button(item.channel != nil ? "Part Channel" : "Close Conversation", systemImage: "xmark", role: .destructive) {
            store.closeConversation(item)
        }
    }
}

/// What can be done to a server, for its menus.
struct ServerActions: View {
    @Environment(ChatStore.self) private var store
    let server: IRCServer
    /// For the list's menu of a disconnected server, whose row doesn't open its log: a way in
    /// anyway, to read why it isn't connected.
    var offersLog = false

    var body: some View {
        switch server.connectionStatus {
        case .connected:
            Button("Disconnect", systemImage: "bolt.horizontal.circle") { store.disconnect(server) }
            Button("Join Channel…", systemImage: "plus.bubble") {
                store.pendingJoinServerID = server.id
                store.isPresentingJoinChannel = true
            }
        case .connecting, .reconnecting:
            Button("Cancel Connection", systemImage: "xmark.circle") { store.disconnect(server) }
        case .disconnected, .connectionTimeout:
            Button("Connect", systemImage: "bolt.horizontal") { store.connect(server) }
        }
        if offersLog {
            Button("Show Log", systemImage: "doc.plaintext") { store.select(SidebarItem(server: server, kind: .server)) }
        }
        Divider()
        Button("Edit Server…", systemImage: "pencil") {
            store.pendingEditServerID = server.id
            store.isPresentingEditServer = true
        }
        Button("Delete Server…", systemImage: "trash", role: .destructive) { store.requestDeletion(of: server) }
    }
}
