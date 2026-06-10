import Foundation
import Observation

@Observable
final class ChatStore: IRCConnectionServiceDelegate, MessageRouterDelegate {
    // Services
    private let connectionService = IRCConnectionService()
    private let imageCache = ImageCacheService()
    private let messageRouter = MessageRouter()
    private let keychain = KeychainService()

    // Core data
    var servers: [IRCServer] = [] { didSet { persistServers() } }

    // Selection (server or channel id)
    var selectedNodeID: UUID? = nil

    // Thumbnail data - stored here so @Observable triggers view updates
    var messageThumbnails: [UUID: [MessageThumbnail]] = [:]

    // Bumped on every log mutation to guarantee view invalidation.
    // Works as a safety net when @Observable tracking breaks after sleep/wake.
    var logVersion: Int = 0
    
    // UI state
    var isPresentingAddServer: Bool = false
    var isPresentingEditServer: Bool = false
    var isPresentingJoinChannel: Bool = false
    var pendingJoinServerID: UUID? = nil
    var pendingEditServerID: UUID? = nil
    var joinChannelDraft: String = ""
    var isPresentingTopicEditor: Bool = false
    
    // Preferences
    weak var preferences: AppPreferences?
    
    init() {
        setupServices()
        loadServers()
        // Delay auto-connect to ensure UI is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in 
            self?.autoConnectFlaggedServers() 
        }
    }
    
    private func setupServices() {
        connectionService.delegate = self
        connectionService.configureServerLookup { [weak self] serverID in
            self?.servers.first { $0.id == serverID }
        }
        messageRouter.delegate = self
        imageCache.onThumbnailUpdated = { [weak self] messageID, thumbnails in
            self?.messageThumbnails[messageID] = thumbnails
        }
    }

    /// Pushes preference values that backing services mirror (currently the raw-traffic debug
    /// log). Call after `preferences` is set and whenever the relevant preference changes.
    func syncPreferencesToServices() {
        connectionService.debugRawServerLog = preferences?.debugRawServerLog ?? false
    }
    
    // MARK: - Thumbnails

    func scanMessageForThumbnails(_ message: ChatMessage) {
        imageCache.scanMessageForThumbnails(message, showImageThumbnails: preferences?.showImageThumbnails ?? false)
    }
    
    // MARK: - Connection Management
    
    func connect(_ server: IRCServer) {
        connectionService.connect(server)
    }
    
    func disconnect(_ server: IRCServer) {
        // The service drops the server's channel list wholesale; release the thumbnail
        // state those logs were holding once the channels are gone.
        let channels = server.channels
        connectionService.disconnect(server)
        for channel in channels { discardThumbnails(for: channel.log) }
    }
    
    // MARK: - Channels
    
    func joinChannel(_ name: String, key: String? = nil, on server: IRCServer) {
        connectionService.joinChannel(name, key: key, on: server)
    }
    
    func partChannel(_ channel: IRCChannel) {
        guard let server = servers.first(where: { $0.channels.contains(where: { $0.id == channel.id }) }) else { return }
        connectionService.partChannel(channel, from: server)
        // The service removes the channel only when the PART was actually sent (it keeps the
        // channel when not connected/registered); if it's gone, drop its thumbnail state.
        if !server.channels.contains(where: { $0.id == channel.id }) {
            discardThumbnails(for: channel.log)
        }
    }
    
    func setTopic(_ topic: String, on channel: IRCChannel) {
        guard let server = servers.first(where: { $0.channels.contains(where: { $0.id == channel.id }) }) else { return }
        connectionService.sendTopicChange(topic, for: channel.name, on: server)
    }

    func requestTopic(for channel: IRCChannel) {
        guard let server = servers.first(where: { $0.channels.contains(where: { $0.id == channel.id }) }) else { return }
        connectionService.requestTopic(for: channel.name, on: server)
    }

    func closePrivateMessage(_ pm: IRCPrivateMessage, from server: IRCServer) {
        discardThumbnails(for: pm.log)
        server.privateMessages.removeAll { $0.id == pm.id }
        server.log.append(ChatMessage(time: Date(), text: "Closed conversation with \(pm.nickname)"))
        noteLogsChanged()
    }
    
    // MARK: - Messaging
    
    func handleInputFromComposer(_ text: String, selection: UUID?) {
        messageRouter.handleInputFromComposer(text, selection: selection, servers: servers, connectionService: connectionService)
    }
    
    // MARK: - Server CRUD
    
    func addServer(name: String, host: String, port: Int, password: String?, useTLS: Bool, autoConnectOnLaunch: Bool = false, nickname: String? = nil) {
        let server = IRCServer(name: name, host: host, port: port, password: password, useTLS: useTLS, autoConnectOnLaunch: autoConnectOnLaunch, nickname: nickname)
        try! syncKeychain(password: password, for: server.id)
        servers.append(server)
        selectedNodeID = server.id
    }
    
    func updateServer(id: UUID, name: String, host: String, port: Int, password: String?, useTLS: Bool, autoConnectOnLaunch: Bool, nickname: String? = nil) {
        guard let idx = servers.firstIndex(where: { $0.id == id }) else { return }
        let s = servers[idx]
        s.name = name
        s.host = host
        s.port = port
        s.password = password
        s.useTLS = useTLS
        s.autoConnectOnLaunch = autoConnectOnLaunch
        s.nickname = nickname
        try! syncKeychain(password: password, for: id)
        // Force persistence because didSet on `servers` doesn't trigger for in-place mutation
        persistServers()
    }
    
    func deleteServer(_ server: IRCServer) {
        let deletingSelected = (selectedNodeID == server.id)
        let channels = server.channels
        let pms = server.privateMessages
        connectionService.disconnect(server)
        try! keychain.delete(for: server.id)
        servers.removeAll { $0.id == server.id }
        // Every log this server owned is going away; release their thumbnail state.
        discardThumbnails(for: server.log)
        for channel in channels { discardThumbnails(for: channel.log) }
        for pm in pms { discardThumbnails(for: pm.log) }
        if deletingSelected { selectedNodeID = servers.first?.id }
    }
    
    func server(withID id: UUID?) -> IRCServer? {
        guard let id else { return nil }
        return servers.first(where: { $0.id == id })
    }

    /// Returns the server for a given selection (server ID, channel ID, or PM ID)
    func serverForSelection(_ selectionID: UUID?) -> IRCServer? {
        guard let id = selectionID else { return nil }
        // Direct server selection
        if let server = servers.first(where: { $0.id == id }) {
            return server
        }
        // Channel or PM selection - find parent server
        for server in servers {
            if server.channels.contains(where: { $0.id == id }) ||
               server.privateMessages.contains(where: { $0.id == id }) {
                return server
            }
        }
        return nil
    }

    /// Check if we can actually send messages to the given selection.
    /// This checks connection status, client state, and channel join confirmation.
    func canSendMessage(to selectionID: UUID?) -> Bool {
        guard let server = serverForSelection(selectionID) else { return false }

        // First check the observable status - this is the source of truth for UI state
        guard server.connectionStatus == .connected else { return false }

        // Then verify the server is fully registered. Uses a main-thread set in
        // IRCConnectionService instead of reading IRCClient.state (event-loop-owned).
        guard connectionService.isRegistered(server.id) else { return false }

        // If a channel is selected, only allow sending after the server confirmed our JOIN
        if let channel = server.channels.first(where: { $0.id == selectionID }) {
            return channel.joined
        }

        return true
    }

    // MARK: - Log Trimming

    /// Pure trim step (static so it can be unit-tested, like `MessageRouter.parse`): once a
    /// log grows past `cap + slack`, returns the kept tail of exactly `cap` messages plus the
    /// dropped overflow; returns nil while within bounds. The slack batches the O(n) front
    /// removal so it doesn't run on every single append once a log sits at the cap.
    static func trimOverflow(of log: [ChatMessage], cap: Int, slack: Int) -> (kept: [ChatMessage], dropped: [ChatMessage])? {
        let cap = max(1, cap)
        guard log.count > cap + max(0, slack) else { return nil }
        return (kept: Array(log.suffix(cap)), dropped: Array(log.prefix(log.count - cap)))
    }

    /// Enforces the maxLogLines preference on every log array (server, channel, PM) and
    /// releases thumbnail state for the dropped messages. Without this, logs and thumbnails
    /// grew without bound for the lifetime of the process — only the *display* was capped.
    /// Cheap when nothing overflowed (one count check per node), so it runs on every log
    /// mutation via noteLogsChanged().
    func trimLogs() {
        let cap = max(1, preferences?.maxLogLines ?? 1000)
        let slack = max(32, cap / 10)
        // Assign back only when something was dropped, so @Observable setters (and the
        // SwiftUI invalidation they trigger) fire only on real changes.
        func apply(_ log: [ChatMessage], _ assign: ([ChatMessage]) -> Void) {
            guard let t = Self.trimOverflow(of: log, cap: cap, slack: slack) else { return }
            assign(t.kept)
            discardThumbnails(for: t.dropped)
        }
        for server in servers {
            apply(server.log) { server.log = $0 }
            for channel in server.channels { apply(channel.log) { channel.log = $0 } }
            for pm in server.privateMessages { apply(pm.log) { pm.log = $0 } }
        }
    }

    /// Single funnel for "some log array was mutated": bumps the view-invalidation counter
    /// and enforces the log cap. Every append path ends up here, directly or via a delegate
    /// callback.
    private func noteLogsChanged() {
        logVersion &+= 1
        trimLogs()
    }

    /// Drops per-message thumbnail state — both the @Observable mirror driving the views and
    /// the copy inside ImageCacheService — for messages that left a log (trimmed past the cap,
    /// or removed along with their channel/PM/server).
    private func discardThumbnails(for messages: [ChatMessage]) {
        guard !messages.isEmpty else { return }
        for message in messages {
            messageThumbnails.removeValue(forKey: message.id)
        }
        imageCache.discardThumbnails(for: messages.map(\.id))
    }

    // MARK: - Persistence
    
    private let serversPersistenceKey = "PersistedServers.v1"
    
    private func persistServers() {
        let records = servers.map { $0.toRecord() }
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: serversPersistenceKey)
        }
    }

    /// Writes the password to the Keychain, or deletes the entry if password is nil/empty.
    private func syncKeychain(password: String?, for id: UUID) throws {
        if let password, !password.isEmpty {
            try keychain.save(password: password, for: id)
        } else {
            try keychain.delete(for: id)
        }
    }

    private func loadServers() {
        guard let data = UserDefaults.standard.data(forKey: serversPersistenceKey),
              let records = try? JSONDecoder().decode([IRCServerRecord].self, from: data) else {
            servers = []
            return
        }
        var migrated = false
        let loaded: [IRCServer] = records.map { record in
            let server = IRCServer(from: record)
            // Migration: legacy records carried a plaintext password. Move it to the Keychain.
            if let legacy = record.password, !legacy.isEmpty {
                try! keychain.save(password: legacy, for: record.id)
                migrated = true
            }
            // Load the (possibly just-migrated) password from the Keychain into memory.
            server.password = try! keychain.password(for: record.id)
            return server
        }
        servers = loaded
        // After a migration, make sure the legacy plaintext password is dropped from UserDefaults.
        // Assigning `servers` already triggers didSet -> persistServers() (and encode(to:) omits the
        // password), so this is belt-and-suspenders that also states the migration intent explicitly.
        if migrated { persistServers() }
    }
    
    private func autoConnectFlaggedServers() {
        for s in servers where s.autoConnectOnLaunch {
            connect(s)
        }
    }
    
    // MARK: - IRCConnectionServiceDelegate
    
    func ircConnectionService(_ service: IRCConnectionService, didAppendMessage message: ChatMessage, to server: IRCServer) {
        noteLogsChanged()
        if message.isPrivmsg {
            scanMessageForThumbnails(message)
        }
    }

    func ircConnectionServiceNetworkDidBecomeAvailable(_ service: IRCConnectionService) {
        // Reconnect all servers that should auto-reconnect and are currently disconnected
        for server in servers {
            let isDisconnected = server.connectionStatus == .disconnected ||
                                 server.connectionStatus == .connectionTimeout ||
                                 server.connectionStatus == .reconnectionFailed
            if server.shouldAutoReconnect && isDisconnected {
                server.log.append(ChatMessage(time: Date(), text: "Network available, reconnecting..."))
                noteLogsChanged()
                connectionService.resetReconnectionAttempts(for: server)
                connect(server)
            }
        }
    }

    // MARK: - MessageRouterDelegate

    func messageRouter(_ router: MessageRouter, didAppendMessage message: ChatMessage) {
        noteLogsChanged()
        scanMessageForThumbnails(message)
    }
    
    func ircConnectionService(_ service: IRCConnectionService, serverDidDisconnect serverID: UUID) {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }

        connectionService.cancelConnectionTimeout(for: server)

        server.connectionStatus = .connectionTimeout
        server.log.append(ChatMessage(time: Date(), text: "Connection to \(server.name) lost"))
        noteLogsChanged()

        if server.shouldAutoReconnect {
            connectionService.scheduleReconnection(for: server)
        }
    }
    
    func ircConnectionService(_ service: IRCConnectionService, serverDidRegister serverID: UUID, as nick: String) {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }

        connectionService.cancelConnectionTimeout(for: server)
        server.currentNick = nick

        let statusText = server.displayAttempt > 0 ?
            "Reconnected as \(nick)" :
            "Registered as \(nick)"
        let message = ChatMessage(time: Date(), text: statusText)
        server.log.append(message)
        noteLogsChanged()
        scanMessageForThumbnails(message)

        connectionService.resetReconnectionAttempts(for: server)
        server.shouldAutoReconnect = true

        for channel in server.channels {
            connectionService.joinChannel(channel.name, on: server)
        }

        connectionService.startPingMonitoring(for: server)
    }
    
    func ircConnectionService(_ service: IRCConnectionService, serverFailedToRegister serverID: UUID) {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }

        connectionService.cancelConnectionTimeout(for: server)

        let message = ChatMessage(time: Date(), text: "Failed to register with server")
        server.log.append(message)
        noteLogsChanged()
        scanMessageForThumbnails(message)

        if server.shouldAutoReconnect {
            connectionService.scheduleReconnection(for: server)
        }
    }

    func ircConnectionService(_ service: IRCConnectionService, server serverID: UUID, connectionStateChanged state: IRCClient.ConnectionState) {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }

        // Map IRCClient.ConnectionState to IRCServer.ConnectionStatus
        switch state {
        case .disconnected:
            // Only update if we think we're connected or connecting.
            // If we're already in a disconnect-related state (reconnecting, timeout, failed),
            // a more specific callback will handle setting the appropriate status.
            if server.connectionStatus == .connected || server.connectionStatus == .connecting {
                server.connectionStatus = .disconnected
            }
        case .connecting:
            // Only set to connecting if not already in a reconnecting state
            if server.connectionStatus != .reconnecting {
                server.connectionStatus = .connecting
            }
        case .connected:
            server.connectionStatus = .connected
        }
    }

    func ircConnectionService(_ service: IRCConnectionService, serverDidChangeNick serverID: UUID, to nick: String) {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }

        server.currentNick = nick
        let message = ChatMessage(time: Date(), text: "You are now known as \(nick)")
        server.log.append(message)
        noteLogsChanged()
        scanMessageForThumbnails(message)
    }
    
    func ircConnectionService(_ service: IRCConnectionService, didReceiveMessage message: ChatMessage, for serverID: UUID, target: MessageTargetType) {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }

        switch target {
        case .server:
            server.log.append(message)

        case .channel(let name, let isMine):
            let channel = server.getOrCreateChannel(named: name)

            // Drop an immediate server echo of a line we just echoed locally (servers with
            // znc.in/self-message echo our own PRIVMSGs back). Heuristic: same sender+text as
            // the last entry within 1s. Buffer playback on reconnect arrives in a burst with no
            // matching just-appended local line, so it is not affected.
            let isDuplicate = channel.log.last?.senderNick == message.senderNick &&
                            channel.log.last?.text == message.text &&
                            Date().timeIntervalSince(channel.log.last?.time ?? Date.distantPast) < 1.0
            if !isDuplicate {
                channel.log.append(message)
                scanMessageForThumbnails(message)
            }

            if !isMine, selectedNodeID != channel.id {
                channel.unreadCount += 1
            }

        case .privateMessage(let senderNick):
            let pm = server.getOrCreatePrivateMessage(with: senderNick)
            pm.log.append(message)
            scanMessageForThumbnails(message)

            if selectedNodeID != pm.id {
                pm.unreadCount += 1
            }
        }
        noteLogsChanged()
    }
    
    func ircConnectionService(_ service: IRCConnectionService, user nick: String, joinedChannel channel: String, on serverID: UUID, isSelf: Bool) {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }

        let channelObj = server.getOrCreateChannel(named: channel)
        channelObj.addUserIfNotPresent(nick)

        if isSelf {
            channelObj.joined = true
            let message = ChatMessage(time: Date(), text: "Joined \(channel)")
            channelObj.log.append(message)
            server.log.append(message)
            noteLogsChanged()
        }
    }

    func ircConnectionService(_ service: IRCConnectionService, user nick: String, leftChannel channel: String, on serverID: UUID, isSelf: Bool) {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }

        if isSelf {
            if let channelObj = server.channels.first(where: { $0.name.caseInsensitiveCompare(channel) == .orderedSame }) {
                let message = ChatMessage(time: Date(), text: "Parted \(channel)")
                channelObj.log.append(message)
                channelObj.joined = false
                // Channel is removed below; release the thumbnail state its log was holding.
                discardThumbnails(for: channelObj.log)
            }
            server.channels.removeAll { $0.name.caseInsensitiveCompare(channel) == .orderedSame }
            let message = ChatMessage(time: Date(), text: "Parted \(channel)")
            server.log.append(message)
            noteLogsChanged()
        } else if let channelObj = server.channels.first(where: { $0.name.caseInsensitiveCompare(channel) == .orderedSame }) {
            channelObj.removeUser(nick)
        }
    }
    
    func ircConnectionService(_ service: IRCConnectionService, didReceiveUserList users: [String], for channel: String, on serverID: UUID) {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }
        guard let channelObj = server.channels.first(where: { $0.name.lowercased() == channel.lowercased() }) else { return }

        // Add each user if not already present (using case-insensitive check)
        for nick in users where !nick.isEmpty {
            channelObj.addUserIfNotPresent(nick)
        }
    }
    
    func ircConnectionService(_ service: IRCConnectionService, didReceiveWhoReply nick: String, for channel: String, on serverID: UUID) {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }
        guard let channelObj = server.channels.first(where: { $0.name.lowercased() == channel.lowercased() }) else { return }

        channelObj.addUserIfNotPresent(nick)
    }

    func ircConnectionService(_ service: IRCConnectionService, didReceiveTopicChange topic: String, for channel: String, on serverID: UUID, changedBy nick: String?) {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }
        guard let channelObj = server.channels.first(where: { $0.name.caseInsensitiveCompare(channel) == .orderedSame }) else { return }

        channelObj.topic = topic.isEmpty ? nil : topic

        let logText: String
        if let nick {
            logText = "\(nick) changed the topic to: \(topic)"
        } else {
            logText = "Topic: \(topic)"
        }
        let message = ChatMessage(time: Date(), text: logText)
        channelObj.log.append(message)
        noteLogsChanged()
    }

    func ircConnectionService(_ service: IRCConnectionService, user oldNick: String, changedNickTo newNick: String, on serverID: UUID) {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }

        let nickMessage = ChatMessage(time: Date(), text: "\(oldNick) is now known as \(newNick)")

        // Update nick in channels and log where the user is present
        for channel in server.channels {
            if channel.hasUser(oldNick) {
                channel.updateUserNick(from: oldNick, to: newNick)
                channel.log.append(nickMessage)
            }
        }

        // Update nick in PM conversations so messages go to the right target
        if let pm = server.privateMessages.first(where: { $0.nickname.caseInsensitiveCompare(oldNick) == .orderedSame }) {
            pm.nickname = newNick
            pm.log.append(nickMessage)
        }

        server.log.append(nickMessage)
        noteLogsChanged()
    }

    func ircConnectionService(_ service: IRCConnectionService, userQuit nick: String, on serverID: UUID, message: String?) {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }

        let quitText = message.map { " (\($0))" } ?? ""
        let logMessage = ChatMessage(time: Date(), text: "\(nick) has quit\(quitText)")

        for channel in server.channels {
            channel.removeUser(nick)
        }

        // Log quit in PM conversation so the user knows their DM partner left
        if let pm = server.privateMessages.first(where: { $0.nickname.caseInsensitiveCompare(nick) == .orderedSame }) {
            pm.log.append(logMessage)
        }

        server.log.append(logMessage)
        noteLogsChanged()
    }
}