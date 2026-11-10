import Foundation
import Observation

@Observable
final class IRCChannel: Identifiable {
    let id = UUID()
    var name: String
    var topic: String?
    /// Who's in the channel, in the order the member list shows them. The helpers below keep
    /// it sorted as it changes, so showing it never has to sort.
    private(set) var users: [String] = []
    var log: [ChatMessage] = []
    var unreadCount: Int = 0
    /// How many of the unread messages mention us.
    var mentionCount: Int = 0
    var joined: Bool = false
    /// We were kicked out and haven't rejoined since. Reconnecting doesn't rejoin it either:
    /// going back is the user's call.
    var wasKicked: Bool = false
    /// The key (channel password) we joined with, to rejoin with after a reconnect.
    var key: String?
    /// Saved with its server, to join again the next time the app launches: a channel we've
    /// been in and haven't parted or been kicked from.
    var isSaved: Bool = false

    init(name: String) { self.name = name }

    // MARK: - User Management Helpers
    // Nicks are compared the way the server compares them (IRCName.equal).

    /// Check if a user is present in the channel
    func hasUser(_ nick: String) -> Bool {
        users.contains { IRCName.equal($0, nick) }
    }

    /// Replaces the member list, as a complete NAMES reply does
    func setUsers(_ nicks: [String]) {
        users = nicks.sorted(by: Self.sortsBefore)
    }

    /// Empties the member list: we're no longer in the channel to know
    func removeAllUsers() {
        users.removeAll()
    }

    /// Add a user to the channel if not already present
    func addUserIfNotPresent(_ nick: String) {
        if !hasUser(nick) { insert(nick) }
    }

    /// Remove a user from the channel
    func removeUser(_ nick: String) {
        users.removeAll { IRCName.equal($0, nick) }
    }

    /// Update a user's nickname, keeping the new nick's case as given
    func updateUserNick(from oldNick: String, to newNick: String) {
        guard let index = users.firstIndex(where: { IRCName.equal($0, oldNick) }) else { return }
        users.remove(at: index)
        insert(newNick)
    }

    /// Puts `nick` where it sorts: before the first member that comes after it.
    private func insert(_ nick: String) {
        var low = 0, high = users.count
        while low < high {
            let middle = (low + high) / 2
            if Self.sortsBefore(nick, users[middle]) { high = middle } else { low = middle + 1 }
        }
        users.insert(nick, at: low)
    }

    /// The member list's order, the Finder's: case doesn't matter, and numbers count up.
    private nonisolated static func sortsBefore(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }
}

@Observable
final class IRCPrivateMessage: Identifiable {
    let id = UUID()
    var nickname: String
    var log: [ChatMessage] = []
    var unreadCount: Int = 0

    init(nickname: String) { self.nickname = nickname }
}
