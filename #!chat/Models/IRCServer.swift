import Foundation
import Observation

@Observable
final class IRCServer: Identifiable {
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
    var currentNick: String?

    // Per-server preferred nickname (nil/empty = use the app-wide default). Set by the user.
    var nickname: String?

    // Connection status tracking - single source of truth
    var connectionStatus: ConnectionStatus = .disconnected

    /// Convenience derived from connectionStatus.
    var isConnected: Bool {
        connectionStatus == .connected
    }
    /// Read-only mirror of the current reconnection attempt, for log/display only.
    /// The source of truth for attempt counting and policy is ReconnectionPolicy;
    /// IRCConnectionService sets this whenever it schedules a reconnect, and resets it to 0
    /// once a connection proves stable (its first PONG), when the user connects, or on an
    /// explicit disconnect.
    var displayAttempt: Int = 0
    /// Whether the app should bring this connection back by itself after a drop, a wake from
    /// sleep, or a network outage. Set when the user (or auto-connect on launch) connects;
    /// cleared by an explicit disconnect, a rejected registration, or running out of retries.
    var shouldAutoReconnect: Bool = false
    
    enum ConnectionStatus {
        case disconnected
        case connecting
        case connected
        case connectionTimeout
        case reconnecting
        case reconnectionFailed
    }

    init(id: UUID = UUID(), name: String, host: String, port: Int, password: String?, useTLS: Bool = false, autoConnectOnLaunch: Bool = false, nickname: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.password = password
        self.useTLS = useTLS
        self.autoConnectOnLaunch = autoConnectOnLaunch
        self.nickname = nickname
    }

    // MARK: - Channel/PM Helpers
    // Names are matched the way the server matches them (IRCName.equal).

    /// Existing channel with this name
    func channel(named name: String) -> IRCChannel? {
        channels.first { IRCName.equal($0.name, name) }
    }

    /// Existing PM conversation with this nick
    func privateMessage(with nickname: String) -> IRCPrivateMessage? {
        privateMessages.first { IRCName.equal($0.nickname, nickname) }
    }

    /// Gets existing channel or creates a new one
    func getOrCreateChannel(named name: String) -> IRCChannel {
        if let existing = channel(named: name) { return existing }
        let channel = IRCChannel(name: name)
        channels.append(channel)
        return channel
    }

    /// Gets existing PM or creates a new one
    func getOrCreatePrivateMessage(with nickname: String) -> IRCPrivateMessage {
        if let existing = privateMessage(with: nickname) { return existing }
        let pm = IRCPrivateMessage(nickname: nickname)
        privateMessages.append(pm)
        return pm
    }

    // MARK: - Persistence

    func toRecord() -> IRCServerRecord {
        IRCServerRecord(id: id, name: name, host: host, port: port, useTLS: useTLS, autoConnectOnLaunch: autoConnectOnLaunch, nickname: nickname)
    }

    convenience init(from r: IRCServerRecord) {
        // Password is NOT taken from the record (it is only the legacy migration value).
        // ChatStore.loadServers populates `password` from the Keychain after constructing.
        self.init(id: r.id, name: r.name, host: r.host, port: r.port, password: nil, useTLS: r.useTLS ?? false, autoConnectOnLaunch: r.autoConnectOnLaunch ?? false, nickname: r.nickname)
    }
}

struct IRCServerRecord: Codable {
    let id: UUID
    let name: String
    let host: String
    let port: Int
    /// Legacy plaintext password. Only ever DECODED from old persisted JSON for a
    /// one-time migration into the Keychain; never encoded going forward.
    let password: String?
    let useTLS: Bool?
    let autoConnectOnLaunch: Bool?
    let nickname: String?

    init(id: UUID, name: String, host: String, port: Int, password: String? = nil, useTLS: Bool?, autoConnectOnLaunch: Bool?, nickname: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.password = password
        self.useTLS = useTLS
        self.autoConnectOnLaunch = autoConnectOnLaunch
        self.nickname = nickname
    }

    // Custom encode: deliberately OMIT password so it never returns to plaintext storage.
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encodeIfPresent(useTLS, forKey: .useTLS)
        try c.encodeIfPresent(autoConnectOnLaunch, forKey: .autoConnectOnLaunch)
        try c.encodeIfPresent(nickname, forKey: .nickname)
        // password intentionally not encoded
    }

    // Decoding is synthesized: optionals use decodeIfPresent, so `password` is still read
    // from legacy JSON and is nil for new JSON.
}