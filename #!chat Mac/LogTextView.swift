import Accessibility
import AppKit
import SwiftUI

extension NSAttributedString.Key {
    /// Marks the text of a nick-mention line; the value is the wash NSColor. Drawn by
    /// LogLayoutManager across the full line width instead of just behind the glyphs.
    nonisolated static let ircHighlightLine = NSAttributedString.Key("ircHighlightLine")
    /// Marks the attachment of an animated thumbnail; the value is the URL of the cached GIF.
    /// The log plays it over the attachment while it's in view.
    nonisolated static let ircAnimatedThumbnail = NSAttributedString.Key("ircAnimatedThumbnail")
}

/// TextKit 1 layout manager for the chat log. For ranges tagged .ircHighlightLine it fills
/// each line fragment edge to edge with the marker's color, underneath normal background
/// and selection drawing (super runs after, so selection stays visible on top).
///
/// NSLayoutManager isn't tied to the main actor, so a subclass can't be either. Of what this
/// one reads, only the text view's width is the main actor's; the view draws on the main thread.
private nonisolated final class LogLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage, let textView = textContainers.first?.textView {
            // Full view width on purpose (not the fragment rect), so the wash also
            // covers the container inset gutters.
            let width = MainActor.assumeIsolated { textView.bounds.width }
            let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            storage.enumerateAttribute(.ircHighlightLine, in: charRange, options: []) { value, range, _ in
                guard let color = value as? NSColor else { return }
                color.setFill()
                let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                self.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, _, _ in
                    NSRect(x: 0, y: rect.minY + origin.y, width: width, height: rect.height)
                        .fill(using: .sourceOver)
                }
            }
            // The log's coordinator is the text view's delegate.
            MainActor.assumeIsolated { (textView.delegate as? LogTextView.Coordinator)?.textWasDrawn() }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

/// An animated thumbnail, playing over the attachment that shows its first frame. The text view
/// can't draw the next frame without drawing its text again, where a layer's frames are played
/// by Core Animation, with nothing for the app to do. Until the frames are drawn, and if they
/// can't be, there's nothing in the layer and the attachment shows through it.
private final class AnimatedThumbnailView: NSView {
    let file: URL
    private var loading: Task<Void, Never>?

    init(file: URL, frame: NSRect, maxPixelSize: Int) {
        self.file = file
        super.init(frame: frame)
        wantsLayer = true
        loading = Task { [weak self] in
            guard let frames = await AnimationFrames.load(from: file, maxPixelSize: maxPixelSize) else { return }
            self?.layer?.add(frames.animation, forKey: "frames")
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Gone from the log before its frames were drawn: nobody's waiting for the rest of them.
    isolated deinit { loading?.cancel() }

    /// Clicks and selections are the text's, attachment included.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Whether the frames stand still. It's the layer's clock that stops, which holds the frame
    /// it stopped on and goes on from there; taking the animation away would start it over.
    var isPaused = false {
        didSet {
            guard isPaused != oldValue, let layer else { return }
            if isPaused {
                let stoppedAt = layer.convertTime(CACurrentMediaTime(), from: nil)
                layer.speed = 0
                layer.timeOffset = stoppedAt
            } else {
                let stoppedAt = layer.timeOffset
                layer.speed = 1
                layer.timeOffset = 0
                layer.beginTime = 0
                layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - stoppedAt
            }
        }
    }
}

struct LogTextView: NSViewRepresentable {
    /// Bumped on every log change in the app; being a property is what gets the view updated.
    let logVersion: Int
    let selectionToken: UUID?
    let messages: [ChatMessage]
    let thumbnailsByMessage: [UUID: [MessageThumbnail]]
    let showThumbnails: Bool
    /// Whether animated thumbnails play. They stand still, where they were, while they don't:
    /// in a window that isn't the one in use, moving pictures are in the corner of the eye.
    let playsAnimatedThumbnails: Bool
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
        /// What's playing: one for each animated thumbnail in view, from the top down.
        fileprivate var animatedThumbnails: [AnimatedThumbnailView] = []
        /// See LogTextView.playsAnimatedThumbnails.
        var animatedThumbnailsArePaused = false {
            didSet { for view in animatedThumbnails { view.isPaused = animatedThumbnailsArePaused } }
        }
        private var isUpdatingAnimatedThumbnailsSoon = false
        var animatedImagesObserver: Any?

        isolated deinit {
            if let observer = boundsObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = frameObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = animatedImagesObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        /// The text has just been drawn, so it may have been laid out again and its attachments
        /// moved, as when the log's width changes. What's playing follows once the drawing is
        /// over: views aren't to be moved in the middle of it.
        func textWasDrawn() {
            guard !isUpdatingAnimatedThumbnailsSoon else { return }
            isUpdatingAnimatedThumbnailsSoon = true
            Task {
                isUpdatingAnimatedThumbnailsSoon = false
                updateAnimatedThumbnails()
            }
        }

        /// Gives each animated thumbnail in view something playing it, placed where its
        /// attachment is now, and takes away what was playing those no longer in view or in the
        /// log. So it's called whenever the text, its layout or the part of it in view changes.
        /// Only what's in view plays, because playing takes memory: every frame, drawn.
        ///
        /// It reads the layout there is, and never asks for any: laying text out from here,
        /// inside the scroll view's notifications, moves where the log ends up scrolled to.
        func updateAnimatedThumbnails() {
            guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer,
                  let storage = textView.textStorage else { return }
            let visible = textView.visibleRect
            let origin = textView.textContainerOrigin
            // Text is laid out from the top. Until that has reached the end of what's in view,
            // as it hasn't just after an edit, nothing says where the attachments are, and what's
            // playing stays as it is. The text is drawn once it's laid out, which comes back here.
            guard layoutManager.firstUnlaidCharacterIndex() >= storage.length
                    || origin.y + layoutManager.usedRect(for: container).maxY >= visible.maxY else { return }

            var leftover = animatedThumbnails
            animatedThumbnails = []
            // "Auto-Play Animated Images", in the system's Accessibility settings.
            if AccessibilitySettings.animatedImagesEnabled, !visible.isEmpty {
                let glyphs = layoutManager.glyphRange(forBoundingRectWithoutAdditionalLayout: visible.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
                let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                storage.enumerateAttribute(.ircAnimatedThumbnail, in: characters) { value, range, _ in
                    guard let file = value as? URL else { return }
                    // An attachment sits on its line's baseline.
                    let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
                    let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
                    let baseline = layoutManager.location(forGlyphAt: glyph)
                    let size = layoutManager.attachmentSize(forGlyphAt: glyph)
                    let frame = NSRect(x: origin.x + line.minX + baseline.x, y: origin.y + line.minY + baseline.y - size.height,
                                       width: size.width, height: size.height)
                    guard frame.intersects(visible) else { return }

                    if let index = leftover.firstIndex(where: { $0.file == file }) {
                        let view = leftover.remove(at: index)
                        // Only a real move: this runs after every drawing, and must not cause one.
                        if view.frame != frame { view.frame = frame }
                        animatedThumbnails.append(view)
                    } else {
                        // Frames with the pixels this screen shows the thumbnail in.
                        let scale = textView.window?.backingScaleFactor ?? 1
                        let view = AnimatedThumbnailView(file: file, frame: frame, maxPixelSize: Int(max(size.width, size.height) * scale))
                        textView.addSubview(view)
                        view.isPaused = animatedThumbnailsArePaused
                        animatedThumbnails.append(view)
                    }
                }
            }
            for view in leftover { view.removeFromSuperview() }
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
            MainActor.assumeIsolated {
                guard let coordinator, let tv = coordinator.textView, let sv = coordinator.scrollView else { return }
                coordinator.isPinnedToBottom = isAtBottom(textView: tv, scrollView: sv)
                coordinator.updateAnimatedThumbnails()
            }
        }
        scroll.postsFrameChangedNotifications = true
        coordinator.frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak coordinator] _ in
            MainActor.assumeIsolated {
                guard let coordinator, let tv = coordinator.textView else { return }
                if coordinator.isPinnedToBottom {
                    tv.scrollToEndOfDocument(nil)
                }
                coordinator.updateAnimatedThumbnails()
            }
        }
        coordinator.animatedImagesObserver = NotificationCenter.default.addObserver(forName: AccessibilitySettings.animatedImagesEnabledDidChangeNotification, object: nil, queue: .main) { [weak coordinator] _ in
            MainActor.assumeIsolated { coordinator?.updateAnimatedThumbnails() }
        }
        coordinator.onFindBarClosed = onFindBarClosed
        coordinator.animatedThumbnailsArePaused = !playsAnimatedThumbnails
        coordinator.findBarObservation
 = scroll.observe(\.isFindBarVisible, options: [.new]) { [weak coordinator] _, change in
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
        coordinator.animatedThumbnailsArePaused = !playsAnimatedThumbnails

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
            coordinator.updateAnimatedThumbnails()
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
        // Chat body or non-chat line: label color, with links detected. A server's reply is
        // secondary, like the time.
        combined.append(Self.linkified(msg.text, attributes: msg.isReply ? Self.grayAttributes : attrs))

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
                let attachment = NSTextAttachment()
                // Until the image has loaded, a blank one holds a place for it.
                attachment.image = item.image.map { NSImage(cgImage: $0, size: Self.thumbnailSize(for: $0)) }
                    ?? Self.thumbnailPlaceholder
                let attStr = NSMutableAttributedString(attachment: attachment)
                let range = NSRange(location: 0, length: attStr.length)
                attStr.addAttribute(.link, value: item.url, range: range)
                attStr.addAttribute(.underlineStyle, value: 0, range: range)
                if item.image != nil, let animation = item.animation {
                    attStr.addAttribute(.ircAnimatedThumbnail, value: animation, range: range)
                }
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

    /// The size a thumbnail shows at: fitted into 200 points either way (a smaller image grows to
    /// fit), in whole points. NSImage draws the image's own pixels, up to 600 either way, at the
    /// screen's resolution by itself. What blurs a thumbnail is a size with a fraction of a point
    /// in it, like 200 × 133.33: its edges fall between pixels, and so does every line after it.
    private static func thumbnailSize(for image: CGImage) -> NSSize {
        let scale = min(200 / CGFloat(image.width), 200 / CGFloat(image.height))
        return NSSize(width: max(1, (CGFloat(image.width) * scale).rounded()),
                      height: max(1, (CGFloat(image.height) * scale).rounded()))
    }

    /// Space for a thumbnail that hasn't loaded yet. It draws nothing.
    private static let thumbnailPlaceholder = NSImage(size: NSSize(width: 200, height: 150))
}
