import Foundation

/// How the log view brings the text it has rendered up to date with a conversation's log.
///
/// A log only loses lines at the front (trimmed past the cap) and gains them at the end, and a
/// line that stays changes only when its thumbnails do. So nearly every update is a small edit
/// of the rendered text, which, unlike rendering it all again, costs little and leaves the
/// reader's selection and place alone.
nonisolated enum LogUpdate: Equatable {
    /// A rendered line: its message, and a fingerprint of the thumbnails drawn under it.
    struct Line: Equatable {
        var id: UUID
        var thumbnails: Int
    }

    /// What's rendered is current.
    case none
    /// Nothing rendered carries over, as when another conversation is selected: render it all.
    case rebuild
    /// Remove the first `dropped` rendered lines, render again the lines at `changed` (indexes
    /// into the new list), and add the new list's lines from `appendFrom` on.
    case edit(dropped: Int, changed: [Int], appendFrom: Int)

    static func plan(from old: [Line], to new: [Line]) -> LogUpdate {
        guard let first = new.first, let dropped = old.firstIndex(where: { $0.id == first.id }) else {
            return old.isEmpty && new.isEmpty ? .none : .rebuild
        }
        let kept = old.count - dropped
        guard kept <= new.count, zip(old[dropped...], new).allSatisfy({ $0.id == $1.id }) else { return .rebuild }

        let changed = (0..<kept).filter { old[dropped + $0].thumbnails != new[$0].thumbnails }
        if dropped == 0, changed.isEmpty, kept == new.count { return .none }
        return .edit(dropped: dropped, changed: changed, appendFrom: kept)
    }
}
