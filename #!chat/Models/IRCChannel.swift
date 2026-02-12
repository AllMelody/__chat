import Foundation
import Observation

@Observable
final class IRCChannel: Identifiable, Hashable {
    static func == (lhs: IRCChannel, rhs: IRCChannel) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    let id = UUID()
    var name: String
    var topic: String? = nil
    var users: [String] = []
    var log: [ChatMessage] = []
    var unreadCount: Int = 0
    var joined: Bool = false

    init(name: String) { self.name = name }

    // MARK: - User Management Helpers (case-insensitive)

    /// Check if a user is present in the channel (case-insensitive)
    func hasUser(_ nick: String) -> Bool {
        users.contains(where: { $0.lowercased() == nick.lowercased() })
    }

    /// Add a user to the channel if not already present (case-insensitive check)
    func addUserIfNotPresent(_ nick: String) {
        if !hasUser(nick) {
            users.append(nick)
        }
    }

    /// Remove a user from the channel (case-insensitive)
    func removeUser(_ nick: String) {
        users.removeAll { $0.lowercased() == nick.lowercased() }
    }

    /// Update a user's nickname (case-insensitive search, preserves case of new nick)
    func updateUserNick(from oldNick: String, to newNick: String) {
        if let index = users.firstIndex(where: { $0.lowercased() == oldNick.lowercased() }) {
            users[index] = newNick
        }
    }
}

@Observable
final class IRCPrivateMessage: Identifiable, Hashable {
    static func == (lhs: IRCPrivateMessage, rhs: IRCPrivateMessage) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    let id = UUID()
    var nickname: String
    var log: [ChatMessage] = []
    var unreadCount: Int = 0

    init(nickname: String) { self.nickname = nickname }
}