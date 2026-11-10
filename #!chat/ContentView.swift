import SwiftUI
import AppKit

// MARK: - Content View & Layout

struct ContentView: View {
    @Environment(ChatStore.self) private var model
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
        @Bindable var model = model
        let closing = model.sidebarItem(withID: model.pendingCloseConversationID)
        AutosavingSplitView(left: { leftPane }, right: { rightPane }, autosaveName: "MainSplitRightWidth")
            .onAppear { focusComposer() }
            .onChange(of: activeState) { _, new in if new == .key { focusComposer() } }
            .onChange(of: model.selectedNodeID) { _, _ in focusComposer() }
            .sheet(isPresented: $model.isPresentingAddServer) { ServerFormView() }
            .sheet(isPresented: $model.isPresentingJoinChannel) { JoinChannelView() }
            .sheet(isPresented: $model.isPresentingEditServer) {
                Group {
                    if let server = model.server(withID: model.pendingEditServerID) {
                        ServerFormView(server: server)
                    } else {
                        Text("No server selected")
                            .padding(16)
                    }
                }
            }
            .sheet(isPresented: $model.isPresentingTopicEditor) {
                if let channel = model.selectedItem?.channel {
                    TopicEditorView(channel: channel)
                }
            }
            .confirmationDialog("Delete Server?", isPresented: $model.isPresentingDeleteServer,
                                presenting: model.server(withID: model.pendingDeleteServerID)) { server in
                Button("Delete", role: .destructive) { model.deleteServer(server) }
            } message: { server in
                Text("“\(server.name)” and its saved password will be removed. This can’t be undone.")
            }
            .confirmationDialog(closing?.channel != nil ? "Part Channel?" : "Close Conversation?",
                                isPresented: $model.isPresentingCloseConversation, presenting: closing) { conversation in
                Button(conversation.channel != nil ? "Part" : "Close") { model.closeConversation(conversation) }
            } message: { conversation in
                if let channel = conversation.channel {
                    Text("You’ll leave \(channel.name), and its messages will be cleared.")
                } else {
                    Text("Your messages with \(conversation.name) will be cleared.")
                }
            }
            // Lets the menu commands tell when this window is key, rather than Settings, say.
            .focusedSceneValue(model)
    }

    // MARK: - Left Pane
    private var leftPane: some View {
        VStack(spacing: 0) {
            if let topic = model.selectedItem?.channel?.topic {
                Text(topic)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .onTapGesture { model.isPresentingTopicEditor = true }
                Divider()
            }
            // No leading padding here: the log's left gutter comes from the text view's
            // container inset, so highlight washes can run edge to edge.
            LogTextView(logVersion: model.logVersion, selectionToken: model.selectedNodeID, messages: currentMessages, thumbnailsByMessage: model.messageThumbnails, showThumbnails: prefs.showImageThumbnails,
                        findRequest: model.findRequest, onFindBarClosed: focusComposer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 2)

            Divider()
            ComposerTextField(text: $draft, placeholder: "Type a message…", focusRequest: composerFocusRequest,
                              completions: { model.nickCompletionCandidates }) {
                guard model.handleInputFromComposer(draft) else { return false }
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
                            if let server = model.selectedItem?.server { model.openPrivateConversation(with: nick, on: server) }
                        }
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, rowHeight)
        }, right: {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.servers.isEmpty {
                        Spacer()
                        Text("No servers configured.")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        Spacer()
                        Button("Add Server…") { model.isPresentingAddServer = true }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(6)
                    }
                    ForEach(model.servers) { server in
                        ServerRow(
                            server: server,
                            isSelected: model.selectedNodeID == server.id,
                            rowHeight: rowHeight,
                            iconColWidth: iconColWidth,
                            activeState: activeState,
                            select: { model.selectedNodeID = server.id },
                            connect: {
                                model.connect(server)
                                model.selectedNodeID = server.id
                            },
                            disconnect: {
                                model.disconnect(server)
                                model.selectedNodeID = server.id
                            },
                            joinChannelPrompt: {
                                model.pendingJoinServerID = server.id
                                model.isPresentingJoinChannel = true
                            },
                            editServer: {
                                model.pendingEditServerID = server.id
                                model.isPresentingEditServer = true
                            },
                            deleteServer: { model.requestDeletion(of: server) }
                        )
                        separator()
                        ForEach(server.channels) { ch in
                            let node = SidebarItem(server: server, kind: .channel(ch))
                            ConversationRow(
                                node: node,
                                unreadCount: ch.unreadCount,
                                wantsAttention: ch.mentionCount > 0,
                                isDimmed: !ch.joined,
                                isSelected: model.selectedNodeID == ch.id,
                                rowHeight: rowHeight,
                                iconColWidth: iconColWidth,
                                indentWidth: indentWidth,
                                activeState: activeState,
                                menuTitle: "Part Channel",
                                select: { model.select(node) },
                                menuAction: { model.partChannel(ch) }
                            )
                            if ch.id != server.channels.last?.id || !server.privateMessages.isEmpty { separator() }
                        }
                        ForEach(server.privateMessages) { pm in
                            let node = SidebarItem(server: server, kind: .privateMessage(pm))
                            ConversationRow(
                                node: node,
                                unreadCount: pm.unreadCount,
                                wantsAttention: pm.unreadCount > 0,   // all of it was said to us
                                isDimmed: false,
                                isSelected: model.selectedNodeID == pm.id,
                                rowHeight: rowHeight,
                                iconColWidth: iconColWidth,
                                indentWidth: indentWidth,
                                activeState: activeState,
                                menuTitle: "Close Conversation",
                                select: { model.select(node) },
                                menuAction: { model.closePrivateMessage(pm, from: server) }
                            )
                            if pm.id != server.privateMessages.last?.id { separator() }
                        }
                    }
                    Color.clear.frame(height: 12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contextMenu { Button("Add Server…") { model.isPresentingAddServer = true } }
        }, autosaveName: "RightPaneSplitHeight", isVertical: false)
    }

    private func separator() -> some View { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: onePixel) }

    // MARK: - Data accessors
    /// All of the stored log, which ChatStore.trimLogs keeps near the preferred length by
    /// dropping a batch of old lines now and then. Showing a window of exactly that length
    /// instead would lose a line at the top for each one gained, an edit of the whole text
    /// every time.
    private var currentMessages: [ChatMessage] {
        model.selectedItem?.log ?? []
    }
    /// The channel's members, which it keeps in order.
    private var currentUsers: [String] {
        model.selectedItem?.channel?.users ?? []
    }
}

// MARK: - Composer (NSTextField wrapper to avoid placeholder shift on focus change)

private struct ComposerTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    /// Each change moves keyboard focus into the field.
    let focusRequest: Int
    /// The nicknames Tab can complete to here, likeliest first. Asked for when Tab is pressed.
    let completions: () -> [String]
    /// Return was pressed. Says whether the line was dealt with, which is what puts it in the
    /// history that ↑ and ↓ go through.
    let onSubmit: () -> Bool

    /// Newlines show as this symbol, so the field stays one line; the binding `text` keeps the
    /// real newlines for sending. Unlike the `\n` it stands for, nobody types it.
    private static let newlineSymbol: Character = "⏎"
    private static let newlineSymbolColor = NSColor.secondaryLabelColor

    private static func flatten(_ s: String) -> String {
        String(s.map { $0.isNewline ? newlineSymbol : $0 })
    }
    private static func unflatten(_ s: String) -> String {
        String(s.map { $0 == newlineSymbol ? "\n" : $0 })
    }

    /// Colorizes newline symbols in the field editor's text storage.
    /// Uses textStorage directly so the NSTextField's intrinsic size is unaffected.
    private static func colorizeNewlineSymbols(in textField: NSTextField) {
        guard let editor = textField.currentEditor() as? NSTextView,
              let storage = editor.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        // Reset foreground color to default (prevents color bleed from typing near symbols)
        storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: fullRange)
        // Color each newline symbol
        let text = storage.string
        for range in text.ranges(of: String(newlineSymbol)) {
            storage.addAttribute(.foregroundColor, value: newlineSymbolColor, range: NSRange(range, in: text))
        }
    }

    /// The text field. In single-line mode, which keeps the placeholder from shifting, AppKit
    /// pastes newlines as spaces; so its cell hands out a field editor of our own that pastes
    /// them as symbols instead.
    final class Field: NSTextField {
        override class var cellClass: AnyClass? {
            get { Cell.self }
            set {}
        }
    }

    final class Cell: NSTextFieldCell {
        private let editor: FieldEditor = {
            let editor = FieldEditor()
            editor.isFieldEditor = true
            return editor
        }()

        override func fieldEditor(for controlView: NSView) -> NSTextView? { editor }
    }

    final class FieldEditor: NSTextView {
        override func paste(_ sender: Any?) {
            guard let pasted = NSPasteboard.general.string(forType: .string) else { return super.paste(sender) }
            insertText(ComposerTextField.flatten(pasted), replacementRange: selectedRange())
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ComposerTextField
        var lastFocusRequest: Int
        private var history = InputHistory()
        /// The nickname Tab last put in, for as long as the text stays as that left it: which
        /// of the matches it is, and where it sits. Another Tab swaps in the next match.
        private var completion: (matches: [String], index: Int, range: NSRange)?
        /// Set while a completion is going in, the one text change that doesn't end it.
        private var isCompleting = false

        init(_ parent: ComposerTextField) {
            self.parent = parent
            self.lastFocusRequest = parent.focusRequest
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = ComposerTextField.unflatten(tf.stringValue)
            if !isCompleting { completion = nil }
            // After every change, so text typed next to a symbol doesn't take its color.
            if tf.stringValue.contains(ComposerTextField.newlineSymbol) {
                ComposerTextField.colorizeNewlineSymbols(in: tf)
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                let line = parent.text
                if parent.onSubmit() { history.add(line) }
            // Tab and Shift-Tab complete nicknames; neither leaves the field.
            case #selector(NSResponder.insertTab(_:)):
                completeNick(in: textView, step: 1)
            case #selector(NSResponder.insertBacktab(_:)):
                completeNick(in: textView, step: -1)
            // In a one-line field there's nowhere up or down to go but through what was sent.
            case #selector(NSResponder.moveUp(_:)):
                if let line = history.older(than: parent.text) { replaceText(in: textView, with: line) }
            case #selector(NSResponder.moveDown(_:)):
                if let line = history.newer() { replaceText(in: textView, with: line) }
            default:
                return false
            }
            return true
        }

        /// Completes the word before the cursor to a nickname, or, straight after a completion,
        /// moves on to the match `step` places along.
        private func completeNick(in textView: NSTextView, step: Int) {
            let cursor = textView.selectedRange()
            if let completion, cursor.length == 0, cursor.location == NSMaxRange(completion.range) {
                let count = completion.matches.count
                insertCompletion((completion.index + step + count) % count, of: completion.matches,
                                 replacing: completion.range, in: textView)
                return
            }
            // Offsets are the same with newlines as with the symbols that stand for them.
            let text = ComposerTextField.unflatten(textView.string)
            guard cursor.length == 0, let partial = NickCompletion.partialWord(in: text, endingAt: cursor.location) else { return }
            let matches = NickCompletion.matches(for: (text as NSString).substring(with: partial), among: parent.completions())
            guard !matches.isEmpty else { return }
            insertCompletion(0, of: matches, replacing: partial, in: textView)
        }

        private func insertCompletion(_ index: Int, of matches: [String], replacing range: NSRange, in textView: NSTextView) {
            let insertion = NickCompletion.insertion(for: matches[index], atStartOfLine: range.location == 0)
            isCompleting = true
            textView.insertText(insertion, replacementRange: range)
            isCompleting = false
            completion = (matches, index, NSRange(location: range.location, length: (insertion as NSString).length))
        }

        /// Swaps the field's whole text, as an edit like any other: it reaches the binding and
        /// can be undone.
        private func replaceText(in textView: NSTextView, with text: String) {
            textView.insertText(ComposerTextField.flatten(text),
                                replacementRange: NSRange(location: 0, length: (textView.string as NSString).length))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let tf = Field()
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = .systemFont(ofSize: NSFont.systemFontSize)
        // Fixed-baseline single-line layout. Without this, the unfocused cell measures text
        // via the multiline path while the focused field editor uses single-line metrics,
        // and the sub-pixel disagreement makes the text/placeholder shift on focus change.
        tf.usesSingleLineMode = true
        tf.lineBreakMode = .byTruncatingTail
        tf.maximumNumberOfLines = 1
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        // Explicit attributes so the focused and unfocused draw paths use identical
        // font/metrics for the placeholder instead of each deriving their own defaults.
        let placeholderParagraph = NSMutableParagraphStyle()
        placeholderParagraph.lineBreakMode = .byTruncatingTail
        tf.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor,
            .paragraphStyle: placeholderParagraph
        ])
        tf.delegate = context.coordinator
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)

        DispatchQueue.main.async { tf.window?.makeFirstResponder(tf) }
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            // Not when it already has focus: AppKit selects all the text of a field that takes
            // focus, and the next key would replace a half-typed message. For the same reason
            // a draft that regains focus gets its insertion point back at the end.
            if tf.currentEditor() == nil, tf.window?.makeFirstResponder(tf) == true {
                tf.currentEditor()?.selectedRange = NSRange(location: (tf.stringValue as NSString).length, length: 0)
            }
        }
        let flat = Self.flatten(text)
        if tf.stringValue != flat {
            tf.stringValue = flat
        }
    }
}

extension NSAttributedString.Key {
    /// Marks the text of a nick-mention line; the value is the wash NSColor. Drawn by
    /// LogLayoutManager across the full line width instead of just behind the glyphs.
    static let ircHighlightLine = NSAttributedString.Key("ircHighlightLine")
}

// MARK: - Log View (NSTextView wrapper)

/// TextKit 1 layout manager for the chat log. For ranges tagged .ircHighlightLine it fills
/// each line fragment edge to edge with the marker's color, underneath normal background
/// and selection drawing (super runs after, so selection stays visible on top).
private final class LogLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage, let textView = textContainers.first?.textView {
            let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            storage.enumerateAttribute(.ircHighlightLine, in: charRange, options: []) { value, range, _ in
                guard let color = value as? NSColor else { return }
                color.setFill()
                let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                self.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, _, _ in
                    // Full view width on purpose (not the fragment rect), so the wash also
                    // covers the container inset gutters.
                    NSRect(x: 0, y: rect.minY + origin.y, width: textView.bounds.width, height: rect.height)
                        .fill(using: .sourceOver)
                }
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

private struct LogTextView: NSViewRepresentable {
    /// Bumped on every log change in the app; being a property is what gets the view updated.
    let logVersion: Int
    let selectionToken: UUID?
    let messages: [ChatMessage]
    let thumbnailsByMessage: [UUID: [MessageThumbnail]]
    let showThumbnails: Bool
    /// The latest Find command (Edit ▸ Find), carried out once when its number is new.
    let findRequest: ChatStore.FindRequest?
    /// The find bar went away, leaving keyboard focus on the log, where typing does nothing.
    let onFindBarClosed: () -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var lastSelectionToken: UUID?
        var isPinnedToBottom: Bool = true
        var boundsObserver: Any?
        var frameObserver: Any?
        var findBarObservation: NSKeyValueObservation?
        var onFindBarClosed: () -> Void = {}
        var lastFindRequest: Int?
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        // Incremental rendering bookkeeping: the lines now in textStorage, in order, with the
        // thumbnail fingerprint each was rendered with (to plan the next update from) and its
        // length in the storage (to find where each one sits).
        var renderedLines: [LogUpdate.Line] = []
        var renderedLengths: [Int] = []
        /// Start of the day the storage was last fully rendered on. Timestamps leave the date
        /// off for "today", so once the day turns every line needs re-rendering.
        var renderedDay: Date?

        deinit {
            if let observer = boundsObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = frameObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        /// Opens links in the browser. Everything rendered as a link is a web link already
        /// (Formatting.webLinks); checking again here keeps a click from ever opening anything else.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = link as? URL ?? (link as? String).flatMap(URL.init(string:))
            guard let url, ["http", "https"].contains(url.scheme?.lowercased()) else { return false }
            NSWorkspace.shared.open(url)
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true

        // Explicit TextKit 1 stack so the view uses LogLayoutManager (which draws nick
        // highlights edge to edge). NSTextView(frame:) would build a TextKit 2 view whose
        // compatibility-mode layout manager we can't substitute.
        let textStorage = NSTextStorage()
        let layoutManager = LogLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        // The designated initializer doesn't apply the convenience init's sizing defaults;
        // without a huge maxSize the view can't grow with its content.
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        // Horizontal inset is the log's left gutter; keeping it inside the text view lets
        // highlight washes span the full view width.
        textView.textContainerInset = NSSize(width: 4, height: 2)
        textView.usesFontPanel = false
        // Edit ▸ Find shows a find bar above the log, and highlights matches as they're typed.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isContinuousSpellCheckingEnabled = false
        textView.delegate = context.coordinator
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]

        scroll.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        // Weak captures: the coordinator owns the observer tokens, and the tokens hold
        // these closures — a strong capture would be a retain cycle that keeps the whole
        // text-view stack alive and prevents deinit from ever removing the observers.
        let coordinator = context.coordinator
        coordinator.boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: nil) { [weak coordinator] _ in
            guard let coordinator, let tv = coordinator.textView, let sv = coordinator.scrollView else { return }
            coordinator.isPinnedToBottom = isAtBottom(textView: tv, scrollView: sv)
        }
        scroll.postsFrameChangedNotifications = true
        coordinator.frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak coordinator] _ in
            guard let coordinator, let tv = coordinator.textView else { return }
            if coordinator.isPinnedToBottom {
                tv.scrollToEndOfDocument(nil)
            }
        }
        coordinator.onFindBarClosed = onFindBarClosed
        coordinator.findBarObservation = scroll.observe(\.isFindBarVisible, options: [.new]) { [weak coordinator] _, change in
            guard change.newValue == false else { return }
            MainActor.assumeIsolated { coordinator?.onFindBarClosed() }
        }
        _ = apply(messages: messages, to: textView, coordinator: coordinator, forceFullRebuild: true)
        textView.scrollToEndOfDocument(nil)
        coordinator.lastSelectionToken = selectionToken
        coordinator.lastFindRequest = findRequest?.number
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.onFindBarClosed = onFindBarClosed

        let selectionChanged = coordinator.lastSelectionToken != selectionToken
        let dayChanged = coordinator.renderedDay != Calendar.current.startOfDay(for: .now)
        if selectionChanged { coordinator.isPinnedToBottom = true }
        // Where the reader is, before the text changes under them.
        let followsNewLines = coordinator.isPinnedToBottom
        let origin = nsView.contentView.bounds.origin

        let removedHeight = apply(messages: messages, to: textView, coordinator: coordinator, forceFullRebuild: selectionChanged || dayChanged)
        coordinator.lastSelectionToken = selectionToken

        if let removedHeight {
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            // Use CATransaction to disable implicit animations that cause flickering
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if followsNewLines {
                textView.scrollToEndOfDocument(nil)
            } else if removedHeight > 0 {
                // Lines trimmed off the top would pull the text up from under someone reading
                // back; move the view up with it.
                nsView.contentView.scroll(to: NSPoint(x: origin.x, y: max(0, origin.y - removedHeight)))
                nsView.reflectScrolledClipView(nsView.contentView)
            }
            CATransaction.commit()
        }

        if let findRequest, coordinator.lastFindRequest != findRequest.number {
            coordinator.lastFindRequest = findRequest.number
            // The text finder works for the view with keyboard focus, and takes its action from
            // a menu item's tag.
            textView.window?.makeFirstResponder(textView)
            let item = NSMenuItem()
            item.tag = findRequest.action.rawValue
            textView.performTextFinderAction(item)
        }
    }

    // Cache commonly used attributes for performance
    private static let sharedParagraphStyle: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.minimumLineHeight = 18
        return paragraph
    }()
    
    private static let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    /// Background for lines that mention our nick. systemYellow adapts to light/dark; the
    /// alpha keeps label-colored text readable on top of it.
    private static let highlightBackgroundColor = NSColor.systemYellow.withAlphaComponent(0.15)

    /// Centers the glyphs inside the enforced minimumLineHeight. TextKit puts ALL of the
    /// surplus fragment height above the ascender, so text sits at the bottom of its line
    /// fragment — invisible normally, but lopsided once a highlight wash paints the full
    /// fragment. Raising the baseline by half the surplus centers it. Applied to every text
    /// run (not just highlighted ones) so all lines share the same baseline.
    private static let textBaselineOffset: CGFloat = {
        let natural = NSLayoutManager().defaultLineHeight(for: baseFont)
        return max(0, (sharedParagraphStyle.minimumLineHeight - natural) / 2)
    }()

    /// Log text attributes (shared font, paragraph style and baseline) in the given color.
    private static func textAttributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: baseFont,
            .paragraphStyle: sharedParagraphStyle,
            .foregroundColor: color,
            .baselineOffset: textBaselineOffset
        ]
    }

    /// Plain text and inter-message separators.
    private static let baseAttributes = textAttributes(.labelColor)
    private static let grayAttributes = textAttributes(.secondaryLabelColor)
    private static let myNickAttributes = textAttributes(NSColor(calibratedHue: 0.0, saturation: 0.75, brightness: 0.55, alpha: 1.0))
    private static let otherNickAttributes = textAttributes(NSColor(calibratedHue: 0.13, saturation: 0.75, brightness: 0.55, alpha: 1.0))

    /// `text` in `attributes`, with its web links made clickable.
    private static func linkified(_ text: String, attributes: [NSAttributedString.Key: Any]) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        for link in Formatting.webLinks(in: text) {
            result.addAttribute(.link, value: link.url, range: link.range)
        }
        return result
    }

    /// Brings the rendered text up to date with `messages`. Returns nil when nothing shown
    /// here changed; otherwise the height of what went from above the text that stayed (lines
    /// trimmed off the front), which is what it takes to keep a reader's place.
    private func apply(messages: [ChatMessage], to textView: NSTextView, coordinator: Coordinator, forceFullRebuild: Bool) -> CGFloat? {
        guard let storage = textView.textStorage, let layoutManager = textView.layoutManager else { return nil }
        let lines = messages.map { LogUpdate.Line(id: $0.id, thumbnails: thumbnailFingerprint(for: $0.id)) }
        let separator = NSAttributedString(string: "\n", attributes: Self.baseAttributes)
        var removedHeight: CGFloat = 0

        switch forceFullRebuild ? .rebuild : LogUpdate.plan(from: coordinator.renderedLines, to: lines) {
        case .none:
            // logVersion bumps for every log in the app, so most updates come from some other
            // conversation, and leave this one's text alone.
            return nil

        case .rebuild:
            let combined = NSMutableAttributedString()
            var lengths: [Int] = []
            for message in messages {
                if !lengths.isEmpty { combined.append(separator) }
                let line = attributedString(for: message)
                combined.append(line)
                lengths.append(line.length)
            }
            storage.setAttributedString(combined)
            coordinator.renderedLengths = lengths
            coordinator.renderedDay = Calendar.current.startOfDay(for: .now)

        // The storage holds the lines with a newline between each two and none at the end. At
        // least one rendered line stays, so every line dropped or added has one beside it.
        // Each step is an edit of its own: AppKit moves the selection along with single edits,
        // but drops it over a batch of them.
        case .edit(let dropped, let changed, let appendFrom):
            var lengths = Array(coordinator.renderedLengths[dropped...])
            if dropped > 0 {
                let removedLength = coordinator.renderedLengths[..<dropped].reduce(0) { $0 + $1 + 1 }
                let firstKeptGlyph = layoutManager.glyphIndexForCharacter(at: removedLength)
                removedHeight = layoutManager.lineFragmentRect(forGlyphAt: firstKeptGlyph, effectiveRange: nil).minY
                storage.deleteCharacters(in: NSRange(location: 0, length: removedLength))
            }
            for index in changed {
                let location = lengths[..<index].reduce(0) { $0 + $1 + 1 }
                let line = attributedString(for: messages[index])
                storage.replaceCharacters(in: NSRange(location: location, length: lengths[index]), with: line)
                lengths[index] = line.length
            }
            if appendFrom < messages.count {
                let appended = NSMutableAttributedString()
                for message in messages[appendFrom...] {
                    let line = attributedString(for: message)
                    appended.append(separator)
                    appended.append(line)
                    lengths.append(line.length)
                }
                storage.append(appended)
            }
            coordinator.renderedLengths = lengths
        }

        coordinator.renderedLines = lines
        return removedHeight
    }

    /// Stable fingerprint of a message's thumbnails (count + how many images have loaded), so
    /// that a thumbnail loading, or the preference to show them changing, renders its line again.
    private func thumbnailFingerprint(for id: UUID) -> Int {
        guard showThumbnails else { return 0 }
        let arr = thumbnailsByMessage[id] ?? []
        var fp = arr.count
        let loaded = arr.count(where: { $0.image != nil })
        fp = fp &* 31 &+ loaded
        return fp
    }

    /// Renders ONE message (time + nick/body or plain text + optional thumbnail block) WITHOUT
    /// a trailing inter-message newline. Shared by the full-rebuild and edit paths so the two
    /// produce byte-identical output for the same message.
    private func attributedString(for msg: ChatMessage) -> NSAttributedString {
        let attrs = Self.baseAttributes
        let combined = NSMutableAttributedString()
        // Time, without brackets, gray
        let timeStr = "\(Formatting.timeString(msg.time)) "
        combined.append(NSAttributedString(string: timeStr, attributes: Self.grayAttributes))

        if msg.isPrivmsg, let nick = msg.senderNick {
            // Chat line: colored nick, gray colon, body in label color. An action reads
            // "* nick waves" instead. A message for some members only names its audience
            // after the nick: "nick (@#chan): …".
            let sender = NSMutableAttributedString(string: nick, attributes: msg.isFromMe ? Self.myNickAttributes : Self.otherNickAttributes)
            if let statusTarget = msg.statusTarget {
                sender.append(NSAttributedString(string: " (\(statusTarget))", attributes: Self.grayAttributes))
            }
            if msg.isAction {
                combined.append(NSAttributedString(string: "* ", attributes: Self.grayAttributes))
                combined.append(sender)
                combined.append(NSAttributedString(string: " ", attributes: attrs))
            } else {
                combined.append(sender)
                combined.append(NSAttributedString(string: ": ", attributes: Self.grayAttributes))
            }
        }
        // Chat body or non-chat line: label color, with links detected
        combined.append(Self.linkified(msg.text, attributes: attrs))

        // Marker consumed by LogLayoutManager, which paints the wash edge to edge across
        // the text view (.backgroundColor would only paint behind the glyphs). Applied
        // before the thumbnail block so it covers the mention line but not attached images.
        if msg.isHighlight {
            combined.addAttribute(.ircHighlightLine, value: Self.highlightBackgroundColor,
                                  range: NSRange(location: 0, length: combined.length))
        }

        if showThumbnails, let thumbs = thumbnailsByMessage[msg.id], !thumbs.isEmpty {
            combined.append(NSAttributedString(string: "\n", attributes: attrs))
            for (i, item) in thumbs.enumerated() {
                // Create image attachment with max size of 200x200 logical pixels
                let maxSize = NSSize(width: 200, height: 200)
                let attachment: NSTextAttachment

                if let img = item.image {
                    // Real image - use actual prepared size
                    attachment = makeImageAttachment(img, maxSize: maxSize)
                } else {
                    // Placeholder - reserve exact space that the image will occupy
                    // Use a fixed aspect ratio or default size to prevent layout shift
                    let placeholderSize = NSSize(width: 200, height: 150) // 4:3 aspect ratio placeholder
                    let placeholder = NSImage(size: placeholderSize)
                    attachment = RetinaImageAttachment(image: placeholder, displaySize: placeholderSize)
                }

                let attStr = NSMutableAttributedString(attachment: attachment)
                let range = NSRange(location: 0, length: attStr.length)
                attStr.addAttribute(.link, value: item.url, range: range)
                attStr.addAttribute(.underlineStyle, value: 0, range: range)
                combined.append(attStr)
                if i < thumbs.count - 1 { combined.append(NSAttributedString(string: "\n", attributes: attrs)) }
            }
        }
        return combined
    }

    private func isAtBottom(textView: NSTextView, scrollView: NSScrollView) -> Bool {
        let visible = scrollView.contentView.documentVisibleRect
        let contentHeight = textView.bounds.height
        let bottomGap = contentHeight - visible.maxY
        return bottomGap <= 2
    }
    
    final class RetinaImageAttachment: NSTextAttachment {
        let displaySize: NSSize

        init(image: NSImage, displaySize: NSSize) {
            self.displaySize = displaySize
            super.init(data: nil, ofType: nil)
            self.image = image
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func attachmentBounds(for textContainer: NSTextContainer?,
                                       proposedLineFragment lineFrag: NSRect,
                                       glyphPosition position: CGPoint,
                                       characterIndex charIndex: Int) -> NSRect {
            return NSRect(origin: .zero, size: displaySize)
        }
        
        override func image(forBounds imageBounds: NSRect, 
                           textContainer: NSTextContainer?, 
                           characterIndex charIndex: Int) -> NSImage? {
            guard let originalImage = self.image else { return nil }
            
            // If the original image is already the right size, just return it
            if abs(originalImage.size.width - imageBounds.width) < 1.0 &&
               abs(originalImage.size.height - imageBounds.height) < 1.0 {
                return originalImage
            }
            
            // Drawing-handler images render lazily at the destination's backing scale
            return NSImage(size: imageBounds.size, flipped: false) { rect in
                NSGraphicsContext.current?.imageInterpolation = .high
                originalImage.draw(in: rect,
                                   from: NSRect(origin: .zero, size: originalImage.size),
                                   operation: .sourceOver,
                                   fraction: 1.0)
                return true
            }
        }
    }

    private func prepareImageForAttachment(_ sourceImage: NSImage, targetSize: NSSize) -> NSImage {
        // Calculate aspect ratio and determine final display size
        let sourceSize = sourceImage.size
        guard sourceSize.width > 0 && sourceSize.height > 0 else {
            return sourceImage
        }
        
        let aspectRatio = sourceSize.width / sourceSize.height
        let finalSize: NSSize
        
        if targetSize.width / aspectRatio <= targetSize.height {
            // Width-constrained
            finalSize = NSSize(width: targetSize.width, height: targetSize.width / aspectRatio)
        } else {
            // Height-constrained  
            finalSize = NSSize(width: targetSize.height * aspectRatio, height: targetSize.height)
        }
        
        // If the image is already the right size, return it as-is
        if abs(sourceSize.width - finalSize.width) < 1.0 && 
           abs(sourceSize.height - finalSize.height) < 1.0 {
            return sourceImage
        }
        
        // Create a new properly-sized image; the drawing handler renders lazily at the
        // destination's backing scale, so it stays sharp on Retina displays.
        return NSImage(size: finalSize, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            sourceImage.draw(in: rect,
                             from: NSRect(origin: .zero, size: sourceSize),
                             operation: .sourceOver,
                             fraction: 1.0)
            return true
        }
    }

    private func makeImageAttachment(_ img: NSImage, maxSize: NSSize) -> NSTextAttachment {
        // Prepare the image with proper sizing and aspect ratio preservation
        let preparedImage = prepareImageForAttachment(img, targetSize: maxSize)
        return RetinaImageAttachment(image: preparedImage, displaySize: preparedImage.size)
    }


}

// MARK: - Sidebar Components

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

    private var statusColor: Color {
        switch server.connectionStatus {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .connectionTimeout: .red
        case .disconnected: .secondary
        }
    }
    
    var body: some View {
        let node = SidebarItem(server: server, kind: .server)
        SidebarRowBase(isSelected: isSelected, indent: 0, rowHeight: rowHeight, activeState: activeState) {
            Image(systemName: node.systemImageName)
                .frame(width: iconColWidth, alignment: .center)
                .foregroundStyle(statusColor)
            Text(node.name).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            
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
    let node: SidebarItem
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
            Image(systemName: node.systemImageName)
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
            Text(node.name).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                .opacity(isDimmed ? 0.5 : 1)
        }
        .contextMenu { Button(menuTitle, action: menuAction) }
        .onTapGesture(perform: select)
    }
}

/// A sidebar row: a server, or one of its channels or private conversations.
struct SidebarItem: Identifiable {
    enum Kind { case server, channel(IRCChannel), privateMessage(IRCPrivateMessage) }
    /// The server this row is, or belongs to.
    let server: IRCServer
    let kind: Kind

    var id: UUID {
        switch kind {
        case .server: server.id
        case .channel(let c): c.id
        case .privateMessage(let pm): pm.id
        }
    }
    var name: String {
        switch kind {
        case .server: server.name
        case .channel(let c): c.name
        case .privateMessage(let pm): pm.nickname
        }
    }
    var systemImageName: String {
        switch kind {
        case .channel: "rectangle.3.group.bubble"
        case .privateMessage: "person.2"
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
        case .privateMessage(let pm): pm.log
        }
    }
    /// Where text typed while the row is selected goes; nil for a server, which only takes
    /// commands.
    var messageTarget: MessageTarget? {
        switch kind {
        case .server: nil
        case .channel(let c): .channel(c)
        case .privateMessage(let pm): .privateMessage(pm)
        }
    }
}

// MARK: - Dialogs & Preferences

/// The Settings window: a standard preferences form, labels on the left and controls on the
/// right, in a window just big enough to hold it.
struct PreferencesView: View {
    @Environment(AppPreferences.self) private var prefs
    @Environment(ChatStore.self) private var model

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            LabeledContent("Lines to keep in log:") {
                HStack(spacing: 4) {
                    TextField("Lines to keep in log", value: $prefs.maxLogLines, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                    Stepper("Lines to keep in log", value: $prefs.maxLogLines, in: 1...100000)
                        .labelsHidden()
                }
            }
            // Related checkboxes share a label and sit close together; groups get a little air.
            LabeledContent("Show:") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Image thumbnails", isOn: $prefs.showImageThumbnails)
                    Toggle("Joins, parts and quits in channels", isOn: $prefs.showJoinsAndParts)
                }
            }
            .padding(.top, 6)
            LabeledContent("Debug:") {
                Toggle("Log raw server traffic", isOn: $prefs.debugRawServerLog)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 20)
        // A fixed size is what makes the window fit: anything that can stretch, and SwiftUI
        // gives the Settings window room to stretch into.
        .fixedSize()
        // Apply a lowered cap to stored logs immediately; otherwise memory is only
        // reclaimed on the next received message.
        .onChange(of: prefs.maxLogLines) { _, _ in model.trimLogs() }
    }
}

/// Add/Edit server form. `server == nil` creates a new server; otherwise edits in place.
struct ServerFormView: View {
    @Environment(ChatStore.self) private var model
    @Environment(\.dismiss) private var dismiss
    let server: IRCServer?
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var password: String
    @State private var useTLS: Bool
    @State private var useSASL: Bool
    @State private var autoConnectOnLaunch: Bool
    @State private var nickname: String

    // Filled in here rather than in onAppear, where setting useTLS would trigger its port swap.
    // A new server starts out encrypted, on the usual TLS port.
    init(server: IRCServer? = nil) {
        self.server = server
        _name = State(initialValue: server?.name ?? "")
        _host = State(initialValue: server?.host ?? "")
        _port = State(initialValue: String(server?.port ?? 6697))
        _password = State(initialValue: server?.password ?? "")
        _useTLS = State(initialValue: server?.useTLS ?? true)
        _useSASL = State(initialValue: server?.useSASL ?? false)
        _autoConnectOnLaunch = State(initialValue: server?.autoConnectOnLaunch ?? false)
        _nickname = State(initialValue: server?.nickname ?? "")
    }

    private var validPort: Int? { Int(port).flatMap { (1...65535).contains($0) ? $0 : nil } }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }
    private var trimmedNick: String { nickname.trimmingCharacters(in: .whitespaces) }
    private var nickIsValid: Bool { trimmedNick.isEmpty || IRCName.isValidNickname(trimmedNick) }
    /// SASL logs the nickname in to its account with the password, so it needs both.
    private var saslIsComplete: Bool { !useSASL || (!trimmedNick.isEmpty && !password.isEmpty) }
    private var canSave: Bool { !trimmedName.isEmpty && !trimmedHost.isEmpty && validPort != nil && nickIsValid && saslIsComplete }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(server == nil ? "Add Server" : "Edit Server").font(.headline)
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow { Text("Name:"); TextField("Display name", text: $name).textFieldStyle(.roundedBorder) }
                GridRow { Text("Server:"); TextField("irc.example.net", text: $host).textFieldStyle(.roundedBorder) }
                GridRow { Text("Port:"); TextField("6697", text: $port).textFieldStyle(.roundedBorder) }
                GridRow { Text("Password:"); SecureField("Optional", text: $password).textFieldStyle(.roundedBorder) }
                GridRow { Text("Nickname:"); TextField("Optional (uses default if blank)", text: $nickname).textFieldStyle(.roundedBorder) }
                GridRow {
                    Text("Log in with SASL:")
                    Toggle("", isOn: $useSASL)
                        .labelsHidden()
                        .help("Logs the nickname in to its account with the password, instead of sending the password as the server’s. Needs both.")
                }
                GridRow {
                    Text("Use SSL/TLS:")
                    Toggle("", isOn: $useTLS)
                        .labelsHidden()
                        .onChange(of: useTLS) { _, newValue in
                            if let p = Int(port) {
                                if newValue && (p == 6667) { port = "6697" }
                                if !newValue && (p == 6697) { port = "6667" }
                            }
                        }
                }
                GridRow {
                    Text("Auto-connect on launch:")
                    Toggle("", isOn: $autoConnectOnLaunch).labelsHidden()
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    guard let p = validPort else { return }
                    let pwd: String? = password.isEmpty ? nil : password
                    let nick: String? = trimmedNick.isEmpty ? nil : trimmedNick
                    if let server {
                        model.updateServer(id: server.id, name: trimmedName, host: trimmedHost, port: p, password: pwd, useTLS: useTLS, useSASL: useSASL, autoConnectOnLaunch: autoConnectOnLaunch, nickname: nick)
                    } else {
                        model.addServer(name: trimmedName, host: trimmedHost, port: p, password: pwd, useTLS: useTLS, useSASL: useSASL, autoConnectOnLaunch: autoConnectOnLaunch, nickname: nick)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

struct JoinChannelView: View {
    @Environment(ChatStore.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    /// As for /join: several channels separated by commas, with `#` added where there's no prefix.
    private var channels: [String] { MessageRouter.channelNames(name.filter { !$0.isWhitespace }) }
    private var canJoin: Bool { !channels.isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Join Channel").font(.headline)
            HStack {
                Text("Channel:")
                TextField("#channel", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Join") {
                    guard canJoin, let server = model.server(withID: model.pendingJoinServerID) else { return }
                    model.joinChannels(channels, on: server)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canJoin)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

struct TopicEditorView: View {
    @Environment(ChatStore.self) private var model
    @Environment(\.dismiss) private var dismiss
    let channel: IRCChannel
    @State private var topicDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Topic for \(channel.name)").font(.headline)
            TextEditor(text: $topicDraft)
                .font(.body)
                .frame(minHeight: 80, maxHeight: 200)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Set Topic") {
                    let topic = topicDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Setting the same topic again would announce a change to the whole channel.
                    if topic != (channel.topic ?? "") { model.setTopic(topic, on: channel) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear { topicDraft = channel.topic ?? "" }
    }
}

// MARK: - Split View Wrapper

struct AutosavingSplitView<Left: View, Right: View>: NSViewRepresentable {
    let left: Left
    let right: Right
    let autosaveName: String
    let isVertical: Bool
    init(@ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right, autosaveName: String, isVertical: Bool = true) {
        self.left = left()
        self.right = right()
        self.autosaveName = autosaveName
        self.isVertical = isVertical
    }
    func makeNSView(context: Context) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = isVertical
        split.dividerStyle = .thin
        let leftHost = NSHostingView(rootView: left)
        let rightHost = NSHostingView(rootView: right)
        split.addArrangedSubview(leftHost)
        split.addArrangedSubview(rightHost)
        split.autosaveName = NSSplitView.AutosaveName(autosaveName)
        leftHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rightHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        return split
    }
    func updateNSView(_ nsView: NSSplitView, context: Context) {
        if let leftHost = nsView.subviews.first as? NSHostingView<Left> { leftHost.rootView = left }
        if nsView.subviews.count > 1, let rightHost = nsView.subviews[1] as? NSHostingView<Right> { rightHost.rootView = right }
    }
}
