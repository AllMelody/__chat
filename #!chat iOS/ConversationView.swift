import SwiftUI

/// A server's log, or a channel's or private conversation's, with a field to type into below it.
struct ConversationView: View {
    @Environment(ChatStore.self) private var store
    @Environment(AppPreferences.self) private var prefs
    let item: SidebarItem
    @Binding var draft: String
    @State private var isShowingMembers = false
    @FocusState private var composerIsFocused: Bool

    var body: some View {
        LogView(messages: item.log, thumbnails: prefs.showImageThumbnails ? store.messageThumbnails : [:])
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

/// The log, one row a line, kept scrolled to the end while the end is in view: as lines
/// arrive, and as the keyboard comes and goes.
private struct LogView: View {
    let messages: [ChatMessage]
    let thumbnails: [UUID: [MessageThumbnail]]
    @State private var position = ScrollPosition(edge: .bottom)

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
        .onScrollGeometryChange(for: LogGeometry.self, of: LogGeometry.init) { old, new in
            if old.showsEnd, new.sizes != old.sizes {
                position.scrollTo(edge: .bottom)
            }
        }
    }
}

/// What LogView watches of its scroll view.
private struct LogGeometry: Equatable {
    /// The content's height, and the height of the part of the scroll view it shows through.
    /// One changes when lines come or go, the other when the keyboard does.
    var sizes: [CGFloat]
    /// The end of the log is in view, or nearly.
    var showsEnd: Bool

    nonisolated init(_ geometry: ScrollGeometry) {
        let visibleHeight = geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom
        sizes = [geometry.contentSize.height, visibleHeight]
        let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height - geometry.contentInsets.bottom
        showsEnd = visibleBottom >= geometry.contentSize.height - 8
    }
}

/// One line of the log: the time, who said it, what they said with its web links tappable,
/// and thumbnails of the images it links to. A line that mentions us is highlighted.
private struct MessageRow: View {
    let message: ChatMessage
    let thumbnails: [MessageThumbnail]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.line(for: message))
                .font(.subheadline)
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
