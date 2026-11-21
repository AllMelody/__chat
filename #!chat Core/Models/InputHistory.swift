/// The lines sent from the composer, for bringing them back with ↑ and ↓ the way a shell does.
nonisolated struct InputHistory {
    static let capacity = 100

    private var lines: [String] = []
    /// Which of `lines` is showing; nil while the user is on a line of their own.
    private var position: Int?
    /// What the user had typed before they started going back, to return to after the newest line.
    private var draft = ""

    /// Remembers a line that was sent. Going back starts from it again.
    mutating func add(_ line: String) {
        position = nil
        draft = ""
        guard !line.allSatisfy(\.isWhitespace), line != lines.last else { return }
        lines.append(line)
        if lines.count > Self.capacity { lines.removeFirst() }
    }

    /// The line before the one showing, or nil when there's none older. `current` is what the
    /// composer holds now, kept as the draft when this is the first step back.
    mutating func older(than current: String) -> String? {
        guard let index = position.map({ $0 - 1 }) ?? lines.indices.last, index >= 0 else { return nil }
        if position == nil { draft = current }
        position = index
        return lines[index]
    }

    /// The line after the one showing, ending with the draft; nil when not going back at all.
    mutating func newer() -> String? {
        guard let position else { return nil }
        guard position + 1 < lines.count else {
            self.position = nil
            return draft
        }
        self.position = position + 1
        return lines[position + 1]
    }
}
