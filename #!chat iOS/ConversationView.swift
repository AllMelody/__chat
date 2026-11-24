import SwiftUI

/// A server's log, or a channel's or private conversation's, with a field to type into below it.
struct ConversationView: View {
    @Environment(ChatStore.self) private var store
    @Environment(AppPreferences.self) private var prefs
    let item: SidebarItem
    @Binding var draft: String
    @State private var isShowingMembers = false
    @FocusState private var composerIsFocused: Bool
    /// Whether the keyboard moves the log and the field: not until the field is typed into.
    @State private var followsKeyboard = false
    /// Bumped each time the user sends something.
    @State private var sentCount = 0

    var body: some View {
        LogView(messages: item.log, thumbnails: prefs.showImageThumbnails ? store.messageThumbnails : [:], sentCount: sentCount)
            .safeAreaBar(edge: .bottom) { composer }
            // Going back to the list with the keyboard up, the system keeps the keyboard for this
            // screen, and brings it back for an instant as the next conversation slides in, with
            // no field for it. The log would make room for it within the slide, and spring back
            // from under the bottom of the screen. A keyboard nobody asked for is left alone.
            .ignoresSafeArea(.keyboard, edges: followsKeyboard ? [] : .bottom)
            .onChange(of: composerIsFocused) { if composerIsFocused { followsKeyboard = true } }
            .navigationTitle(item.name)
            .modifier(TopicSubtitle(channel: item.channel))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .inspector(isPresented: $isShowingMembers) {
                if let channel = item.channel {
                    MemberList(channel: channel, server: item.server) { isShowingMembers = false }
                }
            }
    }

    private var composer: some View {
        // The button stays beside the last line as the field grows.
        HStack(alignment: .bottom, spacing: 8) {
            // As in Messages, Return breaks the line and only the button sends, which leaves the
            // keyboard where it is for the next one. Each line goes out as a message of its own.
            // A server takes only commands.
            TextField(item.isConversation ? "Message \(item.name)" : "Command, like /join #channel", text: $draft, axis: .vertical)
                .focused($composerIsFocused)
                .lineLimit(1...5)
                .textInputAutocapitalization(.sentences)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                // The field itself is only as tall as its text: a tap on the space around it,
                // anywhere in the capsule, is one on the field too. Behind the field rather
                // than over it, so that taps on the text stay the field's own.
                .background {
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { composerIsFocused = true }
                }
                // A capsule around one line, and the same corners around more.
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
            Button("Send", systemImage: "arrow.up", action: send)
                .labelStyle(.iconOnly)
                .fontWeight(.semibold)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .disabled(!item.canSend(draft))   // off until there's someone to read it
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func send() {
        guard item.canSend(draft), store.handleInputFromComposer(draft) else { return }
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
    /// Puts the list away, for the log to show the answer to a Whois.
    let close: () -> Void

    var body: some View {
        List {
            Section("\(channel.users.count) Members") {
                ForEach(channel.users, id: \.self) { nick in
                    Button(nick) { store.openPrivateConversation(with: nick, on: server) }
                        .foregroundStyle(.primary)
                        .contextMenu {
                            Button("Private Message", systemImage: "bubble.left") { store.openPrivateConversation(with: nick, on: server) }
                                .disabled(server.currentNick.map { IRCName.equal(nick, $0) } ?? false)
                            Button("Whois", systemImage: "info.circle") {
                                store.whois(nick, on: server)
                                close()
                            }
                        }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Log

/// The log, one row a line. It opens at its newest line and stays there, as lines arrive and as
/// the keyboard comes and goes, until the user scrolls away from it.
///
/// Staying there is the scroll view's own doing, by its bottom anchor. Following the newest row
/// by its id instead goes wrong: where a scroll view puts a row it's keeping in view, once the
/// keyboard has gone or the bars have come in around a log just opened, is past the end by the
/// height of the composer.
private struct LogView: View {
    let messages: [ChatMessage]
    let thumbnails: [UUID: [MessageThumbnail]]
    /// Bumped each time the user sends something: the log goes back to its newest line, as
    /// Messages does.
    let sentCount: Int
    @State private var position = ScrollPosition(edge: .bottom)
    /// The width the log is laid out at: the room it has, a moment late.
    @State private var width: CGFloat?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(messages) { message in
                    MessageRow(message: message, thumbnails: thumbnails[message.id] ?? [])
                }
            }
            .padding(.vertical, 6)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.top, for: .alignment)   // a log shorter than the screen starts at its top
        .scrollPosition($position)
        .onChange(of: sentCount) { position.scrollTo(edge: .bottom) }
        // A log short enough to be all in view sits at its top, which to the scroll view isn't
        // its end, so it isn't kept there. When the keyboard, or one more line, leaves it too
        // tall for the room it has, it goes to its end.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height <= geometry.containerSize.height
        } action: { _, isAllInView in
            if !isAllInView { position.scrollTo(edge: .bottom) }
        }
        // The sidebar opening or closing changes the room the log has, within its animation.
        // Every line wraps again, the log's height changes by a lot, and staying at the end
        // means scrolling by as much: done within the animation, UIKit animates that too, and
        // sweeps the log across the screen. So the log takes its new width just after instead,
        // all at once. Until then it keeps its old one, against the edge the sidebar isn't on.
        .frame(width: width)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { room in
            guard room > 0 else { return }   // not laid out yet
            Task { width = room }
        }
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

/// An image a line links to, which opens the link when tapped. At most 370 × 280 points: most of
/// a phone's width, and no bigger on a wider screen; a narrower phone gets the width there is.
/// That's more pixels than a thumbnail has (600 at most), so a big one is scaled up, a little
/// soft. Until it has loaded, a placeholder holds its place.
private struct ThumbnailView: View {
    let thumbnail: MessageThumbnail
    private static let maxWidth: CGFloat = 370
    private static let maxHeight: CGFloat = 280

    var body: some View {
        // Thumbnails are made from links that were URLs already.
        Link(destination: URL(string: thumbnail.url)!) {
            if let image = thumbnail.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    // Rounded before it's framed: the frame is wider than an image that's
                    // tall or square.
                    .clipShape(.rect(cornerRadius: 6))
                    .frame(maxWidth: Self.maxWidth, maxHeight: Self.maxHeight, alignment: .leading)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .frame(maxWidth: Self.maxWidth)
            }
        }
    }
}
