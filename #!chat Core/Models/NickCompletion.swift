import Foundation

/// Completing a nickname with Tab in the composer. The text field does the editing; this decides
/// what to complete, with whom, and what to put in.
enum NickCompletion {
    /// The word that ends at `cursor` in `text`, the part of a nickname typed so far; nil when
    /// the cursor doesn't follow a word. Positions are UTF-16 offsets, as AppKit counts them.
    static func partialWord(in text: String, endingAt cursor: Int) -> NSRange? {
        let string = text as NSString
        guard cursor <= string.length else { return nil }
        var start = cursor
        while start > 0 {
            // Half of a surrogate pair is no scalar, and no space either.
            if let scalar = Unicode.Scalar(string.character(at: start - 1)),
               CharacterSet.whitespacesAndNewlines.contains(scalar) { break }
            start -= 1
        }
        return start < cursor ? NSRange(location: start, length: cursor - start) : nil
    }

    /// The candidates that start with `partial`, whatever its case, in the order given.
    static func matches(for partial: String, among candidates: [String]) -> [String] {
        let prefix = partial.lowercased()
        return candidates.filter { $0.lowercased().hasPrefix(prefix) }
    }

    /// What replaces the partial word: `nick: ` when it opens the line, to address someone, and
    /// `nick ` anywhere else.
    static func insertion(for nick: String, atStartOfLine: Bool) -> String {
        atStartOfLine ? "\(nick): " : "\(nick) "
    }

    /// Whom to offer in a channel, in order: the people who spoke most recently first, since
    /// they're the likeliest to be answered, then everyone else as the member list has them.
    /// Never ourselves.
    static func candidates(members: [String], log: [ChatMessage], ownNick: String?) -> [String] {
        var recent: [String] = []
        for message in log.suffix(recentMessages).reversed() where message.isPrivmsg && !message.isFromMe {
            guard let sender = message.senderNick,
                  !recent.contains(where: { IRCName.equal($0, sender) }),
                  let member = members.first(where: { IRCName.equal($0, sender) }) else { continue }
            recent.append(member)
        }
        let others = members.filter { member in !recent.contains { IRCName.equal($0, member) } }
        return (recent + others).filter { nick in ownNick.map { !IRCName.equal($0, nick) } ?? true }
    }

    /// How far back in a log to look for recent speakers.
    private static let recentMessages = 200
}
