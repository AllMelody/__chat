import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(ChatStore.self) private var store
    @Environment(AppPreferences.self) private var prefs
    @Environment(\.controlActiveState) private var activeState

    @State private var draft = ""
    /// Bumped to ask the composer to take keyboard focus.
    @State private var composerFocusRequest = 0

    private let rowHeight: CGFloat = 24
    private let iconColWidth: CGFloat = 18
    private let indentWidth: CGFloat = 14
    private var onePixel: CGFloat { 1 / (NSScreen.main?.backingScaleFactor ?? 2) }

    private func focusComposer() {
        composerFocusRequest += 1
    }

    var body: some View {
        @Bindable var store = store
        let closing = store.sidebarItem(withID: store.pendingCloseConversationID)
        AutosavingSplitView(left: { leftPane }, right: { rightPane }, autosaveName: "MainSplitRightWidth")
            .onAppear { focusComposer() }
            .onChange(of: activeState) { _, new in if new == .key { focusComposer() } }
            .onChange(of: store.selectedItemID) { _, _ in focusComposer() }
            .sheet(isPresented: $store.isPresentingAddServer) { ServerFormView() }
            .sheet(isPresented: $store.isPresentingJoinChannel) { JoinChannelView() }
            .sheet(isPresented: $store.isPresentingChangeNickname) {
                if let server = store.server(withID: store.pendingNicknameServerID) {
                    ChangeNicknameView(server: server)
                }
            }
            .sheet(isPresented: $store.isPresentingEditServer) {
                Group {
                    if let server = store.server(withID: store.pendingEditServerID) {
                        ServerFormView(server: server)
                    } else {
                        Text("No server selected")
                            .padding(16)
                    }
                }
            }
            .sheet(isPresented: $store.isPresentingTopicEditor) {
                if let channel = store.selectedItem?.channel {
                    TopicEditorView(channel: channel)
                }
            }
            .confirmationDialog("Delete Server?", isPresented: $store.isPresentingDeleteServer,
                                presenting: store.server(withID: store.pendingDeleteServerID)) { server in
                Button("Delete", role: .destructive) { store.deleteServer(server) }
            } message: { server in
                Text("“\(server.name)” and its saved password will be removed. This can’t be undone.")
            }
            .confirmationDialog(closing?.channel != nil ? "Part Channel?" : "Close Conversation?",
                                isPresented: $store.isPresentingCloseConversation, presenting: closing) { conversation in
                Button(conversation.channel != nil ? "Part" : "Close") { store.closeConversation(conversation) }
            } message: { conversation in
                if let channel = conversation.channel {
                    Text("You’ll leave \(channel.name), and its messages will be cleared.")
                } else {
                    Text("Your messages with \(conversation.name) will be cleared.")
                }
            }
            // Lets the menu commands tell when this window is key, rather than Settings, say.
            .focusedSceneValue(store)
    }

    // MARK: - Left Pane
    private var leftPane: some View {
        VStack(spacing: 0) {
            if let topic = store.selectedItem?.channel?.topic {
                Text(topic)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .onTapGesture { store.isPresentingTopicEditor = true }
                Divider()
            }
            // No leading padding here: the log's left gutter comes from the text view's
            // container inset, so highlight washes can run edge to edge.
            LogTextView(logVersion: store.logVersion, selectionToken: store.selectedItemID, messages: currentMessages, thumbnailsByMessage: store.messageThumbnails, showThumbnails: prefs.showImageThumbnails,
                        findRequest: store.findRequest, onFindBarClosed: focusComposer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 2)

            Divider()
            ComposerTextField(text: $draft, placeholder: "Type a message…", focusRequest: composerFocusRequest,
                              completions: { store.nickCompletionCandidates }) {
                // Not sendable yet, with nobody to read it (SidebarItem.canSend): the line stays,
                // with the beep of a key that can't do anything here, rather than "Not connected."
                // in the log. An empty line just does nothing, as before.
                if !draft.isEmpty, let item = store.selectedItem, !item.canSend(draft) {
                    NSSound.beep()
                    return false
                }
                guard store.handleInputFromComposer(draft) else { return false }
                draft = ""
                return true
            }
            .padding(.leading, 6)
            .padding(.trailing, 4)
            .padding(.bottom, 2)
            .frame(height: 26)
        }
    }

    // MARK: - Right Pane
    private var rightPane: some View {
        AutosavingSplitView(left: {
            List {
                ForEach(currentUsers, id: \.self) { nick in
                    Text(nick)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        // Double-click someone to talk to them privately.
                        .onTapGesture(count: 2) {
                            if let server = store.selectedItem?.server { store.openPrivateConversation(with: nick, on: server) }
                        }
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, rowHeight)
        }, right: {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if store.servers.isEmpty {
                        Spacer()
                        Text("No servers configured.")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        Spacer()
                        Button("Add Server…") { store.isPresentingAddServer = true }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(6)
                    }
                    ForEach(store.servers) { server in
                        ServerRow(
                            server: server,
                            isSelected: store.selectedItemID == server.id,
                            rowHeight: rowHeight,
                            iconColWidth: iconColWidth,
                            activeState: activeState,
                            select: { store.selectedItemID = server.id },
                            connect: {
                                store.connect(server)
                                store.selectedItemID = server.id
                            },
                            disconnect: {
                                store.disconnect(server)
                                store.selectedItemID = server.id
                            },
                            joinChannelPrompt: {
                                store.pendingJoinServerID = server.id
                                store.isPresentingJoinChannel = true
                            },
                            changeNickname: { store.requestNicknameChange(on: server) },
                            editServer: {
                                store.pendingEditServerID = server.id
                                store.isPresentingEditServer = true
                            },
                            deleteServer: { store.requestDeletion(of: server) }
                        )
                        separator()
                        ForEach(server.channels) { ch in
                            let item = SidebarItem(server: server, kind: .channel(ch))
                            ConversationRow(
                                item: item,
                                unreadCount: ch.unreadCount,
                                wantsAttention: ch.mentionCount > 0,
                                isDimmed: !ch.joined,
                                isSelected: store.selectedItemID == ch.id,
                                rowHeight: rowHeight,
                                iconColWidth: iconColWidth,
                                indentWidth: indentWidth,
                                activeState: activeState,
                                menuTitle: "Part Channel",
                                select: { store.select(item) },
                                menuAction: { store.partChannel(ch) }
                            )
                            if ch.id != server.channels.last?.id || !server.privateConversations.isEmpty { separator() }
                        }
                        ForEach(server.privateConversations) { pm in
                            let item = SidebarItem(server: server, kind: .privateConversation(pm))
                            ConversationRow(
                                item: item,
                                unreadCount: pm.unreadCount,
                                wantsAttention: pm.unreadCount > 0,   // all of it was said to us
                                isDimmed: false,
                                isSelected: store.selectedItemID == pm.id,
                                rowHeight: rowHeight,
                                iconColWidth: iconColWidth,
                                indentWidth: indentWidth,
                                activeState: activeState,
                                menuTitle: "Close Conversation",
                                select: { store.select(item) },
                                menuAction: { store.closePrivateConversation(pm, from: server) }
                            )
                            if pm.id != server.privateConversations.last?.id { separator() }
                        }
                    }
                    Color.clear.frame(height: 12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contextMenu { Button("Add Server…") { store.isPresentingAddServer = true } }
        }, autosaveName: "RightPaneSplitHeight", isVertical: false)
    }

    private func separator() -> some View { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: onePixel) }

    // MARK: - Data accessors
    /// All of the stored log, which ChatStore.trimLogs keeps near the preferred length by
    /// dropping a batch of old lines now and then. Showing a window of exactly that length
    /// instead would lose a line at the top for each one gained, an edit of the whole text
    /// every time.
    private var currentMessages: [ChatMessage] {
        store.selectedItem?.log ?? []
    }
    /// The channel's members, which it keeps in order.
    private var currentUsers: [String] {
        store.selectedItem?.channel?.users ?? []
    }
}
