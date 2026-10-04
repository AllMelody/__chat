import AppKit
import Foundation
import Network

/// Owns one IRCClient per connected server, and reports what happens on each to its owner
/// as `Event`s. Everything here, including IRCClient's events and all IRCServer model
/// mutation, runs on the main actor.
final class IRCConnectionService {
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
        /// The server refused something we sent. `subject` is the channel, nick or command
        /// it's about, when the reply names one.
        case errorReply(subject: String?, text: String)
        case joined(channel: String, nick: String, isSelf: Bool)
        case parted(channel: String, nick: String, isSelf: Bool)
        /// `nick` was removed from `channel` by `kicker` (nil when the server did it).
        case kicked(channel: String, nick: String, kicker: String?, reason: String?, isSelf: Bool)
        /// Someone else changed their nickname. (Ours is `nicknameChanged`.)
        case nickChanged(from: String, to: String)
        case quit(nick: String, reason: String?)
        /// The channel topic: the current one when joining (`setBy` nil), or a change.
        case topic(channel: String, topic: String, setBy: String?)
        /// Everyone in a channel, without their status prefixes.
        case names(channel: String, nicks: [String])
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
    private var reconnection = ReconnectionPolicy.default
    private var reconnectTasks: [UUID: Task<Void, any Error>] = [:]

    // Network monitoring for immediate disconnect detection
    private var pathMonitorTask: Task<Void, Never>?

    // Default nick
    private let defaultNick = "Guest\(Int.random(in: 1000...9999))"

    /// When true, every line received from a server is echoed to its server log as a "RECV:"
    /// line. Off by default; mirrored from AppPreferences at launch and when toggled.
    var debugRawServerLog = false

    // Server lookup for client events and teardown, which only know a server's ID
    private var serverLookup: ((UUID) -> IRCServer?)?

    /// Configure the server lookup closure. Must be called before connecting.
    func configureServerLookup(_ lookup: @escaping (UUID) -> IRCServer?) {
        self.serverLookup = lookup
    }

    // Typed-notification tokens deregister themselves when released.
    private var sleepObserver: NotificationCenter.ObservationToken?
    private var wakeObserver: NotificationCenter.ObservationToken?

    init() {
        setupNetworkMonitoring()
        setupSleepWakeMonitoring()
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
        for task in reconnectTasks.values {
            task.cancel()
        }
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
        // No waiting for server responses before the system sleeps: just close the sockets.
        suspendConnections(reason: "Going to sleep")
    }

    /// Drops every connection, and any retry waiting to happen, until the Mac wakes or the
    /// network returns; `onNetworkAvailable` then brings back the servers that should be
    /// connected.
    private func suspendConnections(reason: String) {
        for serverID in Set(clients.keys).union(reconnectTasks.keys) {
            if let server = serverLookup?(serverID) {
                logToServer(reason, on: server)
            }
            tearDownConnection(for: serverID)
        }
        clearMessageQueue()
    }

    /// Full per-server teardown for the "close everything now" paths (sleep, network
    /// loss, a dead or timed-out connection, the connection ending on its own): cancel
    /// reconnection, ping monitoring and the connect-timeout timer, mark
    /// the model disconnected, close the client, and drop per-server bookkeeping.
    /// One shared checklist so the paths can't drift apart (network loss used to skip
    /// the timers, leaking a live connect-timeout that could double-schedule reconnects).
    private func tearDownConnection(for serverID: UUID) {
        cancelReconnection(for: serverID)
        pingTasks.removeValue(forKey: serverID)?.cancel()
        lastPongReceived.removeValue(forKey: serverID)
        connectionTimeouts.removeValue(forKey: serverID)?.cancel()

        if let server = serverLookup?(serverID) {
            if [.connecting, .connected, .reconnecting].contains(server.connectionStatus) {
                server.connectionStatus = .disconnected
            }
            // Off the server, we're in no channel; rejoining brings fresh member lists.
            for channel in server.channels {
                channel.joined = false
                channel.users.removeAll()
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

    /// Set while the network is down. Nothing retries then; the network's return does.
    private var isOffline = false

    private func setupNetworkMonitoring() {
        // Iterating the monitor starts it; cancelling the task stops it.
        pathMonitorTask = Task { [weak self] in
            for await path in NWPathMonitor() {
                guard let self else { return }
                if path.status == .satisfied {
                    if self.isOffline {
                        self.isOffline = false
                        self.handleNetworkRestored()
                    }
                } else {
                    self.isOffline = true
                    self.handleNetworkLoss()
                }
            }
        }
    }

    private func handleNetworkLoss() {
        suspendConnections(reason: "Network unavailable")
    }

    private func handleNetworkRestored() {
        onNetworkAvailable()
    }

    // MARK: - Connection Management
    
    func connect(_ server: IRCServer) {
        guard server.connectionStatus != .connecting && server.connectionStatus != .connected else {
            return
        }
        cancelReconnection(for: server.id)   // this is the attempt a pending retry would have made
        server.connectionStatus = .connecting
        
        let statusText = server.displayAttempt > 0 ?
            "Reconnecting to \(server.name) (attempt \(server.displayAttempt)/\(reconnection.maxAttempts))" :
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
        cancelReconnection(for: server.id)
        stopPingMonitoring(for: server)
        
        clients.removeValue(forKey: server.id)?.quit()
        removeQueuedLines { $0.server.id == server.id }
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
        // Everything that ends an attempt cancels its timeout, so this is a stuck attempt.
        guard server.connectionStatus == .connecting else { return }

        logToServer("Connection to \(server.name) timed out", on: server)
        server.connectionStatus = .connectionTimeout
        tearDownConnection(for: server.id)

        // Attempt reconnection if enabled
        if server.shouldAutoReconnect {
            scheduleReconnection(for: server)
        }
    }
    
    /// Retries the connection as the reconnection policy says: the first attempt right away,
    /// later ones after a pause, and none once the attempts run out. The connect itself always
    /// runs as a task of its own, so it never starts in the middle of handling whatever ended
    /// the previous connection.
    func scheduleReconnection(for server: IRCServer) {
        cancelReconnection(for: server.id)
        // Retrying without a network would only use up attempts. The network's return
        // reconnects the server instead.
        guard !isOffline else { return }

        switch reconnection.nextAttempt(for: server.id) {
        case .giveUp:
            server.connectionStatus = .reconnectionFailed
            server.shouldAutoReconnect = false
            logToServer("Failed to reconnect to \(server.name) after \(reconnection.maxAttempts) attempts", on: server)

        case .retry(let attempt, let delay):
            server.connectionStatus = .reconnecting
            server.displayAttempt = attempt
            // An immediate retry is announced by connect() alone.
            if delay > .zero {
                logToServer("Reconnecting to \(server.name) in \(delay.components.seconds) seconds… (attempt \(attempt)/\(reconnection.maxAttempts))", on: server)
            }

            // Task.sleep only throws on cancellation, which simply ends the task.
            reconnectTasks[server.id] = Task { [weak self] in
                if delay > .zero { try await Task.sleep(for: delay) }
                // A cancel can land after the sleep finished but before we resumed on main.
                try Task.checkCancellation()
                guard let self else { return }
                self.reconnectTasks[server.id] = nil
                self.connect(server)
            }
        }
    }

    private func cancelReconnection(for serverID: UUID) {
        reconnectTasks.removeValue(forKey: serverID)?.cancel()
    }

    func resetReconnectionAttempts(for server: IRCServer) {
        reconnection.reset(for: server.id)
        server.displayAttempt = 0
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

        logToServer("Connection to \(server.name) lost (ping timeout)", on: server)
        tearDownConnection(for: server.id)

        if server.shouldAutoReconnect {
            scheduleReconnection(for: server)
        }
    }

    // MARK: - Channel Operations
    
    func joinChannel(_ name: String, key: String? = nil, on server: IRCServer) {
        guard let client = clients[server.id], client.isRegistered else {
            handleSendFailure(for: server, reason: "Cannot join channel: Not connected")
            return
        }

        client.send(.join(name, key: key))
        let channel = server.getOrCreateChannel(named: name)
        if let key { channel.key = key }
    }

    /// Takes us out of a channel. The server confirms with a PART of our own.
    func partChannel(named name: String, on server: IRCServer) {
        clients[server.id]?.send(.part(name))
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
        guard isRegistered(server.id) else {
            handleSendFailure(for: server, reason: "Not connected")
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
    /// queue; with `asAction`, each line goes out as a `/me` action. Lines too long for IRC are
    /// split, so everyone gets the same lines we show.
    func sendMessage(_ text: String, asAction isAction: Bool = false, to target: MessageTarget, from server: IRCServer) {
        guard let client = clients[server.id], client.isRegistered else {
            handleSendFailure(for: server, target: target, reason: "Not connected")
            return
        }
        let maximumLength = IRCMessage.maximumTextLength(to: target.name, from: client.nickname, asAction: isAction)
        // isNewline covers \n, \r and the single-Character \r\n, so no stray \r ends up
        // inside an outgoing IRC line. Blank lines are left out.
        let lines = text.split(whereSeparator: \.isNewline)
            .filter { !$0.allSatisfy(\.isWhitespace) }
            .flatMap { IRCMessage.split(String($0), maximumLength: maximumLength) }
        guard !lines.isEmpty else { return }
        enqueueLines(lines, isAction: isAction, to: target, from: server)
    }

    private func sendSingleLine(_ text: String, isAction: Bool, to target: MessageTarget, from server: IRCServer) {
        // The connection can drop while lines wait in the queue.
        guard let client = clients[server.id], client.isRegistered else {
            handleSendFailure(for: server, target: target, reason: "Not connected")
            return
        }

        // Show our own line right away: the server never sends it back to us, because we
        // don't request IRCv3 echo-message. (znc.in/self-message is something else: it makes
        // a bouncer relay what we send from our *other* clients, which arrives as isOwn.)
        let msg = ChatMessage(time: Date(), text: text, senderNick: client.nickname, isPrivmsg: true, isFromMe: true, isAction: isAction)
        switch target {
        case .channel(let channel): channel.log.append(msg)
        case .privateMessage(let pm): pm.log.append(msg)
        }
        onEvent(.logAppended(msg), server)
        // A failed write ends the connection, which arrives as a .disconnected event.
        client.send(isAction ? .action(to: target.name, text) : .privateMessage(to: target.name, text))
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

    /// Forgets lines still waiting to go to a conversation that's being closed.
    func cancelQueuedLines(to conversationID: UUID) {
        removeQueuedLines { $0.target.id == conversationID }
    }

    private func removeQueuedLines(where shouldRemove: (QueuedLine) -> Bool) {
        messageQueue.removeAll(where: shouldRemove)
        if messageQueue.isEmpty { clearMessageQueue() }
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
        case .none:
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

        case .errorReply(let subject, let text):
            report(.errorReply(subject: subject, text: text), for: serverID)

        // Server time, when present, dates bouncer backlog to when it was originally sent.
        case .channelMessage(let channel, let message):
            let statusTarget = message.statusPrefix.map { "\($0)\(channel)" }
            report(.messageReceived(chatMessage(message, statusTarget: statusTarget, nickname: client.nickname), .channel(channel)),
                   for: serverID)

        case .privateMessage(let peer, let message):
            report(.messageReceived(chatMessage(message, nickname: client.nickname), .privateMessage(peer)), for: serverID)

        case .notice(let sender, let channel, let text, let time):
            // "NOTICE from NickServ: …", "NOTICE from bot to #chan: …", or just "NOTICE: …"
            let origin = (sender.map { " from \($0)" } ?? "") + (channel.map { " to \($0)" } ?? "")
            logServerEvent("NOTICE\(origin): \(text)", time: time, for: serverID)

        case .joined(let channel, let nick, let isSelf):
            report(.joined(channel: channel, nick: nick, isSelf: isSelf), for: serverID)

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
        removeQueuedLines { $0.server.id == serverID }
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

/// A conversation messages can be sent to.
enum MessageTarget {
    case channel(IRCChannel)
    case privateMessage(IRCPrivateMessage)

    /// The channel or nick the messages are addressed to.
    var name: String {
        switch self {
        case .channel(let channel): channel.name
        case .privateMessage(let pm): pm.nickname
        }
    }

    /// The conversation's sidebar ID.
    var id: UUID {
        switch self {
        case .channel(let channel): channel.id
        case .privateMessage(let pm): pm.id
        }
    }
}

enum MessageTargetType {
    case server
    case channel(String)
    case privateMessage(String)
}
