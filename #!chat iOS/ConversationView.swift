import SwiftUI

/// A server's log, or a channel's or private conversation's, with a field to type into below it.
struct ConversationView: View {
    @Environment(ChatStore.self) private var store
    @Environment(AppPreferences.self) private var prefs
    let item: SidebarItem
    @Binding var draft: String
    @State private var isShowingMembers = false
    @FocusState private var composerIsFocused: Bool
    /// Bumped each time the user sends something.
    @State private var sentCount = 0

    var body: some View {
        LogView(messages: item.log, thumbnails: prefs.showImageThumbnails ? store.messageThumbnails : [:], sentCount: sentCount)
            .safeAreaBar(edge: .bottom) { composer }
            .navigationTitle(item.name)
            .modifier(TopicSubtitle(channel: item.channel))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .inspector(isPresented: $isShowingMembers) {
                if let channel = item.channel {
                    MemberList(channel: channel, server: item.server)
                }
            }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            // A server takes only commands.
            TextField(item.isConversation ? "Message \(item.name)" : "Command, like /join #channel", text: $draft)
                .focused($composerIsFocused)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .glassEffect(.regular.interactive(), in: .capsule)
            Button("Send", systemImage: "arrow.up", action: send)
                .labelStyle(.iconOnly)
                .fontWeight(.semibold)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .disabled(draft.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func send() {
        // Return would take the keyboard away, and the next line is often on its way.
        composerIsFocused = true
        guard store.handleInputFromComposer(draft) else { return }
        draft = ""
        sentCount += 1
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if item.channel != nil {
            ToolbarItem(placement: .primaryAction) {
                Button("Members", systemImage: "person.2") { isShowingMembers.toggle() }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu("More", systemImage: "ellipsis") {
                switch item.kind {
                case .server:
                    ServerActions(server: item.server)
                case .channel:
                    Button("Topic…", systemImage: "text.quote") { store.isPresentingTopicEditor = true }
                    Divider()
                    Button("Part Channel…", systemImage: "xmark", role: .destructive) { store.requestClosing(item) }
                case .privateConversation:
                    Button("Close Conversation…", systemImage: "xmark", role: .destructive) { store.requestClosing(item) }
                }
            }
        }
    }
}

/// A channel's topic under its name. Applied whatever the topic, rather than only when there is
/// one, so that a topic coming or going doesn't make the log a new view, scrolled back to the end.
private struct TopicSubtitle: ViewModifier {
    let channel: IRCChannel?

    func body(content: Content) -> some View {
        if let channel {
            content.navigationSubtitle(channel.topic ?? "")
        } else {
            content
        }
    }
}

/// A channel's members. Tapping one talks to them privately.
private struct MemberList: View {
    @Environment(ChatStore.self) private var store
    let channel: IRCChannel
    let server: IRCServer

    var body: some View {
        List {
            Section("\(channel.users.count) Members") {
                ForEach(channel.users, id: \.self) { nick in
                    Button(nick) { store.openPrivateConversation(with: nick, on: server) }
                        .foregroundStyle(.primary)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Log

/// The log, one row a line. It follows the newest line, as lines arrive and as the keyboard
/// comes and goes, until the user scrolls away from it; scrolling back to it follows again.
///
/// The rows are laid out lazily, so the scroll view only estimates the height of those it
/// hasn't shown, and its bottom edge is a guess: scrolling there can land past the last line,
/// on nothing. Scrolling to the last line itself is exact, so that's what it does.
private struct LogView: View {
    let messages: [ChatMessage]
    let thumbnails: [UUID: [MessageThumbnail]]
    /// Bumped each time the user sends something: the log goes back to its newest line, as
    /// Messages does, and follows from there.
    let sentCount: Int
    @State private var position = ScrollPosition(idType: UUID.self)
    @State private var following = LogFollowing()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(messages) { message in
                    MessageRow(message: message, thumbnails: thumbnails[message.id] ?? [])
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, 6)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onAppear(perform: scrollToEnd)
        .onScrollTargetVisibilityChange(idType: UUID.self, threshold: 0.1) { ids in
            following.visibleIDs = Set(ids)
        }
        .onScrollPhaseChange { oldPhase, newPhase in
            switch (oldPhase, newPhase) {
            case (_, .interacting):
                following.followsEnd = false   // the user has the log in hand
            case (.interacting, .idle), (.decelerating, .idle):
                // Where they let it come to rest: following again if that's the end.
                following.followsEnd = messages.last.map { following.visibleIDs.contains($0.id) } ?? true
            default:
                break
            }
        }
        .onChange(of: messages.last?.id) {
            if following.followsEnd { scrollToEnd() }
        }
        .onChange(of: sentCount) {
            following.followsEnd = true
            scrollToEnd()
        }
        // The keyboard coming or going changes how much of the log shows.
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.containerSize.height - $0.contentInsets.top - $0.contentInsets.bottom }) { _, _ in
            if following.followsEnd { scrollToEnd() }
        }
    }

    private func scrollToEnd() {
        guard let last = messages.last else { return }
        position.scrollTo(id: last.id, anchor: .bottom)
    }
}

/// What LogView keeps track of as the log scrolls. A plain object, so that keeping track
/// doesn't redraw the log.
private final class LogFollowing {
    /// Whether to keep the newest line in view.
    var followsEnd = true
    /// The rows on screen, at least a little.
    var visibleIDs: Set<UUID> = []
}

/// One line of the log: the time, who said it, what they said with its web links tappable,
/// and thumbnails of the images it links to. A line that mentions us is highlighted.
private struct MessageRow: View {
    let message: ChatMessage
    let thumbnails: [MessageThumbnail]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.line(for: message))
                .font(.body)   // the size of what's typed in the composer
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
                .background {
                    // systemYellow adapts to light and dark; the alpha keeps the text readable.
                    if message.isHighlight { Color.yellow.opacity(0.15) }
                }
            ForEach(thumbnails, id: \.url) { thumbnail in
                ThumbnailView(thumbnail: thumbnail)
                    .padding(.horizontal, 12)
            }
        }
    }

    // The Mac's log colors: see LogTextView in the Mac app's ContentView.
    private static let myNickColor = Color(hue: 0.0, saturation: 0.75, brightness: 0.55)
    private static let otherNickColor = Color(hue: 0.13, saturation: 0.75, brightness: 0.55)

    /// Reads as the Mac's log does: "12:34 nick: text", "12:34 * nick waves", or for a message to
    /// some of a channel's members, "12:34 nick (@#chan): text".
    private static func line(for message: ChatMessage) -> AttributedString {
        var line = gray("\(Formatting.timeString(message.time)) ")
        if message.isPrivmsg, let nick = message.senderNick {
            var sender = AttributedString(nick)
            sender.foregroundColor = message.isFromMe ? myNickColor : otherNickColor
            if let statusTarget = message.statusTarget {
                sender += gray(" (\(statusTarget))")
            }
            if message.isAction {
                line += gray("* ") + sender + AttributedString(" ")
            } else {
                line += sender + gray(": ")
            }
        }
        var body = AttributedString(message.text)
        if message.isReply { body.foregroundColor = .secondary }
        for link in Formatting.webLinks(in: message.text) {
            let range = Range(link.range, in: message.text)!
            body[Range(range, in: body)!].link = link.url
        }
        return line + body
    }

    private static func gray(_ text: String) -> AttributedString {
        var string = AttributedString(text)
        string.foregroundColor = .secondary
        return string
    }
}

/// An image a line links to, at most 200 points either way, which opens the link when tapped.
/// Until it has loaded, a placeholder holds its place.
private struct ThumbnailView: View {
    let thumbnail: MessageThumbnail

    var body: some View {
        // Thumbnails are made from links that were URLs already.
        Link(destination: URL(string: thumbnail.url)!) {
            if let image = thumbnail.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 200, maxHeight: 200, alignment: .leading)
                    .clipShape(.rect(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(width: 200, height: 150)
            }
        }
    }
}
