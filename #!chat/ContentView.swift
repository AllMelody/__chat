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
            LogTextView(logVersion: model.logVersion, selectionToken: model.selectedNodeID, messages: currentMessages, thumbnailsByMessage: model.messageThumbnails, showThumbnails: prefs.showImageThumbnails)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 2)

            Divider()
            ComposerTextField(text: $draft, placeholder: "Type a message…", focusRequest: composerFocusRequest) {
                if model.handleInputFromComposer(draft) { draft = "" }
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
            List { ForEach(currentUsers, id: \.self) { Text($0) } }
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
    private var currentMessages: [ChatMessage] {
        Array((model.selectedItem?.log ?? []).suffix(max(1, prefs.maxLogLines)))
    }
    private var currentUsers: [String] {
        (model.selectedItem?.channel?.users ?? []).sorted(using: .localizedStandard)
    }
}

// MARK: - Composer (NSTextField wrapper to avoid placeholder shift on focus change)

private struct ComposerTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    /// Each change moves keyboard focus into the field.
    let focusRequest: Int
    let onSubmit: () -> Void

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

        init(_ parent: ComposerTextField) {
            self.parent = parent
            self.lastFocusRequest = parent.focusRequest
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = ComposerTextField.unflatten(tf.stringValue)
            // After every change, so text typed next to a symbol doesn't take its color.
            if tf.stringValue.contains(ComposerTextField.newlineSymbol) {
                ComposerTextField.colorizeNewlineSymbols(in: tf)
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
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
            tf.window?.makeFirstResponder(tf)
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
    let logVersion: Int
    let selectionToken: UUID?
    let messages: [ChatMessage]
    let thumbnailsByMessage: [UUID: [MessageThumbnail]]
    let showThumbnails: Bool

    final class Coordinator: NSObject, NSTextViewDelegate {
        var lastSelectionToken: UUID?
        var isPinnedToBottom: Bool = true
        var boundsObserver: Any?
        var frameObserver: Any?
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var lastContentSignature: Int = 0
        var lastContentHeight: CGFloat = 0
        // Incremental rendering bookkeeping: ordered ids currently in textStorage, and the
        // thumbnail fingerprint of each, so apply() can choose append-fast-path vs full rebuild.
        var lastRenderedIDs: [UUID] = []
        var renderedThumbFingerprints: [UUID: Int] = [:]
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

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL {
                NSWorkspace.shared.open(url)
                return true
            } else if let str = link as? String, let url = URL(string: str) {
                NSWorkspace.shared.open(url)
                return true
            }
            return false
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
        textView.usesFindBar = true
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
        apply(messages: messages, to: textView, coordinator: coordinator, forceFullRebuild: true)
        textView.scrollToEndOfDocument(nil)
        coordinator.lastSelectionToken = selectionToken
        coordinator.lastContentHeight = textView.bounds.height
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }

        let signature: Int = {
            var hash = messages.count
            hash = hash &* 31 &+ logVersion
            hash = hash &* 31 &+ (selectionToken?.hashValue ?? 0)
            
            // Only calculate hash for visible messages if there are many
            let messagesToHash = messages.count > 1000 ? Array(messages.suffix(100)) : messages
            for m in messagesToHash {
                let arr = thumbnailsByMessage[m.id] ?? []
                hash = hash &* 31 &+ arr.count
                let loadedCount = arr.count(where: { $0.image != nil })
                hash = hash &* 31 &+ loadedCount
            }
            return hash
        }()
        let selectionChanged = (context.coordinator.lastSelectionToken != selectionToken)
        let dayChanged = (context.coordinator.renderedDay != Calendar.current.startOfDay(for: .now))
        if context.coordinator.lastContentSignature != signature || dayChanged {
            apply(messages: messages, to: textView, coordinator: context.coordinator, forceFullRebuild: selectionChanged || dayChanged)
            context.coordinator.lastContentSignature = signature
        }

        if selectionChanged { context.coordinator.isPinnedToBottom = true }

        // Ensure layout to measure content height change accurately
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let newHeight = textView.bounds.height
        let grew = newHeight - context.coordinator.lastContentHeight > 0.5

        if selectionChanged || (context.coordinator.isPinnedToBottom && grew) {
            // Use CATransaction to disable implicit animations that cause flickering
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            textView.scrollToEndOfDocument(nil)
            CATransaction.commit()
        }

        context.coordinator.lastSelectionToken = selectionToken
        context.coordinator.lastContentHeight = newHeight
    }

    // Cache commonly used attributes for performance
    private static let sharedParagraphStyle: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.minimumLineHeight = 18
        return paragraph
    }()
    
    // Link-only data detectors can't fail to initialize.
    private static let sharedLinkDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

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

    /// `text` in `attributes`, with detected URLs made clickable.
    private static func linkified(_ text: String, attributes: [NSAttributedString.Key: Any]) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        let range = NSRange(location: 0, length: (text as NSString).length)
        sharedLinkDetector.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, let url = match.url else { return }
            result.addAttribute(.link, value: url, range: match.range)
        }
        return result
    }

    private func apply(messages: [ChatMessage], to textView: NSTextView, coordinator: Coordinator, forceFullRebuild: Bool) {
        guard let storage = textView.textStorage else { return }
        let newIDs = messages.map { $0.id }
        let prior = coordinator.lastRenderedIDs
        let renderedThumbnailsAreCurrent = prior.allSatisfy {
            coordinator.renderedThumbFingerprints[$0] == thumbnailFingerprint(for: $0)
        }

        // logVersion bumps for every log in the app, so most updates come from some other
        // conversation. When nothing shown here changed, keep the storage — rebuilding it would
        // also throw away the user's text selection.
        if !forceFullRebuild && newIDs == prior && renderedThumbnailsAreCurrent { return }

        // Append-fast-path is valid ONLY when the new list is a pure suffix-append of what we
        // already rendered (identical prefix, strictly more at the end) AND no already-rendered
        // message changed its thumbnail fingerprint. Anything else — selection change, front
        // truncation from maxLogLines, or a thumbnail loading on an existing message — falls
        // back to a full rebuild.
        let canAppend = !forceFullRebuild
            && newIDs.count > prior.count
            && newIDs.starts(with: prior)
            && renderedThumbnailsAreCurrent

        if canAppend {
            let appended = NSMutableAttributedString()
            // The existing storage has no trailing newline, so the first new message needs a
            // separator if there is already content.
            var needsSeparator = !prior.isEmpty && storage.length > 0
            for msg in messages.suffix(newIDs.count - prior.count) {
                if needsSeparator { appended.append(NSAttributedString(string: "\n", attributes: Self.baseAttributes)) }
                needsSeparator = true
                appended.append(attributedString(for: msg))
            }
            storage.append(appended)
        } else {
            let combined = NSMutableAttributedString()
            for (idx, msg) in messages.enumerated() {
                combined.append(attributedString(for: msg))
                if idx < messages.count - 1 {
                    combined.append(NSAttributedString(string: "\n", attributes: Self.baseAttributes))
                }
            }
            storage.setAttributedString(combined)
            coordinator.renderedDay = Calendar.current.startOfDay(for: .now)
        }

        // Single bookkeeping exit point keeps the next diff accurate.
        coordinator.lastRenderedIDs = newIDs
        coordinator.renderedThumbFingerprints = Dictionary(
            newIDs.map { ($0, thumbnailFingerprint(for: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Stable fingerprint of a message's thumbnails (count + how many images have loaded).
    /// Mirrors the per-message hashing in updateNSView's signature so a thumbnail load both
    /// invalidates the signature AND forces that message to be re-rendered via full rebuild.
    private func thumbnailFingerprint(for id: UUID) -> Int {
        guard showThumbnails else { return 0 }
        let arr = thumbnailsByMessage[id] ?? []
        var fp = arr.count
        let loaded = arr.count(where: { $0.image != nil })
        fp = fp &* 31 &+ loaded
        return fp
    }

    /// Renders ONE message (time + nick/body or plain text + optional thumbnail block) WITHOUT
    /// a trailing inter-message newline. Shared by the full-rebuild and append paths so the two
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
        case .connectionTimeout, .reconnectionFailed: .red
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
                .frame(width: iconColWidth, alignment: .center)
                .overlay(alignment: .topTrailing) {
                    if unreadCount > 0 {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .offset(x: 2, y: -2)
                    }
                }
            Text(node.name).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
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
            case .connectionTimeout, .reconnectionFailed, .disconnected: "network.slash"
            }
        }
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

struct PreferencesView: View {
    @Environment(AppPreferences.self) private var prefs
    @Environment(ChatStore.self) private var model

    var body: some View {
        @Bindable var prefs = prefs
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Number of lines to keep in log:")
                    HStack(spacing: 8) {
                        TextField("Lines", value: $prefs.maxLogLines, format: .number)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Stepper("", value: $prefs.maxLogLines, in: 1...100000)
                            .labelsHidden()
                    }
                }
                GridRow {
                    Text("Show image thumbnails:")
                    Toggle("", isOn: $prefs.showImageThumbnails)
                        .labelsHidden()
                }
                GridRow {
                    Text("Log raw server traffic (debug):")
                    Toggle("", isOn: $prefs.debugRawServerLog)
                        .labelsHidden()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 520)
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
    init(server: IRCServer? = nil) { self.server = server }
    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = "6667"
    @State private var password: String = ""
    @State private var useTLS: Bool = false
    @State private var autoConnectOnLaunch: Bool = false
    @State private var nickname: String = ""
    private var validPort: Int? { Int(port).flatMap { (1...65535).contains($0) ? $0 : nil } }
    private var trimmedNick: String { nickname.trimmingCharacters(in: .whitespaces) }
    private var nickIsValid: Bool { trimmedNick.isEmpty || IRCName.isValidNickname(trimmedNick) }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !host.trimmingCharacters(in: .whitespaces).isEmpty && validPort != nil && nickIsValid }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(server == nil ? "Add Server" : "Edit Server").font(.headline)
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow { Text("Name:"); TextField("Display name", text: $name).textFieldStyle(.roundedBorder) }
                GridRow { Text("Server:"); TextField("irc.example.net", text: $host).textFieldStyle(.roundedBorder) }
                GridRow { Text("Port:"); TextField("6667", text: $port).textFieldStyle(.roundedBorder) }
                GridRow { Text("Password:"); SecureField("Optional", text: $password).textFieldStyle(.roundedBorder) }
                GridRow { Text("Nickname:"); TextField("Optional (uses default if blank)", text: $nickname).textFieldStyle(.roundedBorder) }
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
                        model.updateServer(id: server.id, name: name, host: host, port: p, password: pwd, useTLS: useTLS, autoConnectOnLaunch: autoConnectOnLaunch, nickname: nick)
                    } else {
                        model.addServer(name: name, host: host, port: p, password: pwd, useTLS: useTLS, autoConnectOnLaunch: autoConnectOnLaunch, nickname: nick)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .onAppear {
            guard let server else { return }
            name = server.name
            host = server.host
            port = String(server.port)
            password = server.password ?? ""
            useTLS = server.useTLS
            autoConnectOnLaunch = server.autoConnectOnLaunch
            nickname = server.nickname ?? ""
        }
        .padding(16)
        .frame(width: 420)
    }
}

struct JoinChannelView: View {
    @Environment(ChatStore.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var canJoin: Bool { IRCName.isChannel(trimmedName) }
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
                    model.joinChannel(trimmedName, on: server)
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
                    model.setTopic(topicDraft, on: channel)
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
