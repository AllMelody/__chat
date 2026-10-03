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
    /// The source of truth for attempt counting and policy is ReconnectionManager;
    /// this is updated via the IRCConnectionService -> ReconnectionManagerDelegate hop
    /// and reset to 0 on a successful connect or an explicit disconnect.
    var displayAttempt: Int = 0
    var shouldAutoReconnect: Bool = true
    
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

    /// Existing channel with this name (case-insensitive match)
    func channel(named name: String) -> IRCChannel? {
        channels.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Existing PM conversation with this nick (case-insensitive match)
    func privateMessage(with nickname: String) -> IRCPrivateMessage? {
        privateMessages.first { $0.nickname.caseInsensitiveCompare(nickname) == .orderedSame }
    }

    /// Gets existing channel or creates a new one (case-insensitive match)
    func getOrCreateChannel(named name: String) -> IRCChannel {
        if let existing = channel(named: name) { return existing }
        let channel = IRCChannel(name: name)
        channels.append(channel)
        return channel
    }

    /// Gets existing PM or creates a new one (case-insensitive match)
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