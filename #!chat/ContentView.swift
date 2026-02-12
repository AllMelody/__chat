import SwiftUI
import AppKit

// MARK: - Content View & Layout

struct ContentView: View {
    @Environment(ChatStore.self) private var model
    @Environment(AppPreferences.self) private var prefs
    @Environment(\.controlActiveState) private var activeState

    @State private var draft = ""

    private let rowHeight: CGFloat = 24
    private let iconColWidth: CGFloat = 18
    private let indentWidth: CGFloat = 14
    private var onePixel: CGFloat { 1 / (NSScreen.main?.backingScaleFactor ?? 2) }

    private var allNodesFlat: [SidebarItem] {
        model.servers.flatMap { s in 
            [SidebarItem(kind: .server(s))] + 
            s.channels.map { SidebarItem(kind: .channel($0)) } +
            s.privateMessages.map { SidebarItem(kind: .privateMessage($0)) }
        }
    }

    private func validateSelection() {
        let all = allNodesFlat
        // More robust selection validation
        if let currentID = model.selectedNodeID {
            // Check if current selection still exists
            if !all.contains(where: { $0.id == currentID }) {
                // Try to select the first server, then first available node
                model.selectedNodeID = model.servers.first?.id ?? all.first?.id
            }
        } else {
            // No selection, pick first available
            model.selectedNodeID = model.servers.first?.id ?? all.first?.id
        }
    }
    
    private func navigateUp() {
        let all = allNodesFlat
        guard !all.isEmpty else { return }
        
        if let currentID = model.selectedNodeID,
           let currentIndex = all.firstIndex(where: { $0.id == currentID }) {
            let newIndex = currentIndex > 0 ? currentIndex - 1 : all.count - 1
            model.selectedNodeID = all[newIndex].id
            // Clear unread count if selecting a channel or private message
            if case .channel(let channel) = all[newIndex].kind {
                channel.unreadCount = 0
            } else if case .privateMessage(let pm) = all[newIndex].kind {
                pm.unreadCount = 0
            }
        } else {
            model.selectedNodeID = all.first?.id
        }
    }
    
    private func navigateDown() {
        let all = allNodesFlat
        guard !all.isEmpty else { return }
        
        if let currentID = model.selectedNodeID,
           let currentIndex = all.firstIndex(where: { $0.id == currentID }) {
            let newIndex = currentIndex < all.count - 1 ? currentIndex + 1 : 0
            model.selectedNodeID = all[newIndex].id
            // Clear unread count if selecting a channel or private message
            if case .channel(let channel) = all[newIndex].kind {
                channel.unreadCount = 0
            } else if case .privateMessage(let pm) = all[newIndex].kind {
                pm.unreadCount = 0
            }
        } else {
            model.selectedNodeID = all.first?.id
        }
    }

    private func focusComposer() {
        NotificationCenter.default.post(name: .composerFocus, object: nil)
    }

    var body: some View {
        let splitView = AutosavingSplitView(left: { leftPane }, right: { rightPane }, autosaveName: "MainSplitRightWidth")

        let viewWithAppearance = splitView
            .onAppear { validateSelection(); focusComposer() }
            .onChange(of: model.servers.map(\.id)) { _, _ in validateSelection() }
            .onChange(of: model.servers.flatMap { $0.channels.map(\.id) }) { _, _ in validateSelection() }
        
        let viewWithStateChanges = viewWithAppearance
            .onChange(of: activeState) { _, new in if new == .key { focusComposer() } }
            .onChange(of: model.selectedNodeID) { _, _ in focusComposer() }
            .onReceive(NotificationCenter.default.publisher(for: .navigateUp)) { _ in
                navigateUp()
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateDown)) { _ in
                navigateDown()
            }

        let addServerBinding = Binding(get: { model.isPresentingAddServer }, set: { model.isPresentingAddServer = $0 })
        let joinChannelBinding = Binding(get: { model.isPresentingJoinChannel }, set: { model.isPresentingJoinChannel = $0 })
        let editServerBinding = Binding(get: { model.isPresentingEditServer }, set: { model.isPresentingEditServer = $0 })
        let topicEditorBinding = Binding(get: { model.isPresentingTopicEditor }, set: { model.isPresentingTopicEditor = $0 })

        return viewWithStateChanges
            .sheet(isPresented: addServerBinding) { ServerEditorView() }
            .sheet(isPresented: joinChannelBinding) { JoinChannelView() }
            .sheet(isPresented: editServerBinding) {
                Group {
                    if let server = model.server(withID: model.pendingEditServerID) {
                        EditServerView(server: server)
                    } else {
                        Text("No server selected")
                            .padding(16)
                    }
                }
            }
            .sheet(isPresented: topicEditorBinding) {
                if let channel = findChannel(id: model.selectedNodeID) {
                    TopicEditorView(channel: channel)
                }
            }
    }

    // MARK: - Left Pane
    private var leftPane: some View {
        VStack(spacing: 0) {
            if let topic = findChannel(id: model.selectedNodeID)?.topic {
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
            LogView(logVersion: model.logVersion, selectionToken: model.selectedNodeID, messages: currentMessages, thumbnailsByMessage: model.messageThumbnails, showThumbnails: prefs.showImageThumbnails, myNick: selectedServer?.currentNick)
                .padding(.leading, 4)
                .padding(.bottom, 4)
            Divider()
            ComposerTextField(text: $draft, placeholder: "Type a message…")
                .padding(.horizontal, 6)
                .frame(height: 30)
                .onReceive(NotificationCenter.default.publisher(for: .composerSubmit)) { _ in
                    if canSendMessage { sendMessage() }
                }
        }
    }

    // MARK: - Right Pane
    private var rightPane: some View {
        VSplitView {
            List { ForEach(currentUsers, id: \.self) { Text($0) } }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, rowHeight)

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
                        Button("Add server...") { model.isPresentingAddServer = true }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(6)
                    }
                    ForEach(model.servers, id: \.id) { server in
                        ServerRow(
                            server: server,
                            isSelected: model.selectedNodeID == server.id,
                            rowHeight: rowHeight,
                            iconColWidth: iconColWidth,
                            indentWidth: indentWidth,
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
                                model.joinChannelDraft = ""
                                model.isPresentingJoinChannel = true
                            },
                            editServer: {
                                model.pendingEditServerID = server.id
                                model.isPresentingEditServer = true
                            },
                            deleteServer: { model.deleteServer(server) }
                        )
                        separator()
                        ForEach(server.channels, id: \.id) { ch in
                            ChannelRow(
                                channel: ch,
                                isSelected: model.selectedNodeID == ch.id,
                                rowHeight: rowHeight,
                                iconColWidth: iconColWidth,
                                indentWidth: indentWidth,
                                activeState: activeState,
                                select: {
                                    ch.unreadCount = 0
                                    model.selectedNodeID = ch.id
                                },
                                part: {
                                    let wasSelected = (model.selectedNodeID == ch.id)
                                    model.partChannel(ch)
                                    if wasSelected { model.selectedNodeID = server.id }
                                }
                            )
                            if ch.id != server.channels.last?.id || !server.privateMessages.isEmpty { separator() }
                        }
                        ForEach(server.privateMessages, id: \.id) { pm in
                            PrivateMessageRow(
                                privateMessage: pm,
                                isSelected: model.selectedNodeID == pm.id,
                                rowHeight: rowHeight,
                                iconColWidth: iconColWidth,
                                indentWidth: indentWidth,
                                activeState: activeState,
                                select: {
                                    pm.unreadCount = 0
                                    model.selectedNodeID = pm.id
                                },
                                close: {
                                    let wasSelected = (model.selectedNodeID == pm.id)
                                    model.closePrivateMessage(pm, from: server)
                                    if wasSelected { model.selectedNodeID = server.id }
                                }
                            )
                            if pm.id != server.privateMessages.last?.id { separator() }
                        }
                    }
                    Color.clear.frame(height: 12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contextMenu { Button("Add Server…") { model.isPresentingAddServer = true } }
        }
    }

    @ViewBuilder
    private func separator() -> some View { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: onePixel) }

    // MARK: - Data accessors
    private var selectedServer: IRCServer? { model.servers.first(where: { $0.id == model.selectedNodeID }) }
    private var canSendMessage: Bool {
        // Use the ChatStore method that checks actual client availability
        model.canSendMessage(to: model.selectedNodeID)
    }
    private func findChannel(id: UUID?) -> IRCChannel? { guard let id else { return nil }; for s in model.servers { if let c = s.channels.first(where: { $0.id == id }) { return c } }; return nil }
    private func findPrivateMessage(id: UUID?) -> IRCPrivateMessage? { guard let id else { return nil }; for s in model.servers { if let pm = s.privateMessages.first(where: { $0.id == id }) { return pm } }; return nil }
    private var currentMessages: [ChatMessage] {
        let all: [ChatMessage]
        if let ch = findChannel(id: model.selectedNodeID) { all = ch.log }
        else if let pm = findPrivateMessage(id: model.selectedNodeID) { all = pm.log }
        else if let s = selectedServer { all = s.log }
        else { all = [] }
        let keep = max(1, prefs.maxLogLines)
        return all.count > keep ? Array(all.suffix(keep)) : all
    }
    private var currentUsers: [String] { guard let users = findChannel(id: model.selectedNodeID)?.users else { return [] }; return users.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    private func sendMessage() {
        model.handleInputFromComposer(draft, selection: model.selectedNodeID)
        draft = ""
    }
}

// MARK: - Log View (NSTextView wrapper)

// MARK: - Composer (NSTextField wrapper to avoid placeholder shift on focus change)

private struct ComposerTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ComposerTextField
        var focusObserver: Any?
        weak var textField: NSTextField?

        init(_ parent: ComposerTextField) { self.parent = parent }

        deinit {
            if let obs = focusObserver { NotificationCenter.default.removeObserver(obs) }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                NotificationCenter.default.post(name: .composerSubmit, object: nil)
                return true
            }
            return false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.placeholderString = placeholder
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = .systemFont(ofSize: NSFont.systemFontSize)
        tf.lineBreakMode = .byTruncatingTail
        tf.maximumNumberOfLines = 1
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        tf.delegate = context.coordinator
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)

        context.coordinator.textField = tf
        context.coordinator.focusObserver = NotificationCenter.default.addObserver(
            forName: .composerFocus, object: nil, queue: .main
        ) { [weak tf] _ in
            guard let tf else { return }
            tf.window?.makeFirstResponder(tf)
        }

        // Initial focus after a brief delay to ensure the view is in the window
        DispatchQueue.main.async { tf.window?.makeFirstResponder(tf) }
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        if tf.stringValue != text {
            tf.stringValue = text
        }
    }
}

struct LogView: View {
    let logVersion: Int
    let selectionToken: UUID?
    let messages: [ChatMessage]
    let thumbnailsByMessage: [UUID: [MessageThumbnail]]
    let showThumbnails: Bool
    let myNick: String?

    var body: some View {
        LogTextView(logVersion: logVersion, selectionToken: selectionToken, messages: messages, thumbnailsByMessage: thumbnailsByMessage, showThumbnails: showThumbnails, myNick: myNick)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LogTextView: NSViewRepresentable {
    let logVersion: Int
    let selectionToken: UUID?
    let messages: [ChatMessage]
    let thumbnailsByMessage: [UUID: [MessageThumbnail]]
    let showThumbnails: Bool
    let myNick: String?

    final class Coordinator: NSObject, NSTextViewDelegate {
        var lastSelectionToken: UUID?
        var lastMessageCount: Int = 0
        var isPinnedToBottom: Bool = true
        var boundsObserver: Any?
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var lastContentSignature: Int = 0
        var lastContentHeight: CGFloat = 0
        
        deinit {
            if let observer = boundsObserver {
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

        let textView = NSTextView(frame: .zero)
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
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
        context.coordinator.boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: nil) { _ in
            guard let tv = context.coordinator.textView, let sv = context.coordinator.scrollView else { return }
            context.coordinator.isPinnedToBottom = isAtBottom(textView: tv, scrollView: sv)
        }
        apply(messages: messages, to: textView)
        textView.scrollToEndOfDocument(nil)
        context.coordinator.lastSelectionToken = selectionToken
        context.coordinator.lastMessageCount = messages.count
        context.coordinator.lastContentHeight = textView.bounds.height
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
                let loadedCount = arr.reduce(0) { $0 + ($1.image == nil ? 0 : 1) }
                hash = hash &* 31 &+ loadedCount
            }
            return hash
        }()
        if context.coordinator.lastContentSignature != signature {
            apply(messages: messages, to: textView)
            context.coordinator.lastContentSignature = signature
        }

        let selectionChanged = (context.coordinator.lastSelectionToken != selectionToken)
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

        context.coordinator.lastMessageCount = messages.count
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
    
    private static let sharedLinkDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()
    
    private func apply(messages: [ChatMessage], to textView: NSTextView) {
        let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .paragraphStyle: Self.sharedParagraphStyle,
            .foregroundColor: NSColor.labelColor
        ]
        let grayAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .paragraphStyle: Self.sharedParagraphStyle,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let myNickAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .paragraphStyle: Self.sharedParagraphStyle,
            .foregroundColor: NSColor(calibratedHue: 0.0, saturation: 0.75, brightness: 0.55, alpha: 1.0)
        ]
        let otherNickAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .paragraphStyle: Self.sharedParagraphStyle,
            .foregroundColor: NSColor(calibratedHue: 0.13, saturation: 0.75, brightness: 0.55, alpha: 1.0)
        ]

        let combined = NSMutableAttributedString()
        let detector = Self.sharedLinkDetector
        for (idx, msg) in messages.enumerated() {
            // Time, without brackets, gray
            let timeStr = "\(Formatting.timeString(msg.time)) "
            combined.append(NSAttributedString(string: timeStr, attributes: grayAttrs))

            if msg.isPrivmsg, let nick = msg.senderNick {
                // Chat line: colored nick, gray colon, body in black
                let isMine = msg.isFromMe || (myNick != nil && nick.compare(myNick!, options: .caseInsensitive) == .orderedSame)
                combined.append(NSAttributedString(string: nick, attributes: isMine ? myNickAttrs : otherNickAttrs))
                combined.append(NSAttributedString(string: ": ", attributes: grayAttrs))

                let bodyStr = msg.text
                let bodyAttr = NSMutableAttributedString(string: bodyStr, attributes: attrs)
                if let detector {
                    let nsBody = bodyStr as NSString
                    let bodyRange = NSRange(location: 0, length: nsBody.length)
                    detector.enumerateMatches(in: bodyStr, options: [], range: bodyRange) { result, _, _ in
                        guard let result, let url = result.url else { return }
                        bodyAttr.addAttribute(.link, value: url, range: result.range)
                    }
                }
                combined.append(bodyAttr)
            } else {
                // Non-chat line: keep as-is (black), but still detect links
                let text = msg.text
                let plain = NSMutableAttributedString(string: text, attributes: attrs)
                if let detector {
                    let nsText = text as NSString
                    let fullRange = NSRange(location: 0, length: nsText.length)
                    detector.enumerateMatches(in: text, options: [], range: fullRange) { result, _, _ in
                        guard let result, let url = result.url else { return }
                        plain.addAttribute(.link, value: url, range: result.range)
                    }
                }
                combined.append(plain)
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
            if idx < messages.count - 1 { combined.append(NSAttributedString(string: "\n", attributes: attrs)) }
        }

        textView.textStorage?.setAttributedString(combined)
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
            
            // Create a new image with proper scaling
            let scaledImage = NSImage(size: imageBounds.size)
            scaledImage.lockFocus()
            
            let context = NSGraphicsContext.current?.cgContext
            context?.interpolationQuality = .high
            
            originalImage.draw(in: NSRect(origin: .zero, size: imageBounds.size),
                             from: NSRect(origin: .zero, size: originalImage.size),
                             operation: .sourceOver,
                             fraction: 1.0)
            
            scaledImage.unlockFocus()
            return scaledImage
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
        
        // Create a new properly-sized image
        let resizedImage = NSImage(size: finalSize)
        resizedImage.lockFocus()
        
        // Set high quality interpolation
        NSGraphicsContext.current?.imageInterpolation = .high
        
        sourceImage.draw(in: NSRect(origin: .zero, size: finalSize),
                        from: NSRect(origin: .zero, size: sourceSize),
                        operation: .sourceOver,
                        fraction: 1.0)
        
        resizedImage.unlockFocus()
        return resizedImage
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
        let bgColor: Color = { guard isSelected else { return .clear }; return isKey ? Color(nsColor: .selectedContentBackgroundColor) : Color(nsColor: .unemphasizedSelectedContentBackgroundColor) }()
        let fgColor: Color = { guard isSelected else { return .primary }; return isKey ? .white : .primary }()
        ZStack {
            bgColor
            HStack(spacing: 6) {
                Color.clear.frame(width: indent)
                HStack(spacing: 6) { content.frame(height: rowHeight) }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundColor(fgColor)
        }
        .contentShape(Rectangle())
    }
}

struct ServerRow: View {
    let server: IRCServer
    let isSelected: Bool
    let rowHeight: CGFloat
    let iconColWidth: CGFloat
    let indentWidth: CGFloat
    let activeState: ControlActiveState
    let select: () -> Void
    let connect: () -> Void
    let disconnect: () -> Void
    let joinChannelPrompt: () -> Void
    let editServer: () -> Void
    let deleteServer: () -> Void
    
    private var statusColor: Color {
        switch server.connectionStatus {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .connectionTimeout, .reconnectionFailed: return .red
        case .disconnected: return .secondary
        }
    }
    
    var body: some View {
        let node = SidebarItem(kind: .server(server))
        SidebarRowBase(isSelected: isSelected, indent: 0, rowHeight: rowHeight, activeState: activeState) {
            Image(systemName: node.systemImageName)
                .frame(width: iconColWidth, alignment: .center)
                .foregroundColor(statusColor)
            Text(node.name).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            
            // Status indicator for connecting/reconnecting states
            if server.connectionStatus == .connecting || server.connectionStatus == .reconnecting {
                Image(systemName: "ellipsis")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .symbolEffect(.variableColor.iterative, isActive: true)
            }
        }
        .contextMenu {
            if server.isConnected { 
                Button("Disconnect…", action: disconnect)
                Button("Join Channel…", action: joinChannelPrompt)
            } else if server.connectionStatus == .connecting || server.connectionStatus == .reconnecting {
                Button("Cancel Connection", action: disconnect)
            } else { 
                Button("Connect…", action: connect)
            }
            Divider()
            Button("Edit Server…", action: editServer)
            Divider()
            Button(role: .destructive) { deleteServer() } label: { Text("Delete Server…") }
        }
        .onTapGesture(perform: select)
    }
}

struct ChannelRow: View {
    let channel: IRCChannel
    let isSelected: Bool
    let rowHeight: CGFloat
    let iconColWidth: CGFloat
    let indentWidth: CGFloat
    let activeState: ControlActiveState
    let select: () -> Void
    let part: () -> Void
    var body: some View {
        let node = SidebarItem(kind: .channel(channel))
        SidebarRowBase(isSelected: isSelected, indent: indentWidth, rowHeight: rowHeight, activeState: activeState) {
            Image(systemName: node.systemImageName)
                .frame(width: iconColWidth, alignment: .center)
                .overlay(alignment: .topTrailing) {
                    if channel.unreadCount > 0 {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .offset(x: 2, y: -2)
                    }
                }
            Text(node.name).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
        }
        .contextMenu { Button("Part Channel", action: part) }
        .onTapGesture(perform: select)
    }
}

struct PrivateMessageRow: View {
    let privateMessage: IRCPrivateMessage
    let isSelected: Bool
    let rowHeight: CGFloat
    let iconColWidth: CGFloat
    let indentWidth: CGFloat
    let activeState: ControlActiveState
    let select: () -> Void
    let close: () -> Void
    var body: some View {
        let node = SidebarItem(kind: .privateMessage(privateMessage))
        SidebarRowBase(isSelected: isSelected, indent: indentWidth, rowHeight: rowHeight, activeState: activeState) {
            Image(systemName: node.systemImageName)
                .frame(width: iconColWidth, alignment: .center)
                .overlay(alignment: .topTrailing) {
                    if privateMessage.unreadCount > 0 {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .offset(x: 2, y: -2)
                    }
                }
            Text(node.name).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
        }
        .contextMenu { Button("Close Conversation", action: close) }
        .onTapGesture(perform: select)
    }
}

struct SidebarItem: Identifiable, Hashable {
    enum Kind { case server(IRCServer), channel(IRCChannel), privateMessage(IRCPrivateMessage) }
    let kind: Kind

    var id: UUID {
        switch kind { 
        case .server(let s): return s.id
        case .channel(let c): return c.id
        case .privateMessage(let pm): return pm.id
        }
    }
    var name: String {
        switch kind { 
        case .server(let s): return s.name
        case .channel(let c): return c.name
        case .privateMessage(let pm): return pm.nickname
        }
    }
    var systemImageName: String {
        switch kind {
        case .channel: return "rectangle.3.group.bubble"
        case .privateMessage: return "person.2"
        case .server(let s): 
            switch s.connectionStatus {
            case .connected: return "network"
            case .connecting: return "network.badge.shield.half.filled"
            case .reconnecting: return "arrow.clockwise.circle"
            case .connectionTimeout, .reconnectionFailed: return "network.slash"
            case .disconnected: return "network.slash"
            }
        }
    }

    static func == (lhs: SidebarItem, rhs: SidebarItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Dialogs & Preferences

struct PreferencesView: View {
    @Environment(AppPreferences.self) private var prefs

    private var numberFormatter: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimum = 1
        return f
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Number of lines to keep in log:")
                    HStack(spacing: 8) {
                        TextField("Lines", value: Binding(get: { prefs.maxLogLines }, set: { prefs.maxLogLines = max(1, $0) }), formatter: numberFormatter)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Stepper("", value: Binding(get: { prefs.maxLogLines }, set: { prefs.maxLogLines = max(1, $0) }), in: 1...100000)
                            .labelsHidden()
                    }
                }
                GridRow {
                    Text("Show image thumbnails:")
                    Toggle("", isOn: Binding(get: { prefs.showImageThumbnails }, set: { prefs.showImageThumbnails = $0 }))
                        .labelsHidden()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct ServerEditorView: View {
    @Environment(ChatStore.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = "6667"
    @State private var password: String = ""
    @State private var useTLS: Bool = false
    @State private var autoConnectOnLaunch: Bool = false
    private var validPort: Int? { Int(port).flatMap { (1...65535).contains($0) ? $0 : nil } }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !host.trimmingCharacters(in: .whitespaces).isEmpty && validPort != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Server").font(.headline)
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow { Text("Name:"); TextField("Display name", text: $name).textFieldStyle(.roundedBorder) }
                GridRow { Text("Server:"); TextField("irc.example.net", text: $host).textFieldStyle(.roundedBorder) }
                GridRow { Text("Port:"); TextField("6667", text: $port).textFieldStyle(.roundedBorder) }
                GridRow { Text("Password:"); SecureField("Optional", text: $password).textFieldStyle(.roundedBorder) }
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
                    model.addServer(name: name, host: host, port: p, password: pwd, useTLS: useTLS, autoConnectOnLaunch: autoConnectOnLaunch)
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

struct EditServerView: View {
    @Environment(ChatStore.self) private var model
    @Environment(\.dismiss) private var dismiss
    let server: IRCServer
    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = "6667"
    @State private var password: String = ""
    @State private var useTLS: Bool = false
    @State private var autoConnectOnLaunch: Bool = false
    private var validPort: Int? { Int(port).flatMap { (1...65535).contains($0) ? $0 : nil } }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !host.trimmingCharacters(in: .whitespaces).isEmpty && validPort != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Server").font(.headline)
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow { Text("Name:"); TextField("Display name", text: $name).textFieldStyle(.roundedBorder) }
                GridRow { Text("Server:"); TextField("irc.example.net", text: $host).textFieldStyle(.roundedBorder) }
                GridRow { Text("Port:"); TextField("6667", text: $port).textFieldStyle(.roundedBorder) }
                GridRow { Text("Password:"); SecureField("Optional", text: $password).textFieldStyle(.roundedBorder) }
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
                    model.updateServer(id: server.id, name: name, host: host, port: p, password: pwd, useTLS: useTLS, autoConnectOnLaunch: autoConnectOnLaunch)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .onAppear {
            name = server.name
            host = server.host
            port = String(server.port)
            password = server.password ?? ""
            useTLS = server.useTLS
            autoConnectOnLaunch = server.autoConnectOnLaunch
        }
        .padding(16)
        .frame(width: 420)
    }
}

struct JoinChannelView: View {
    @Environment(ChatStore.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    private var canJoin: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.hasPrefix("#")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Join Channel").font(.headline)
            HStack {
                Text("Channel:")
                TextField("#channel", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onAppear { name = model.joinChannelDraft }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Join") {
                    guard canJoin, let server = model.server(withID: model.pendingJoinServerID) else { return }
                    model.joinChannel(name, on: server)
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
    init(@ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right, autosaveName: String) {
        self.left = left()
        self.right = right()
        self.autosaveName = autosaveName
    }
    func makeNSView(context: Context) -> NSSplitView {
        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin
        let leftHost = NSHostingView(rootView: left)
        let rightHost = NSHostingView(rootView: right)
        split.addArrangedSubview(leftHost); split.addArrangedSubview(rightHost)
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
