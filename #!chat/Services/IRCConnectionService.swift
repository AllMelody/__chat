import Foundation
import NIO
import Network

final class IRCConnectionService: IRCClientDelegate, ReconnectionManagerDelegate {
    // Clients and connection state
    var clients: [UUID: IRCClient] = [:]
    var connectionTimers: [UUID: Timer] = [:]
    var pingTasks: [UUID: RepeatedTask] = [:]
    var lastPongReceived: [UUID: Date] = [:]
    private var selfNicks: [UUID: String] = [:]

    // Reconnection handling
    private let reconnectionManager = ReconnectionManager()

    // Network monitoring for immediate disconnect detection
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "io.github.AllMelody.__chat")

    // Default nick
    var defaultNick: String = "Guest\(Int.random(in: 1000...9999))"

    // Delegate for server updates
    weak var delegate: IRCConnectionServiceDelegate?

    // Server lookup for reconnection callbacks
    private var serverLookup: ((UUID) -> IRCServer?)?

    /// Configure the server lookup closure. Must be called before reconnection can work.
    func configureServerLookup(_ lookup: @escaping (UUID) -> IRCServer?) {
        self.serverLookup = lookup
    }

    init() {
        setupNetworkMonitoring()
        reconnectionManager.delegate = self
    }

    deinit {
        pathMonitor.cancel()
        // Clean up all timers
        for timer in connectionTimers.values {
            timer.invalidate()
        }
        // Cancel all ping tasks
        for task in pingTasks.values {
            task.cancel()
        }
        // Reconnection manager cleans up in its own deinit
    }

    // MARK: - Network Monitoring

    private func setupNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            if path.status == .unsatisfied || path.status == .requiresConnection {
                // Network is down - immediately disconnect all servers
                DispatchQueue.main.async {
                    self.handleNetworkLoss()
                }
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    private func handleNetworkLoss() {
        // Get all connected server IDs (copy to avoid mutation during iteration)
        let connectedServerIDs = Array(clients.keys)

        for serverID in connectedServerIDs {
            // Update server state IMMEDIATELY before cleanup.
            // This prevents race conditions where UI thinks we're still connected.
            if let server = serverLookup?(serverID) {
                if server.connectionStatus == .connected || server.connectionStatus == .connecting {
                    server.connectionStatus = .disconnected
                }
            }

            // Close the client and notify delegate
            if let client = clients.removeValue(forKey: serverID) {
                client.close()
            }

            // Notify delegate - this will trigger reconnection logic in ChatStore
            delegate?.ircConnectionService(self, serverDidDisconnect: serverID)
        }
    }

    // MARK: - Connection Management
    
    func connect(_ server: IRCServer) {
        guard server.connectionStatus != .connecting && server.connectionStatus != .connected else { return }
        
        server.connectionStatus = .connecting
        server.lastConnectionAttempt = Date()
        
        let statusText = server.reconnectionAttempts > 0 ? 
            "Reconnecting to \(server.name) (attempt \(server.reconnectionAttempts + 1)/\(server.maxReconnectionAttempts))" :
            "Connecting to \(server.name) (\(server.host):\(server.port))"
        let msg = ChatMessage(time: Date(), text: statusText)
        server.log.append(msg)
        delegate?.ircConnectionService(self, didAppendMessage: msg, to: server)

        let nick = IRCNickName(defaultNick) ?? IRCNickName("Guest")!
        let opts = IRCClientOptions(
            port: server.port,
            host: server.host,
            password: server.password,
            nickname: nick,
            userInfo: nil,
            eventLoopGroup: nil
        )
        opts.useTLS = server.useTLS
        let client = IRCClient(options: opts)
        client.delegate = self
        clients[server.id] = client
        
        // Set up connection timeout
        setupConnectionTimeout(for: server)
        
        client.connect()
    }

    func disconnect(_ server: IRCServer) {
        let msg = ChatMessage(time: Date(), text: "Disconnecting from \(server.name)…")
        server.log.append(msg)
        delegate?.ircConnectionService(self, didAppendMessage: msg, to: server)
        
        // Cancel any timers
        cancelConnectionTimeout(for: server)
        cancelReconnectionTimer(for: server)
        stopPingMonitoring(for: server)
        
        if let c = clients.removeValue(forKey: server.id) { c.close() }
        selfNicks.removeValue(forKey: server.id)
        server.channels.removeAll()
        server.connectionStatus = .disconnected
        server.reconnectionAttempts = 0
        server.shouldAutoReconnect = false
        
        let done = ChatMessage(time: Date(), text: "Disconnected from \(server.name)")
        server.log.append(done)
        delegate?.ircConnectionService(self, didAppendMessage: done, to: server)
    }
    
    private func setupConnectionTimeout(for server: IRCServer) {
        cancelConnectionTimeout(for: server)
        
        let timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleConnectionTimeout(for: server)
            }
        }
        connectionTimers[server.id] = timer
    }
    
    func cancelConnectionTimeout(for server: IRCServer) {
        connectionTimers[server.id]?.invalidate()
        connectionTimers.removeValue(forKey: server.id)
    }
    
    private func handleConnectionTimeout(for server: IRCServer) {
        // Allow timeout handling if we're still trying to connect OR if we just
        // received a disconnect during the connection attempt. Prevents skipping
        // cleanup when connectionStateChanged(.disconnected) fires before timeout.
        let validStates: [IRCServer.ConnectionStatus] = [.connecting, .disconnected]
        guard validStates.contains(server.connectionStatus) else { return }

        // Only log timeout message if we were still connecting (not already disconnected)
        if server.connectionStatus == .connecting {
            let msg = ChatMessage(time: Date(), text: "Connection to \(server.name) timed out")
            server.log.append(msg)
            delegate?.ircConnectionService(self, didAppendMessage: msg, to: server)
        }

        server.connectionStatus = .connectionTimeout

        // Close the client connection if it exists
        if let client = clients.removeValue(forKey: server.id) {
            client.close()
        }

        // Attempt reconnection if enabled
        if server.shouldAutoReconnect {
            scheduleReconnection(for: server)
        }
    }
    
    func scheduleReconnection(for server: IRCServer) {
        let policy = ReconnectionManager.Policy(
            maxAttempts: server.maxReconnectionAttempts,
            baseDelay: server.reconnectionDelay,
            maxDelay: 60.0,
            backoffMultiplier: 2.0
        )
        reconnectionManager.scheduleReconnection(for: server.id, policy: policy)
    }

    func cancelReconnectionTimer(for server: IRCServer) {
        reconnectionManager.cancelReconnection(for: server.id)
    }

    func resetReconnectionAttempts(for server: IRCServer) {
        reconnectionManager.resetAttempts(for: server.id)
        server.reconnectionAttempts = 0
    }

    // MARK: - ReconnectionManagerDelegate

    func reconnectionManager(_ manager: ReconnectionManager, shouldReconnect serverID: UUID) {
        guard let server = serverLookup?(serverID) else { return }
        connect(server)
    }

    func reconnectionManager(_ manager: ReconnectionManager, didScheduleReconnect serverID: UUID, attempt: Int, delay: TimeInterval) {
        guard let server = serverLookup?(serverID) else { return }

        server.connectionStatus = .reconnecting
        server.reconnectionAttempts = attempt

        let msg = ChatMessage(time: Date(), text: "Reconnecting to \(server.name) in \(Int(delay)) seconds... (attempt \(attempt)/\(server.maxReconnectionAttempts))")
        server.log.append(msg)
        delegate?.ircConnectionService(self, didAppendMessage: msg, to: server)
    }

    func reconnectionManager(_ manager: ReconnectionManager, didExhaustAttempts serverID: UUID, maxAttempts: Int) {
        guard let server = serverLookup?(serverID) else { return }

        server.connectionStatus = .reconnectionFailed
        server.shouldAutoReconnect = false

        let msg = ChatMessage(time: Date(), text: "Failed to reconnect to \(server.name) after \(maxAttempts) attempts")
        server.log.append(msg)
        delegate?.ircConnectionService(self, didAppendMessage: msg, to: server)
    }
    
    func startPingMonitoring(for server: IRCServer) {
        stopPingMonitoring(for: server)
        lastPongReceived[server.id] = Date()

        guard let client = clients[server.id] else { return }

        // Use EventLoop.scheduleRepeatedTask for better integration with NIO
        let task = client.eventLoop.scheduleRepeatedTask(initialDelay: .seconds(60), delay: .seconds(60)) { [weak self] _ in
            DispatchQueue.main.async {
                self?.checkConnectionHealth(for: server)
            }
        }
        pingTasks[server.id] = task
    }

    func stopPingMonitoring(for server: IRCServer) {
        pingTasks[server.id]?.cancel()
        pingTasks.removeValue(forKey: server.id)
        lastPongReceived.removeValue(forKey: server.id)
    }
    
    private func checkConnectionHealth(for server: IRCServer) {
        guard server.connectionStatus == .connected,
              let client = clients[server.id] else { return }
        
        let now = Date()
        if let lastPong = lastPongReceived[server.id],
           now.timeIntervalSince(lastPong) > 120 {
            handleConnectionDead(for: server)
            return
        }
        
        client.send(.otherCommand("PING", ["\(now.timeIntervalSince1970)"]))
    }
    
    private func handleConnectionDead(for server: IRCServer) {
        // Idempotency guard - prevent duplicate handling
        guard server.connectionStatus == .connected || server.connectionStatus == .connecting else { return }

        server.connectionStatus = .connectionTimeout

        let msg = ChatMessage(time: Date(), text: "Connection to \(server.name) lost")
        server.log.append(msg)
        delegate?.ircConnectionService(self, didAppendMessage: msg, to: server)
        
        if let client = clients.removeValue(forKey: server.id) {
            client.close()
        }
        
        stopPingMonitoring(for: server)
        
        if server.shouldAutoReconnect {
            scheduleReconnection(for: server)
        }
    }
    
    func updateLastPongReceived(for serverID: UUID) {
        lastPongReceived[serverID] = Date()
    }
    
    // MARK: - Channel Operations
    
    func joinChannel(_ name: String, key: String? = nil, on server: IRCServer) {
        guard let client = clients[server.id] else {
            handleSendFailure(for: server, reason: "Cannot join channel: Not connected")
            return
        }

        guard client.canSend else {
            handleSendFailure(for: server, reason: "Cannot join channel: Not registered")
            handleConnectionDead(for: server)
            return
        }

        if let ch = IRCChannelName(name) {
            if let key { client.send(.JOIN(channels: [ ch ], keys: [ key ])) }
            else { client.send(.JOIN(channels: [ ch ], keys: nil)) }
        } else {
            if let key { client.send(.otherCommand("JOIN", [ name, key ])) }
            else { client.send(.otherCommand("JOIN", [ name ])) }
        }

        _ = server.getOrCreateChannel(named: name)
    }

    func partChannel(_ channel: IRCChannel, from server: IRCServer) {
        guard let client = clients[server.id] else {
            handleSendFailure(for: server, reason: "Cannot part channel: Not connected")
            return
        }

        guard client.canSend else {
            handleSendFailure(for: server, reason: "Cannot part channel: Not registered")
            handleConnectionDead(for: server)
            return
        }

        if let ch = IRCChannelName(channel.name) {
            client.send(.PART(channels: [ ch ], message: nil))
        } else {
            client.send(.otherCommand("PART", [ channel.name ]))
        }

        server.channels.removeAll { $0.id == channel.id }
        server.log.append(ChatMessage(time: Date(), text: "Parted \(channel.name)"))
    }
    
    // MARK: - Messaging

    /// Send a message to an arbitrary nick or channel (used by /msg command)
    /// Creates a PM conversation if needed
    func sendMessageToTarget(_ text: String, targetName: String, from server: IRCServer) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let client = clients[server.id] else {
            let msg = ChatMessage(time: Date(), text: "⚠️ Failed to send message: Not connected")
            server.log.append(msg)
            delegate?.ircConnectionService(self, didAppendMessage: msg, to: server)
            return
        }

        guard client.canSend else {
            let msg = ChatMessage(time: Date(), text: "⚠️ Failed to send message: Not registered")
            server.log.append(msg)
            delegate?.ircConnectionService(self, didAppendMessage: msg, to: server)
            handleConnectionDead(for: server)
            return
        }

        if targetName.hasPrefix("#") {
            // Channel message - find or create channel
            let channel = server.getOrCreateChannel(named: targetName)
            sendMessage(trimmed, to: .channel(channel), from: server)
        } else {
            // Private message - find or create PM conversation
            let pm = server.getOrCreatePrivateMessage(with: targetName)
            sendMessage(trimmed, to: .privateMessage(pm), from: server)
        }
    }

    func sendMessage(_ text: String, to target: MessageTarget, from server: IRCServer) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let client = clients[server.id] else {
            handleSendFailure(for: server, target: target, reason: "Not connected")
            return
        }

        // Check if client is registered and can send
        guard client.canSend else {
            handleSendFailure(for: server, target: target, reason: "Not registered")
            handleConnectionDead(for: server)
            return
        }

        switch target {
        case .channel(let channel):
            let nick = server.currentNick ?? defaultNick
            let msg = ChatMessage(time: Date(), text: trimmed, senderNick: nick, isPrivmsg: true, isFromMe: true)
            channel.log.append(msg)
            delegate?.ircConnectionService(self, didAppendMessage: msg, to: server)

            if let chName = IRCChannelName(channel.name) {
                sendWithFailureDetection(.PRIVMSG([ .channel(chName) ], trimmed), to: client, server: server)
            } else {
                sendWithFailureDetection(.otherCommand("PRIVMSG", [ channel.name, trimmed ]), to: client, server: server)
            }

        case .privateMessage(let pm):
            let nick = server.currentNick ?? defaultNick
            let msg = ChatMessage(time: Date(), text: trimmed, senderNick: nick, isPrivmsg: true, isFromMe: true)
            pm.log.append(msg)
            delegate?.ircConnectionService(self, didAppendMessage: msg, to: server)

            sendWithFailureDetection(.otherCommand("PRIVMSG", [ pm.nickname, trimmed ]), to: client, server: server)

        case .server:
            let msg = ChatMessage(time: Date(), text: trimmed)
            server.log.append(msg)
            delegate?.ircConnectionService(self, didAppendMessage: msg, to: server)
        }
    }

    private func sendWithFailureDetection(_ command: IRCCommand, to client: IRCClient, server: IRCServer) {
        let message = IRCMessage(command: command)
        let promise = client.eventLoop.makePromise(of: Void.self)

        promise.futureResult.whenFailure { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                print("⚠️ Write failed for server \(server.name): \(error)")
                self.handleSendFailure(for: server, reason: "Write failed: \(error.localizedDescription)")
                self.handleConnectionDead(for: server)
            }
        }

        client.sendMessages([message], promise: promise)
    }

    private func handleSendFailure(for server: IRCServer, target: MessageTarget? = nil, reason: String) {
        let msg = ChatMessage(time: Date(), text: "⚠️ Failed to send message: \(reason)")

        // Log to the appropriate target so the user sees the error where they're looking
        switch target {
        case .channel(let channel):
            channel.log.append(msg)
        case .privateMessage(let pm):
            pm.log.append(msg)
        case .server, .none:
            server.log.append(msg)
        }

        delegate?.ircConnectionService(self, didAppendMessage: msg, to: server)
    }
    
    // MARK: - Helper Methods
    
    private func serverID(for client: IRCClient) -> UUID? {
        return clients.first { $0.value === client }?.key
    }
    
    private func formatIRCMessage(_ message: IRCMessage, direction: String) -> String {
        switch message.command {
        case .numeric(let code, let args):
            let argsText = args.joined(separator: " ")
            return "\(direction): \(code.rawValue) \(argsText)"
        case .PRIVMSG(let recipients, let text):
            let targets = recipients.map { $0.description }.joined(separator: ",")
            let sender = message.origin?.description ?? "server"
            return "\(direction): \(sender) PRIVMSG \(targets) :\(text)"
        case .NOTICE(let recipients, let text):
            let targets = recipients.map { $0.description }.joined(separator: ",")
            let sender = message.origin?.description ?? "server"
            return "\(direction): \(sender) NOTICE \(targets) :\(text)"
        case .JOIN(channels: let channels, keys: _):
            let channelNames = channels.map { $0.stringValue }.joined(separator: ",")
            let sender = message.origin?.description ?? "server"
            return "\(direction): \(sender) JOIN \(channelNames)"
        case .PART(channels: let channels, message: let partMessage):
            let channelNames = channels.map { $0.stringValue }.joined(separator: ",")
            let sender = message.origin?.description ?? "server"
            let reasonText = partMessage.map { " :\($0)" } ?? ""
            return "\(direction): \(sender) PART \(channelNames)\(reasonText)"
        case .QUIT(let reason):
            let sender = message.origin?.description ?? "server"
            let reasonText = reason.map { " :\($0)" } ?? ""
            return "\(direction): \(sender) QUIT\(reasonText)"
        case .NICK(let nick):
            let sender = message.origin?.description ?? "server"
            return "\(direction): \(sender) NICK \(nick.stringValue)"
        case .MODE(let target, add: let add, remove: let remove):
            let sender = message.origin?.description ?? "server"
            return "\(direction): \(sender) MODE \(target.stringValue) +\(add) -\(remove)"
        case .otherCommand(let command, let args):
            let argsText = args.joined(separator: " ")
            let sender = message.origin?.description ?? "server"
            return "\(direction): \(sender) \(command) \(argsText)"
        default:
            return "\(direction): \(message.command)"
        }
    }
    
    // MARK: - IRCClientDelegate Implementation
    
    func clientDidDisconnect(_ client: IRCClient) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let serverID = self.serverID(for: client) else { return }

            // Update server state IMMEDIATELY before any cleanup.
            // This prevents race conditions where canSendMessage() might check
            // state between the async dispatch and cleanup completion.
            if let server = self.serverLookup?(serverID) {
                // Only update if we think we're still connected/connecting.
                // If already in a disconnect-related state, don't overwrite it.
                if server.connectionStatus == .connected || server.connectionStatus == .connecting {
                    server.connectionStatus = .disconnected
                }
            }

            // Clean up all monitoring and timers for this server
            self.pingTasks[serverID]?.cancel()
            self.pingTasks.removeValue(forKey: serverID)
            self.lastPongReceived.removeValue(forKey: serverID)
            self.connectionTimers[serverID]?.invalidate()
            self.connectionTimers.removeValue(forKey: serverID)
            self.reconnectionManager.cancelReconnection(for: serverID)

            // Remove client reference
            self.clients.removeValue(forKey: serverID)
            self.selfNicks.removeValue(forKey: serverID)

            // Notify delegate so it can trigger reconnection if needed
            self.delegate?.ircConnectionService(self, serverDidDisconnect: serverID)
        }
    }

    func client(_ client: IRCClient, registered nick: IRCNickName, with userInfo: IRCUserInfo) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let serverID = self.serverID(for: client) else { return }
            self.selfNicks[serverID] = nick.stringValue
            self.delegate?.ircConnectionService(self, serverDidRegister: serverID, as: nick.stringValue)
        }
    }

    func clientFailedToRegister(_ client: IRCClient) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let serverID = self.serverID(for: client) else { return }
            self.delegate?.ircConnectionService(self, serverFailedToRegister: serverID)
        }
    }

    func client(_ client: IRCClient, connectionStateChanged state: IRCClient.ConnectionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let serverID = self.serverID(for: client) else { return }
            self.delegate?.ircConnectionService(self, server: serverID, connectionStateChanged: state)
        }
    }

    func client(_ client: IRCClient, messageOfTheDay: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let serverID = self.serverID(for: client) else { return }
            let m = ChatMessage(time: Date(), text: "MOTD:\n\(messageOfTheDay)")
            self.delegate?.ircConnectionService(self, didReceiveMessage: m, for: serverID, target: .server)
        }
    }

    func client(_ client: IRCClient, changedNickTo nick: IRCNickName) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let serverID = self.serverID(for: client) else { return }
            self.selfNicks[serverID] = nick.stringValue
            self.delegate?.ircConnectionService(self, serverDidChangeNick: serverID, to: nick.stringValue)
        }
    }

    func client(_ client: IRCClient, notice message: String, for recipients: [IRCMessageRecipient], serverTime: Date?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let serverID = self.serverID(for: client) else { return }
            // Use server-time if available (for ZNC backlog), otherwise use current time
            let time = serverTime ?? Date()
            let m = ChatMessage(time: time, text: "NOTICE: \(message)")
            self.delegate?.ircConnectionService(self, didReceiveMessage: m, for: serverID, target: .server)
        }
    }

    func client(_ client: IRCClient, message: String, from user: IRCUserID, for recipients: [IRCMessageRecipient], serverTime: Date?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let serverID = self.serverID(for: client) else { return }
            // Use server-time if available (for ZNC backlog), otherwise use current time
            let time = serverTime ?? Date()

            for r in recipients {
                if case .channel(let chName) = r {
                    let name = chName.stringValue
                    let selfNick = self.selfNicks[serverID]
                    let isMine = (selfNick != nil && user.nick.stringValue.compare(selfNick!, options: .caseInsensitive) == .orderedSame)
                    let m = ChatMessage(time: time, text: message, senderNick: user.nick.stringValue, isPrivmsg: true, isFromMe: isMine)
                    self.delegate?.ircConnectionService(self, didReceiveMessage: m, for: serverID, target: .channel(name, isMine: isMine))
                } else if case .nickname(let targetNick) = r {
                    let selfNick = self.selfNicks[serverID] ?? ""
                    let senderIsSelf = user.nick.stringValue.compare(selfNick, options: .caseInsensitive) == .orderedSame
                    let targetIsSelf = targetNick.stringValue.compare(selfNick, options: .caseInsensitive) == .orderedSame

                    if targetIsSelf {
                        // Incoming PM: someone else is messaging us
                        // Target window = sender's nick
                        let senderNick = user.nick.stringValue
                        let m = ChatMessage(time: time, text: message, senderNick: senderNick, isPrivmsg: true, isFromMe: false)
                        self.delegate?.ircConnectionService(self, didReceiveMessage: m, for: serverID, target: .privateMessage(senderNick))
                    } else if senderIsSelf {
                        // Self-message: we sent this PM (from ZNC buffer playback)
                        // Target window = recipient's nick
                        let m = ChatMessage(time: time, text: message, senderNick: selfNick, isPrivmsg: true, isFromMe: true)
                        self.delegate?.ircConnectionService(self, didReceiveMessage: m, for: serverID, target: .privateMessage(targetNick.stringValue))
                    }
                }
            }
        }
    }

    func client(_ client: IRCClient, user: IRCUserID, joined channels: [IRCChannelName]) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let serverID = self.serverID(for: client) else { return }
            
            for ch in channels {
                let name = ch.stringValue
                let nick = user.nick.stringValue
                let selfNick = self.selfNicks[serverID]
                self.delegate?.ircConnectionService(self, user: nick, joinedChannel: name, on: serverID, isSelf: nick == selfNick)
                
                if nick == selfNick {
                    if let client = self.clients[serverID] {
                        client.send(.otherCommand("NAMES", [ name ]))
                        client.send(.otherCommand("WHO",   [ name ]))
                    }
                }
            }
        }
    }

    func client(_ client: IRCClient, user: IRCUserID, left channels: [IRCChannelName], with msg: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let serverID = self.serverID(for: client) else { return }

            for ch in channels {
                let name = ch.stringValue
                let nick = user.nick.stringValue
                let selfNick = self.selfNicks[serverID]
                self.delegate?.ircConnectionService(self, user: nick, leftChannel: name, on: serverID, isSelf: nick == selfNick)
            }
        }
    }

    func client(_ client: IRCClient, user: IRCUserID, changedNickTo newNick: IRCNickName) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let serverID = self.serverID(for: client) else { return }

            let oldNick = user.nick.stringValue
            let newNickString = newNick.stringValue

            self.delegate?.ircConnectionService(self, user: oldNick, changedNickTo: newNickString, on: serverID)
        }
    }

    func client(_ client: IRCClient, userQuit user: IRCUserID, message: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let serverID = self.serverID(for: client) else { return }

            let nick = user.nick.stringValue

            self.delegate?.ircConnectionService(self, userQuit: nick, on: serverID, message: message)
        }
    }

    func client(_ client: IRCClient, received message: IRCMessage) {
        let readable = formatIRCMessage(message, direction: "RECV")
        DispatchQueue.main.async { [weak self] in
            guard let self, let serverID = self.serverID(for: client) else { return }
            let m = ChatMessage(time: Date(), text: readable)
            self.delegate?.ircConnectionService(self, didReceiveMessage: m, for: serverID, target: .server)
        }
        
        let isChannelPrivmsg: Bool = {
            switch message.command {
            case .PRIVMSG(let recipients, _):
                return recipients.contains { if case .channel = $0 { return true } else { return false } }
            default:
                return false
            }
        }()
        
        guard !isChannelPrivmsg else { return }

        switch message.command {
        case .PING(let server, let token):
            if let client = clients[serverID(for: client) ?? UUID()] {
                client.send(.PONG(server: server, server2: token))
            }
        case .PONG(_, _):
            DispatchQueue.main.async { [weak self] in
                guard let self, let serverID = self.serverID(for: client) else { return }
                self.updateLastPongReceived(for: serverID)
            }
        case .otherCommand("PONG", _):
            DispatchQueue.main.async { [weak self] in
                guard let self, let serverID = self.serverID(for: client) else { return }
                self.updateLastPongReceived(for: serverID)
            }
        case .otherCommand("CAP", let args):
            let capMsg = "📥 CAP Response: \(args.joined(separator: " "))"
            print("📥 Received CAP: \(args)")
            DispatchQueue.main.async { [weak self] in
                guard let self, let serverID = self.serverID(for: client) else { return }
                let m = ChatMessage(time: Date(), text: capMsg)
                self.delegate?.ircConnectionService(self, didReceiveMessage: m, for: serverID, target: .server)
            }
        case .numeric(.replyNameReply, let args):
            fallthrough
        case .otherCommand("353", let args):
            guard !args.isEmpty else { return }
            let channelName = args.first(where: { $0.hasPrefix("#") }) ?? (args.count > 2 ? args[2] : "")
            let namesList = args.last ?? ""
            let rawNames = namesList.split(separator: " ").map { String($0) }
            let cleaned = rawNames.map { name -> String in
                guard let first = name.first, "@+~&%".contains(first) else { return name }
                return String(name.dropFirst())
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, let serverID = self.serverID(for: client) else { return }
                self.delegate?.ircConnectionService(self, didReceiveUserList: cleaned, for: channelName, on: serverID)
            }
        case .numeric(.replyEndOfNames, _):
            break
        case .numeric(.replyWhoReply, let args):
            fallthrough
        case .otherCommand("352", let args):
            let channelName = args.first(where: { $0.hasPrefix("#") }) ?? (args.count > 1 ? args[1] : "")
            let nick = args.count > 5 ? args[5] : ""
            guard !channelName.isEmpty, !nick.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let serverID = self.serverID(for: client) else { return }
                self.delegate?.ircConnectionService(self, didReceiveWhoReply: nick, for: channelName, on: serverID)
            }
        default:
            break
        }
    }
}

// MARK: - Supporting Types

enum MessageTarget {
    case channel(IRCChannel)
    case privateMessage(IRCPrivateMessage)
    case server
}

enum MessageTargetType {
    case server
    case channel(String, isMine: Bool)
    case privateMessage(String)
}

protocol IRCConnectionServiceDelegate: AnyObject {
    func ircConnectionService(_ service: IRCConnectionService, didAppendMessage message: ChatMessage, to server: IRCServer)
    func ircConnectionService(_ service: IRCConnectionService, serverDidDisconnect serverID: UUID)
    func ircConnectionService(_ service: IRCConnectionService, serverDidRegister serverID: UUID, as nick: String)
    func ircConnectionService(_ service: IRCConnectionService, serverFailedToRegister serverID: UUID)
    func ircConnectionService(_ service: IRCConnectionService, server serverID: UUID, connectionStateChanged state: IRCClient.ConnectionState)
    func ircConnectionService(_ service: IRCConnectionService, serverDidChangeNick serverID: UUID, to nick: String)
    func ircConnectionService(_ service: IRCConnectionService, didReceiveMessage message: ChatMessage, for serverID: UUID, target: MessageTargetType)
    func ircConnectionService(_ service: IRCConnectionService, user nick: String, joinedChannel channel: String, on serverID: UUID, isSelf: Bool)
    func ircConnectionService(_ service: IRCConnectionService, user nick: String, leftChannel channel: String, on serverID: UUID, isSelf: Bool)
    func ircConnectionService(_ service: IRCConnectionService, user oldNick: String, changedNickTo newNick: String, on serverID: UUID)
    func ircConnectionService(_ service: IRCConnectionService, userQuit nick: String, on serverID: UUID, message: String?)
    func ircConnectionService(_ service: IRCConnectionService, didReceiveUserList users: [String], for channel: String, on serverID: UUID)
    func ircConnectionService(_ service: IRCConnectionService, didReceiveWhoReply nick: String, for channel: String, on serverID: UUID)
}
