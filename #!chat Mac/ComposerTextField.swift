import AppKit
import SwiftUI

// MARK: - Composer (NSTextField wrapper to avoid placeholder shift on focus change)

struct ComposerTextField: NSViewRepresentable {
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
