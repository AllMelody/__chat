import Foundation
import Observation

@Observable
final class IRCChannel: Identifiable {
    let id = UUID()
    var name: String
    var topic: String?
    var users: [String] = []
    var log: [ChatMessage] = []
    var unreadCount: Int = 0
    var joined: Bool = false
    /// We were kicked out and haven't rejoined since. Reconnecting doesn't rejoin it either:
    /// going back is the user's call.
    var wasKicked: Bool = false
    /// The key (channel password) we joined with, to rejoin with after a reconnect.
    var key: String?

    init(name: String) { self.name = name }

    // MARK: - User Management Helpers
    // Nicks are compared the way the server compares them (IRCName.equal).

    /// Check if a user is present in the channel
    func hasUser(_ nick: String) -> Bool {
        users.contains { IRCName.equal($0, nick) }
    }

    /// Add a user to the channel if not already present
    func addUserIfNotPresent(_ nick: String) {
        if !hasUser(nick) {
            users.append(nick)
        }
    }

    /// Remove a user from the channel
    func removeUser(_ nick: String) {
        users.removeAll { IRCName.equal($0, nick) }
    }

    /// Update a user's nickname, keeping the new nick's case as given
    func updateUserNick(from oldNick: String, to newNick: String) {
        if let index = users.firstIndex(where: { IRCName.equal($0, oldNick) }) {
            users[index] = newNick
        }
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