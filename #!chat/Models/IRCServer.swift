import Foundation
import Observation

@Observable
final class IRCServer: Identifiable, Hashable {
    static func == (lhs: IRCServer, rhs: IRCServer) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    let id: UUID
    var name: String
    var host: String
    var port: Int
    var password: String?
    var useTLS: Bool = false
    var channels: [IRCChannel] = []
    var privateMessages: [IRCPrivateMessage] = []
    var log: [ChatMessage] = []
    var autoConnectOnLaunch: Bool = false
    // Last known nickname for this server (set on register or nick change)
    var currentNick: String? = nil
    
    // Connection status tracking - single source of truth
    var connectionStatus: ConnectionStatus = .disconnected

    // Computed property for backwards compatibility - derives from connectionStatus
    var isConnected: Bool {
        connectionStatus == .connected
    }
    var lastConnectionAttempt: Date?
    var reconnectionAttempts: Int = 0
    var maxReconnectionAttempts: Int = 5
    var reconnectionDelay: TimeInterval = 5.0
    var shouldAutoReconnect: Bool = true
    
    enum ConnectionStatus {
        case disconnected
        case connecting
        case connected
        case connectionTimeout
        case reconnecting
        case reconnectionFailed
    }

    init(id: UUID = UUID(), name: String, host: String, port: Int, password: String?, useTLS: Bool = false, autoConnectOnLaunch: Bool = false) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.password = password
        self.useTLS = useTLS
        self.autoConnectOnLaunch = autoConnectOnLaunch
    }

    // MARK: - Channel/PM Helpers

    /// Gets existing channel or creates a new one (case-insensitive match)
    func getOrCreateChannel(named name: String) -> IRCChannel {
        if let existing = channels.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return existing
        }
        let channel = IRCChannel(name: name)
        channels.append(channel)
        return channel
    }

    /// Gets existing PM or creates a new one (case-insensitive match)
    func getOrCreatePrivateMessage(with nickname: String) -> IRCPrivateMessage {
        if let existing = privateMessages.first(where: { $0.nickname.caseInsensitiveCompare(nickname) == .orderedSame }) {
            return existing
        }
        let pm = IRCPrivateMessage(nickname: nickname)
        privateMessages.append(pm)
        return pm
    }

    // MARK: - Persistence

    func toRecord() -> IRCServerRecord {
        IRCServerRecord(id: id, name: name, host: host, port: port, password: password, useTLS: useTLS, autoConnectOnLaunch: autoConnectOnLaunch)
    }

    convenience init(from r: IRCServerRecord) {
        self.init(id: r.id, name: r.name, host: r.host, port: r.port, password: r.password, useTLS: r.useTLS ?? false, autoConnectOnLaunch: r.autoConnectOnLaunch ?? false)
    }
}

struct IRCServerRecord: Codable {
    let id: UUID
    let name: String
    let host: String
    let port: Int
    let password: String?
    let useTLS: Bool?
    let autoConnectOnLaunch: Bool?
}