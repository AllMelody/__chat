import Foundation
import Observation

@Observable
final class ChatStore: IRCConnectionServiceDelegate, MessageRouterDelegate {
    // Services
    private let connectionService = IRCConnectionService()
    private let imageCache = ImageCacheService()
    private let messageRouter = MessageRouter()
    
    // Core data
    var servers: [IRCServer] = [] { didSet { persistServers() } }
    
    // Selection (server or channel id)
    var selectedNodeID: UUID? = nil
    
    // UI state
    var isPresentingAddServer: Bool = false
    var isPresentingEditServer: Bool = false
    var isPresentingJoinChannel: Bool = false
    var pendingJoinServerID: UUID? = nil
    var pendingEditServerID: UUID? = nil
    var joinChannelDraft: String = ""
    
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
    }
    
    // MARK: - Thumbnails
    
    var messageThumbnails: [UUID: [MessageThumbnail]] {
        imageCache.messageThumbnails
    }
    
    func scanMessageForThumbnails(_ message: ChatMessage) {
        imageCache.scanMessageForThumbnails(message, showImageThumbnails: preferences?.showImageThumbnails ?? false)
    }
    
    // MARK: - Connection Management
    
    func connect(_ server: IRCServer) {
        connectionService.connect(server)
    }
    
    func disconnect(_ server: IRCServer) {
        connectionService.disconnect(server)
    }
    
    // MARK: - Channels
    
    func joinChannel(_ name: String, key: String? = nil, on server: IRCServer) {
        connectionService.joinChannel(name, key: key, on: server)
    }
    
    func partChannel(_ channel: IRCChannel) {
        guard let server = servers.first(where: { $0.channels.contains(where: { $0.id == channel.id }) }) else { return }
        connectionService.partChannel(channel, from: server)
    }
    
    func closePrivateMessage(_ pm: IRCPrivateMessage, from server: IRCServer) {
        server.privateMessages.removeAll { $0.id == pm.id }
        server.log.append(ChatMessage(time: Date(), text: "Closed conversation with \(pm.nickname)"))
    }
    
    // MARK: - Messaging
    
    func handleInputFromComposer(_ text: String, selection: UUID?) {
        messageRouter.handleInputFromComposer(text, selection: selection, servers: servers, connectionService: connectionService)
    }
    
    // MARK: - Server CRUD
    
    func addServer(name: String, host: String, port: Int, password: String?, useTLS: Bool, autoConnectOnLaunch: Bool = false) {
        let server = IRCServer(name: name, host: host, port: port, password: password, useTLS: useTLS, autoConnectOnLaunch: autoConnectOnLaunch)
        servers.append(server)
        selectedNodeID = server.id
    }
    
    func updateServer(id: UUID, name: String, host: String, port: Int, password: String?, useTLS: Bool, autoConnectOnLaunch: Bool) {
        guard let idx = servers.firstIndex(where: { $0.id == id }) else { return }
        let s = servers[idx]
        s.name = name
        s.host = host
        s.port = port
        s.password = password
        s.useTLS = useTLS
        s.autoConnectOnLaunch = autoConnectOnLaunch
        // Force persistence because didSet on `servers` doesn't trigger for in-place mutation
        persistServers()
    }
    
    func deleteServer(_ server: IRCServer) {
        let deletingSelected = (selectedNodeID == server.id)
        connectionService.disconnect(server)
        servers.removeAll { $0.id == server.id }
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

    /// Check if we can actually send messages to the given selection
    /// This checks the real connection state, not just the UI status
    func canSendMessage(to selectionID: UUID?) -> Bool {
        guard let server = serverForSelection(selectionID) else { return false }
        guard let client = connectionService.clients[server.id] else { return false }
        return client.canSend
    }
    
    // MARK: - Persistence
    
    private let serversPersistenceKey = "PersistedServers.v1"
    
    private func persistServers() {
        let records = servers.map { $0.toRecord() }
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: serversPersistenceKey)
        }
    }
    
    private func loadServers() {
        guard let data = UserDefaults.standard.data(forKey: serversPersistenceKey),
              let records = try? JSONDecoder().decode([IRCServerRecord].self, from: data) else {
            servers = []
            return
        }
        servers = records.map { IRCServer(from: $0) }
    }
    
    private func autoConnectFlaggedServers() {
        for s in servers where s.autoConnectOnLaunch {
            connect(s)
        }
    }
    
    // MARK: - IRCConnectionServiceDelegate
    
    func ircConnectionService(_ service: IRCConnectionService, didAppendMessage message: ChatMessage, to server: IRCServer) {
        // Only scan for thumbnails if this is an actual chat message (not server status messages)
        // Server status messages create noise from IRC hostmasks being detected as URLs
        if message.isPrivmsg {
            scanMessageForThumbnails(message)
        }
    }
    
    // MARK: - MessageRouterDelegate
    
    func messageRouter(_ router: MessageRouter, didAppendMessage message: ChatMessage) {
        scanMessageForThumbnails(message)
    }
    
    func ircConnectionService(_ service: IRCConnectionService, serverDidDisconnect serverID: UUID) {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }
        
        connectionService.cancelConnectionTimeout(for: server)
        
        // Always update state on disconnect - the delegate is only called for unexpected disconnects
        // Manual disconnects go through IRCConnectionService.disconnect() which sets state directly
        server.connectionStatus = .connectionTimeout
        server.log.append(ChatMessage(time: Date(), text: "Connection to \(server.name) lost"))

        // Attempt reconnection if enabled
        if server.shouldAutoReconnect {
            connectionService.scheduleReconnection(for: server)
        }
    }
    
    func ircConnectionService(_ service: IRCConnectionService, serverDidRegister serverID: UUID, as nick: String) {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }

        // Cancel timeout timer since we successfully connected
        connectionService.cancelConnectionTimeout(for: server)

        // Note: connectionStatus is now updated via connectionStateChanged callback
        server.currentNick = nick
        
        let statusText = server.reconnectionAttempts > 0 ? 
            "Reconnected as \(nick)" : 
            "Registered as \(nick)"
        let message = ChatMessage(time: Date(), text: statusText)
        server.log.append(message)
        scanMessageForThumbnails(message)
        
        connectionService.resetReconnectionAttempts(for: server)  // Reset reconnection counter on successful connection
        server.shouldAutoReconnect = true // Re-enable auto-reconnect for future disconnections

        // Start ping monitoring for this connection
        connectionService.startPingMonitoring(for: server)
    }
    
    func ircConnectionService(_ service: IRCConnectionService, serverFailedToRegister serverID: UUID) {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }

        connectionService.cancelConnectionTimeout(for: server)

        // Note: connectionStatus is now updated via connectionStateChanged callback
        let message = ChatMessage(time: Date(), text: "Failed to register with server")
        server.log.append(message)
        scanMessageForThumbnails(message)

        // Attempt reconnection if enabled
        if server.shouldAutoReconnect {
            connectionService.scheduleReconnection(for: server)
        }
    }

    func ircConnectionService(_ service: IRCConnectionService, server serverID: UUID, connectionStateChanged state: IRCClient.ConnectionState) {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }

        // Map IRCClient.ConnectionState to IRCServer.ConnectionStatus
        // Note: We only handle .connecting and .connected here.
        // Disconnect scenarios are handled by specific callbacks (serverDidDisconnect,
        // serverFailedToRegister) which set more specific statuses like .connectionTimeout
        switch state {
        case .disconnected:
            // Don't set status here - let specific disconnect callbacks handle it
            // They provide more context (timeout vs clean disconnect vs reconnecting)
            break
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
        scanMessageForThumbnails(message)
    }
    
    func ircConnectionService(_ service: IRCConnectionService, didReceiveMessage message: ChatMessage, for serverID: UUID, target: MessageTargetType) {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }
        
        switch target {
        case .server:
            server.log.append(message)
            // Don't scan server log for thumbnails - creates noise from IRC server hostmasks

        case .channel(let name, let isMine):
            let channel = server.getOrCreateChannel(named: name)
            
            // Improved duplicate detection
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
            // Find or create private message conversation
            let pm = server.getOrCreatePrivateMessage(with: senderNick)
            
            // Add the message
            pm.log.append(message)
            scanMessageForThumbnails(message)
            
            // Mark as unread if not currently selected
            if selectedNodeID != pm.id {
                pm.unreadCount += 1
            }
        }
    }
    
    func ircConnectionService(_ service: IRCConnectionService, user nick: String, joinedChannel channel: String, on serverID: UUID, isSelf: Bool) {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }

        let channelObj = server.getOrCreateChannel(named: channel)
        channelObj.addUserIfNotPresent(nick)

        if isSelf {
            let message = ChatMessage(time: Date(), text: "Joined \(channel)")
            server.log.append(message)
            scanMessageForThumbnails(message)
        }
    }
    
    func ircConnectionService(_ service: IRCConnectionService, user nick: String, leftChannel channel: String, on serverID: UUID, isSelf: Bool) {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }

        if isSelf {
            server.channels.removeAll { $0.name == channel }
            let message = ChatMessage(time: Date(), text: "Parted \(channel)")
            server.log.append(message)
            scanMessageForThumbnails(message)
        } else if let channelObj = server.channels.first(where: { $0.name == channel }) {
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

    func ircConnectionService(_ service: IRCConnectionService, user oldNick: String, changedNickTo newNick: String, on serverID: UUID) {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }

        // Update the nick in ALL channels on this server
        for channel in server.channels {
            channel.updateUserNick(from: oldNick, to: newNick)
        }

        // Log the nick change to the server log
        let message = ChatMessage(time: Date(), text: "\(oldNick) is now known as \(newNick)")
        server.log.append(message)
        scanMessageForThumbnails(message)
    }

    func ircConnectionService(_ service: IRCConnectionService, userQuit nick: String, on serverID: UUID, message: String?) {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }

        // Remove the user from ALL channels on this server (QUIT = left the entire server)
        for channel in server.channels {
            channel.removeUser(nick)
        }

        // Log the quit to the server log
        let quitText = message.map { " (\($0))" } ?? ""
        let logMessage = ChatMessage(time: Date(), text: "\(nick) has quit\(quitText)")
        server.log.append(logMessage)
        scanMessageForThumbnails(logMessage)
    }
}