import SwiftUI

/// The servers and their conversations in a sidebar, and the one selected beside it, or, on
/// most iPhones and in most orientations, one at a time.
struct ContentView: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Open to begin with, and stated rather than automatic, so that it says what's on screen.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// What's typed and not sent yet. One for the app, as on the Mac: it stays while the user
    /// looks at another conversation.
    @State private var draft = ""
    @State private var isPresentingSettings = false
    @State private var channelsToJoin = ""
    @State private var newNickname = ""

    var body: some View {
        @Bindable var store = store
        let closing = store.sidebarItem(withID: store.pendingCloseConversationID)
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            SidebarView(isPresentingSettings: $isPresentingSettings)
        } detail: {
            Group {
                if let item = store.selectedItem {
                    ConversationView(item: item, draft: $draft)
                        .id(item.id)
                } else {
                    ContentUnavailableView("No Conversation Selected", systemImage: "bubble.left.and.bubble.right")
                }
            }
            // Only side by side: one at a time, the edge swipe already goes back to the list.
            .modifier(SidebarEdgeSwipe(isEnabled: horizontalSizeClass == .regular) {
                withAnimation { columnVisibility = .all }
            })
        }
        .sheet(isPresented: $store.isPresentingAddServer) { ServerFormView() }
        .sheet(isPresented: $store.isPresentingEditServer) {
            if let server = store.server(withID: store.pendingEditServerID) {
                ServerFormView(server: server)
            }
        }
        .sheet(isPresented: $store.isPresentingTopicEditor) {
            if let channel = store.selectedItem?.channel {
                TopicEditorView(channel: channel)
            }
        }
        .sheet(isPresented: $isPresentingSettings) { SettingsView() }
        .alert("Join Channel", isPresented: $store.isPresentingJoinChannel) {
            TextField("#channel", text: $channelsToJoin)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Join", action: joinChannels)
            Button("Cancel", role: .cancel) { channelsToJoin = "" }
        }
        .alert("Change Nickname", isPresented: $store.isPresentingChangeNickname) {
            TextField("Nickname", text: $newNickname)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Change", action: changeNickname)
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: store.isPresentingChangeNickname) { _, isPresenting in
            // Start from the nickname in use.
            if isPresenting { newNickname = store.server(withID: store.pendingNicknameServerID)?.currentNick ?? "" }
        }
        .alert("Delete Server?", isPresented: $store.isPresentingDeleteServer,
               presenting: store.server(withID: store.pendingDeleteServerID)) { server in
            Button("Delete", role: .destructive) { store.deleteServer(server) }
        } message: { server in
            Text("“\(server.name)” and its saved password will be removed. This can’t be undone.")
        }
        .alert(closing?.channel != nil ? "Part Channel?" : "Close Conversation?",
               isPresented: $store.isPresentingCloseConversation, presenting: closing) { conversation in
            Button(conversation.channel != nil ? "Part" : "Close", role: .destructive) { store.closeConversation(conversation) }
        } message: { conversation in
            if let channel = conversation.channel {
                Text("You’ll leave \(channel.name), and its messages will be cleared.")
            } else {
                Text("Your messages with \(conversation.name) will be cleared.")
            }
        }
    }

    /// The sidebar as the split view shows it, and as it changes it while the app is in front.
    /// In the background the system lays the app out narrow for a moment, one thing at a time,
    /// and the split view then has the sidebar closed: taken at its word, it would stay closed
    /// on coming back to a screen wide enough for both.
    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding {
            columnVisibility
        } set: { visibility in
            if Platform.isAppActive { columnVisibility = visibility }
        }
    }

    /// Asks for the nickname typed, unless it's the one in use. One that isn't a nickname gets
    /// said so in the log.
    private func changeNickname() {
        let nick = newNickname.trimmingCharacters(in: .whitespaces)
        guard let server = store.server(withID: store.pendingNicknameServerID), nick != server.currentNick else { return }
        store.changeNickname(to: nick, on: server)
    }

    /// As for /join: several channels separated by commas, with `#` added where there's no prefix.
    private func joinChannels() {
        let channels = MessageRouter.channelNames(channelsToJoin.filter { !$0.isWhitespace })
        channelsToJoin = ""
        guard !channels.isEmpty, let server = store.server(withID: store.pendingJoinServerID) else { return }
        store.joinChannels(channels, on: server)
    }
}

/// A swipe in from the left edge shows the sidebar where the split view has hidden it, in a
/// window too narrow for both side by side.
///
/// A deliberate exception to iOS conventions, which the rest of the app follows: the system's
/// split view, like Mail's, only opens a hidden sidebar from its toolbar button. Only a mostly
/// sideways drag that starts at the edge counts, so scrolling and selecting text in the log go
/// on as before.
private struct SidebarEdgeSwipe: ViewModifier {
    let isEnabled: Bool
    let showSidebar: () -> Void

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { drag in
                    guard drag.startLocation.x < 24, drag.translation.width > 50,
                          abs(drag.translation.height) < drag.translation.width else { return }
                    showSidebar()
                },
            isEnabled: isEnabled
        )
    }
}
