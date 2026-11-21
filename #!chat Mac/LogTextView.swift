import AppKit
import SwiftUI

extension NSAttributedString.Key {
    /// Marks the text of a nick-mention line; the value is the wash NSColor. Drawn by
    /// LogLayoutManager across the full line width instead of just behind the glyphs.
    static let ircHighlightLine = NSAttributedString.Key("ircHighlightLine")
}

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

struct LogTextView: NSViewRepresentable {
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
