import AppKit
import Foundation
import Network

/// Owns one IRCClient per connected server, and reports what happens on each to its owner
/// as `Event`s. Everything here, including IRCClient's events and all IRCServer model
/// mutation, runs on the main actor.
final class IRCConnectionService: ReconnectionManagerDelegate {
    /// What the service reports about one of its servers.
    enum Event {
        /// A line was added to one of the server's logs: a message we sent, a status line, or
        /// a failure to send.
        case logAppended(ChatMessage)
        /// A line arrived for the server log, a channel, or a private conversation.
        case messageReceived(ChatMessage, MessageTargetType)
        /// The server accepted us under `nick`.
        case registered(nick: String)
        /// The connection ended before registration completed: it was refused, cut off, or
        /// turned down by the server.
        case registrationFailed(reason: String)
        /// A registered connection ended.
        case disconnected(reason: String)
        /// Our own nickname changed.
        case nicknameChanged(String)
        case joined(channel: String, nick: String, isSelf: Bool)
        case parted(channel: String, nick: String, isSelf: Bool)
        /// `nick` was removed from `channel` by `kicker` (nil when the server did it).
        case kicked(channel: String, nick: String, kicker: String?, reason: String?, isSelf: Bool)
        /// Someone else changed their nickname. (Ours is `nicknameChanged`.)
        case nickChanged(from: String, to: String)
        case quit(nick: String, reason: String?)
        /// The channel topic: the current one when joining (`setBy` nil), or a change.
        case topic(channel: String, topic: String, setBy: String?)
        /// A batch of channel members, without their status prefixes.
        case names(channel: String, nicks: [String])
        /// One channel member from a WHO reply.
        case whoReply(channel: String, nick: String)
    }

    /// Receives every event, in order, with the server it concerns.
    var onEvent: (Event, IRCServer) -> Void = { _, _ in }
    /// Called after a wake from sleep, or when the network returns after an outage: the time
    /// to reconnect servers that should be connected.
    var onNetworkAvailable: () -> Void = {}

    // Clients and connection state
    private(set) var clients: [UUID: IRCClient] = [:]
    private var connectionTimeouts: [UUID: Task<Void, any Error>] = [:]
    private var pingTasks: [UUID: Task<Void, any Error>] = [:]
    /// Monotonic, so wall-clock changes (NTP, manual edits) can't fake a dead connection.
    private var lastPongReceived: [UUID: ContinuousClock.Instant] = [:]

    // Message send queue (flood protection)
    private var messageQueue: [QueuedLine] = []
    private var queueTask: Task<Void, any Error>?
    private let burstLimit = 5
    private let queueInterval: Duration = .milliseconds(500)

    /// A line waiting its turn in the flood-protection queue.
    private struct QueuedLine {
        var text: String
        var isAction: Bool
        var target: MessageTarget
        var server: IRCServer
    }

    // Reconnection handling
    private let reconnectionManager = ReconnectionManager()

    // Network monitoring for immediate disconnect detection
    private var pathMonitorTask: Task<Void, Never>?

    // Default nick
    private let defaultNick = "Guest\(Int.random(in: 1000...9999))"

    /// When true, every line received from a server is echoed to its server log as a "RECV:"
    /// line. Off by default; mirrored from AppPreferences at launch and when toggled.
    var debugRawServerLog = false

    // Server lookup for reconnection callbacks
    private var serverLookup: ((UUID) -> IRCServer?)?

    /// Configure the server lookup closure. Must be called before reconnection can work.
    func configureServerLookup(_ lookup: @escaping (UUID) -> IRCServer?) {
        self.serverLookup = lookup
    }

    // Typed-notification tokens deregister themselves when released.
    private var sleepObserver: NotificationCenter.ObservationToken?
    private var wakeObserver: NotificationCenter.ObservationToken?

    init() {
        setupNetworkMonitoring()
        setupSleepWakeMonitoring()
        reconnectionManager.delegate = self
    }

    deinit {
        pathMonitorTask?.cancel()
        // Cancel all connect timeouts
        for task in connectionTimeouts.values {
            task.cancel()
        }
        // Cancel all ping tasks
        for task in pingTasks.values {
            task.cancel()
        }
        queueTask?.cancel()
        // Reconnection manager cleans up in its own deinit
    }

    // MARK: - Sleep/Wake Monitoring

    private func setupSleepWakeMonitoring() {
        let center = NSWorkspace.shared.notificationCenter

        sleepObserver = center.addObserver(of: NSWorkspace.shared, for: NSWorkspace.WillSleepMessage.self) { [weak self] _ in
            self?.handleSleep()
        }

        wakeObserver = center.addObserver(of: NSWorkspace.shared, for: NSWorkspace.DidWakeMessage.self) { [weak self] _ in
            self?.handleWake()
        }
    }

    private func handleSleep() {
        // Tear down all connections immediately before the system sleeps.
        // No waiting for server responses - just close the sockets.
        for serverID in Array(clients.keys) {
            tearDownConnection(for: serverID)
        }
        // Clear message queue — no point sending after sleep
        clearMessageQueue()
    }

    /// Full per-server teardown for the "close everything now" paths (sleep, network
    /// loss, a dead or timed-out connection, the connection ending on its own): cancel
    /// reconnection, ping monitoring and the connect-timeout timer, mark
    /// the model disconnected, close the client, and drop per-server bookkeeping.
    /// One shared checklist so the paths can't drift apart (network loss used to skip
    /// the timers, leaking a live connect-timeout that could double-schedule reconnects).
    private func tearDownConnection(for serverID: UUID) {
        reconnectionManager.cancelReconnection(for: serverID)
        pingTasks.removeValue(forKey: serverID)?.cancel()
        lastPongReceived.removeValue(forKey: serverID)
        connectionTimeouts.removeValue(forKey: serverID)?.cancel()

        if let server = serverLookup?(serverID) {
            if server.connectionStatus == .connected || server.connectionStatus == .connecting {
                server.connectionStatus = .disconnected
            }
            for channel in server.channels {
                channel.joined = false
            }
        }

        if let client = clients.removeValue(forKey: serverID) {
            client.close()
        }
    }

    private func clearMessageQueue() {
        queueTask?.cancel()
        queueTask = nil
        messageQueue.removeAll()
    }

    private func handleWake() {
        // After waking, reconnect all servers that should auto-reconnect.
        onNetworkAvailable()
    }

    // MARK: - Network Monitoring

    private var networkWasUnavailable = false

    private func setupNetworkMonitoring() {
        // Iterating the monitor starts it; cancelling the task stops it.
        pathMonitorTask = Task { [weak self] in
            for await path in NWPathMonitor() {
                guard let self else { return }
                if path.status == .satisfied {
                    // Network is available - reconnect servers if we previously lost network
                    if self.networkWasUnavailable {
                        self.networkWasUnavailable = false
                        self.handleNetworkRestored()
                    }
                } else {
                    // Network is down - immediately disconnect all servers
                    self.networkWasUnavailable = true
                    self.handleNetworkLoss()
                }
            }
        }
    }

    private func handleNetworkLoss() {
        for serverID in Array(clients.keys) {
            if let server = serverLookup?(serverID) {
                logToServer("Network unavailable", on: server)
            }
            tearDownConnection(for: serverID)
        }
        // Clear message queue — can't send without network
        clearMessageQueue()
    }

    private func handleNetworkRestored() {
        onNetworkAvailable()
    }

    // MARK: - Connection Management
    
    func connect(_ server: IRCServer) {
        guard server.connectionStatus != .connecting && server.connectionStatus != .connected else {
            return
        }
        
        server.connectionStatus = .connecting
        
        let statusText = server.displayAttempt > 0 ?
            "Reconnecting to \(server.name) (attempt \(server.displayAttempt)/\(ReconnectionManager.Policy.default.maxAttempts))" :
            "Connecting to \(server.name) (\(server.host):\(server.port))"
        logToServer(statusText, on: server)

        // Per-server nick: explicit server nickname, else last-known currentNick, else the app
        // default, else "Guest". First candidate that is a valid nickname wins.
        let nick = [server.nickname, server.currentNick, defaultNick]
            .lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first(where: IRCName.isValidNickname) ?? "Guest"
        let client = IRCClient(host: server.host, port: server.port, useTLS: server.useTLS,
                               nickname: nick, password: server.password)
        client.onEvent = { [weak self, weak client, serverID = server.id] event in
            guard let self, let client else { return }
            self.handle(event, from: client, serverID: serverID)
        }
        clients[server.id]?.close()   // a replaced client must not keep reporting
        clients[server.id] = client
        
        // Set up connection timeout
        setupConnectionTimeout(for: server)
        
        client.connect()
    }

    func disconnect(_ server: IRCServer) {
        logToServer("Disconnecting from \(server.name)…", on: server)
        
        // Cancel any timers
        cancelConnectionTimeout(for: server)
        reconnectionManager.cancelReconnection(for: server.id)
        stopPingMonitoring(for: server)
        
        clients.removeValue(forKey: server.id)?.quit()
        messageQueue.removeAll { $0.server.id == server.id }
        if messageQueue.isEmpty { queueTask?.cancel(); queueTask = nil }
        server.channels.removeAll()
        server.connectionStatus = .disconnected
        server.displayAttempt = 0
        server.shouldAutoReconnect = false
        
        logToServer("Disconnected from \(server.name)", on: server)
    }
    
    private func setupConnectionTimeout(for server: IRCServer) {
        cancelConnectionTimeout(for: server)
        
        // Task.sleep only throws on cancellation, which simply ends the task.
        connectionTimeouts[server.id] = Task { [weak self] in
            try await Task.sleep(for: .seconds(30))
            try Task.checkCancellation()
            self?.connectionTimeouts[server.id] = nil
            self?.handleConnectionTimeout(for: server)
        }
    }
    
    func cancelConnectionTimeout(for server: IRCServer) {
        connectionTimeouts.removeValue(forKey: server.id)?.cancel()
    }
    
    private func handleConnectionTimeout(for server: IRCServer) {
        // Allow timeout handling if we're still trying to connect OR if the connection
        // attempt just ended. Prevents skipping cleanup when the status turned
        // .disconnected right before the timeout fired.
        let validStates: [IRCServer.ConnectionStatus] = [.connecting, .disconnected]
        guard validStates.contains(server.connectionStatus) else { return }

        // Only log timeout message if we were still connecting (not already disconnected)
        if server.connectionStatus == .connecting {
            logToServer("Connection to \(server.name) timed out", on: server)
        }

        server.connectionStatus = .connectionTimeout
        tearDownConnection(for: server.id)

        // Attempt reconnection if enabled
        if server.shouldAutoReconnect {
            scheduleReconnection(for: server)
        }
    }
    
    func scheduleReconnection(for server: IRCServer) {
        reconnectionManager.scheduleReconnection(for: server.id)
    }

    func resetReconnectionAttempts(for server: IRCServer) {
        reconnectionManager.resetAttempts(for: server.id)
        server.displayAttempt = 0
    }

    // MARK: - ReconnectionManagerDelegate

    func reconnectionManager(_ manager: ReconnectionManager, shouldReconnect serverID: UUID) {
        guard let server = serverLookup?(serverID) else { return }
        connect(server)
    }

    func reconnectionManager(_ manager: ReconnectionManager, didScheduleReconnect serverID: UUID, attempt: Int, delay: Duration) {
        guard let server = serverLookup?(serverID) else { return }

        server.connectionStatus = .reconnecting
        server.displayAttempt = attempt

        logToServer("Reconnecting to \(server.name) in \(delay.components.seconds) seconds... (attempt \(attempt)/\(ReconnectionManager.Policy.default.maxAttempts))", on: server)
    }

    func reconnectionManager(_ manager: ReconnectionManager, didExhaustAttempts serverID: UUID, maxAttempts: Int) {
        guard let server = serverLookup?(serverID) else { return }

        server.connectionStatus = .reconnectionFailed
        server.shouldAutoReconnect = false

        logToServer("Failed to reconnect to \(server.name) after \(maxAttempts) attempts", on: server)
    }
    
    func startPingMonitoring(for server: IRCServer) {
        stopPingMonitoring(for: server)
        lastPongReceived[server.id] = .now

        guard clients[server.id] != nil else { return }

        // Task.sleep only throws on cancellation, which ends the loop.
        pingTasks[server.id] = Task { [weak self] in
            while true {
                try await Task.sleep(for: .seconds(60))
                try Task.checkCancellation()
                guard let self else { return }
                self.checkConnectionHealth(for: server)
            }
        }
    }

    private func stopPingMonitoring(for server: IRCServer) {
        pingTasks.removeValue(forKey: server.id)?.cancel()
        lastPongReceived.removeValue(forKey: server.id)
    }
    
    private func checkConnectionHealth(for server: IRCServer) {
        guard server.connectionStatus == .connected,
              let client = clients[server.id] else { return }
        
        if let lastPong = lastPongReceived[server.id],
           ContinuousClock.now - lastPong > .seconds(120) {
            handleConnectionDead(for: server)
            return
        }
        
        client.send(.ping("\(Date.now.timeIntervalSince1970)"))
    }
    
    private func handleConnectionDead(for server: IRCServer) {
        // Idempotency guard - prevent duplicate handling
        guard server.connectionStatus == .connected || server.connectionStatus == .connecting else { return }

        server.connectionStatus = .connectionTimeout

        logToServer("Connection to \(server.name) lost", on: server)
        tearDownConnection(for: server.id)

        if server.shouldAutoReconnect {
            scheduleReconnection(for: server)
        }
    }

    // MARK: - Channel Operations
    
    func joinChannel(_ name: String, key: String? = nil, on server: IRCServer) {
        guard let client = clients[server.id] else {
            handleSendFailure(for: server, reason: "Cannot join channel: Not connected")
            return
        }

        guard isRegistered(server.id) else {
            handleSendFailure(for: server, reason: "Cannot join channel: Not registered")
            return
        }

        client.send(.join(name, key: key))
        _ = server.getOrCreateChannel(named: name)
    }

    func partChannel(_ channel: IRCChannel, from server: IRCServer) {
        guard let client = clients[server.id] else {
            handleSendFailure(for: server, reason: "Cannot part channel: Not connected")
            return
        }

        guard isRegistered(server.id) else {
            handleSendFailure(for: server, reason: "Cannot part channel: Not registered")
            return
        }

        client.send(.part(channel.name))
        server.channels.removeAll { $0.id == channel.id }
        // "Parted X" is logged once, by ChatStore, when the server confirms the PART.
    }
    
    // MARK: - Topic

    func sendTopicChange(_ newTopic: String, for channelName: String, on server: IRCServer) {
        guard let client = clients[server.id], isRegistered(server.id) else { return }
        client.send(.topic(channelName, newTopic))
    }

    // MARK: - Messaging

    /// Send a message to an arbitrary nick or channel (used by /msg command)
    /// Creates a PM conversation if needed
    func sendMessageToTarget(_ text: String, targetName: String, from server: IRCServer) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard clients[server.id] != nil else {
            handleSendFailure(for: server, reason: "Not connected")
            return
        }

        guard isRegistered(server.id) else {
            handleSendFailure(for: server, reason: "Not registered")
            return
        }

        if IRCName.isChannel(targetName) {
            // Channel message - find or create channel
            let channel = server.getOrCreateChannel(named: targetName)
            sendMessage(trimmed, to: .channel(channel), from: server)
        } else {
            // Private message - find or create PM conversation
            let pm = server.getOrCreatePrivateMessage(with: targetName)
            sendMessage(trimmed, to: .privateMessage(pm), from: server)
        }
    }

    /// Sends `text` to a channel or private conversation, one line at a time through the flood
    /// queue; with `asAction`, each line goes out as a `/me` action.
    func sendMessage(_ text: String, asAction isAction: Bool = false, to target: MessageTarget, from server: IRCServer) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch target {
        case .server:
            // Server messages are local-only (no IRC send), no splitting needed
            logToServer(trimmed, on: server)

        case .channel, .privateMessage:
            // isNewline covers \n, \r and the single-Character \r\n, so no stray \r
            // ends up inside an outgoing IRC line. Empty lines are omitted.
            let lines = trimmed.split(whereSeparator: \.isNewline).map(String.init)
            guard !lines.isEmpty else { return }
            enqueueLines(lines, isAction: isAction, to: target, from: server)
        }
    }

    private func sendSingleLine(_ text: String, isAction: Bool, to target: MessageTarget, from server: IRCServer) {
        guard let client = clients[server.id] else {
            handleSendFailure(for: server, target: target, reason: "Not connected")
            return
        }

        guard isRegistered(server.id) else {
            handleSendFailure(for: server, target: target, reason: "Not registered")
            return
        }

        // Show our own line right away: the server never sends it back to us, because we
        // don't request IRCv3 echo-message. (znc.in/self-message is something else: it makes
        // a bouncer relay what we send from our *other* clients, which arrives as isOwn.)
        let nick = server.currentNick ?? defaultNick
        let msg = ChatMessage(time: Date(), text: text, senderNick: nick, isPrivmsg: true, isFromMe: true, isAction: isAction)
        let recipient: String
        switch target {
        case .channel(let channel):
            channel.log.append(msg)
            recipient = channel.name
        case .privateMessage(let pm):
            pm.log.append(msg)
            recipient = pm.nickname
        case .server:
            return
        }
        onEvent(.logAppended(msg), server)
        // A failed write ends the connection, which arrives as a .disconnected event.
        client.send(isAction ? .action(to: recipient, text) : .privateMessage(to: recipient, text))
    }

    private func enqueueLines(_ lines: [String], isAction: Bool, to target: MessageTarget, from server: IRCServer) {
        let immediateCount = messageQueue.isEmpty ? min(lines.count, burstLimit) : 0

        for line in lines.prefix(immediateCount) {
            sendSingleLine(line, isAction: isAction, to: target, from: server)
        }

        for line in lines.dropFirst(immediateCount) {
            messageQueue.append(QueuedLine(text: line, isAction: isAction, target: target, server: server))
        }

        if !messageQueue.isEmpty && queueTask == nil {
            // Sends one queued line per interval until drainQueue() empties the queue and
            // clears queueTask. Task.sleep only throws on cancellation, which ends the loop.
            queueTask = Task { [weak self, queueInterval] in
                while true {
                    try await Task.sleep(for: queueInterval)
                    try Task.checkCancellation()
                    guard let self else { return }
                    self.drainQueue()
                    if self.queueTask == nil { return }
                }
            }
        }
    }

    private func drainQueue() {
        guard !messageQueue.isEmpty else {
            queueTask?.cancel()
            queueTask = nil
            return
        }

        let item = messageQueue.removeFirst()
        sendSingleLine(item.text, isAction: item.isAction, to: item.target, from: item.server)

        if messageQueue.isEmpty {
            queueTask?.cancel()
            queueTask = nil
        }
    }

    /// Appends a status line to the server log and reports it — the shared
    /// tail of every "something happened on this connection" message.
    private func logToServer(_ text: String, on server: IRCServer) {
        let msg = ChatMessage(time: Date(), text: text)
        server.log.append(msg)
        onEvent(.logAppended(msg), server)
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

        onEvent(.logAppended(msg), server)
    }
    
    // MARK: - Helper Methods

    /// Whether the server's connection has completed registration.
    func isRegistered(_ serverID: UUID) -> Bool {
        clients[serverID]?.isRegistered ?? false
    }

    // MARK: - Client Events

    /// Applies one event from a server's IRCClient. Clients report on the main actor, in
    /// order, and go quiet once closed, so every event here is from the live connection.
    private func handle(_ event: IRCEvent, from client: IRCClient, serverID: UUID) {
        switch event {
        case .lineReceived(let line):
            if debugRawServerLog { logServerEvent("RECV: \(line)", for: serverID) }

        case .registered(let nick):
            report(.registered(nick: nick), for: serverID)

        case .registrationFailed(let reason):
            // The server turned us down (bad password, banned, no usable nickname): retrying
            // can't change its answer, so wait for the user to connect again.
            serverLookup?(serverID)?.shouldAutoReconnect = false
            registrationDidFail(for: serverID, reason: reason)

        case .disconnected(let reason):
            if client.isRegistered {
                connectionDidEnd(for: serverID, reason: reason)
            } else {
                registrationDidFail(for: serverID, reason: reason)
            }

        case .nicknameChanged(let nick):
            report(.nicknameChanged(nick), for: serverID)

        case .messageOfTheDay(let text):
            logServerEvent("MOTD:\n\(text)", for: serverID)

        case .pong:
            lastPongReceived[serverID] = .now
            // The first keep-alive round trip, a minute after registering, is what makes a
            // reconnect count as successful and earns a fresh set of attempts.
            if let server = serverLookup?(serverID), server.displayAttempt > 0 {
                resetReconnectionAttempts(for: server)
            }

        // Server time, when present, dates bouncer backlog to when it was originally sent.
        case .channelMessage(let channel, let message):
            let statusTarget = message.statusPrefix.map { "\($0)\(channel)" }
            report(.messageReceived(chatMessage(message, statusTarget: statusTarget, nickname: client.nickname), .channel(channel)),
                   for: serverID)

        case .privateMessage(let peer, let message):
            report(.messageReceived(chatMessage(message, nickname: client.nickname), .privateMessage(peer)), for: serverID)

        case .notice(let text, let time):
            logServerEvent("NOTICE: \(text)", time: time, for: serverID)

        case .joined(let channel, let nick, let isSelf):
            report(.joined(channel: channel, nick: nick, isSelf: isSelf), for: serverID)
            if isSelf {
                client.send(.names(channel))
                client.send(.who(channel))
            }

        case .parted(let channel, let nick, let isSelf):
            report(.parted(channel: channel, nick: nick, isSelf: isSelf), for: serverID)

        case .kicked(let channel, let nick, let kicker, let reason, let isSelf):
            report(.kicked(channel: channel, nick: nick, kicker: kicker, reason: reason, isSelf: isSelf), for: serverID)

        case .quit(let nick, let reason):
            report(.quit(nick: nick, reason: reason), for: serverID)

        case .nickChanged(let oldNick, let newNick):
            report(.nickChanged(from: oldNick, to: newNick), for: serverID)

        case .topic(let channel, let topic, let setBy):
            report(.topic(channel: channel, topic: topic, setBy: setBy), for: serverID)

        case .names(let channel, let nicks):
            report(.names(channel: channel, nicks: nicks), for: serverID)

        case .whoReply(let channel, let nick):
            report(.whoReply(channel: channel, nick: nick), for: serverID)
        }
    }

    /// The log entry for a received PRIVMSG. Someone else's message that mentions `nickname`
    /// (ours) is a highlight.
    private func chatMessage(_ message: IRCEvent.Message, statusTarget: String? = nil, nickname: String) -> ChatMessage {
        ChatMessage(time: message.time ?? Date(), text: message.text, senderNick: message.sender, isPrivmsg: true,
                    isFromMe: message.isOwn, isHighlight: !message.isOwn && Formatting.mentionsNick(nickname, in: message.text),
                    isAction: message.isAction, statusTarget: statusTarget)
    }

    /// A server-log line reporting something the server said.
    private func logServerEvent(_ text: String, time: Date? = nil, for serverID: UUID) {
        let message = ChatMessage(time: time ?? Date(), text: text)
        report(.messageReceived(message, .server), for: serverID)
    }

    /// Reports `event` for the server with `serverID`, unless the server is gone.
    private func report(_ event: Event, for serverID: UUID) {
        guard let server = serverLookup?(serverID) else { return }
        onEvent(event, server)
    }

    /// A registered connection ended: tidy up, and let the owner decide about reconnecting.
    private func connectionDidEnd(for serverID: UUID, reason: String) {
        tearDownConnection(for: serverID)
        messageQueue.removeAll { $0.server.id == serverID }
        if messageQueue.isEmpty { queueTask?.cancel(); queueTask = nil }
        report(.disconnected(reason: reason), for: serverID)
    }

    /// The connection ended before registration completed: it was refused, cut off, or
    /// turned down by the server.
    private func registrationDidFail(for serverID: UUID, reason: String) {
        tearDownConnection(for: serverID)
        report(.registrationFailed(reason: reason), for: serverID)
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
    case channel(String)
    case privateMessage(String)
}
