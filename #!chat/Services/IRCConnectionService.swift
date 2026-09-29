import AppKit
import Foundation
import NIO
import Network
import Synchronization

/// Threading contract: all mutable state on this type (clients, connectionTimers, pingTasks,
/// lastPongReceived, selfNicks, registeredServerIDs, messageQueue, queueTimer) and all IRCServer
/// model mutation MUST happen on the main thread. IRCClientDelegate callbacks arrive on the NIO
/// event loop (they're `nonisolated`) and forward a ClientEvent through an AsyncStream that is
/// drained in order on the main actor before touching any of it.
/// client.send(...) is safe to call from main (it re-enters the event loop internally). Never read
/// IRCClient.state from main — use registeredServerIDs instead.
final class IRCConnectionService: IRCClientDelegate, ReconnectionManagerDelegate {
    // Clients and connection state
    var clients: [UUID: IRCClient] = [:]
    var connectionTimers: [UUID: Timer] = [:]
    var pingTasks: [UUID: RepeatedTask] = [:]
    var lastPongReceived: [UUID: Date] = [:]
    private var selfNicks: [UUID: String] = [:]

    /// Server IDs for clients that have completed registration. Maintained ENTIRELY on the
    /// main thread: inserted in the `serverDidRegister` main hop, removed on every disconnect
    /// path. Lets `ChatStore.canSendMessage` gate sends WITHOUT reading IRCClient.state, which
    /// is owned by the NIO event loop (cross-thread read removed).
    private var registeredServerIDs: Set<UUID> = []

    // Message send queue (flood protection)
    private var messageQueue: [(text: String, target: MessageTarget, server: IRCServer)] = []
    private var queueTimer: Timer?
    private let burstLimit = 5
    private let queueInterval: TimeInterval = 0.5

    // Reconnection handling
    private let reconnectionManager = ReconnectionManager()

    // Network monitoring for immediate disconnect detection
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "io.github.AllMelody.__chat")

    // Default nick
    var defaultNick: String = "Guest\(Int.random(in: 1000...9999))"

    /// When true, every received IRC message is echoed to the server log as a "RECV:" line.
    /// Off by default; mirrored from AppPreferences at launch and when toggled.
    /// Written on main, read on the NIO event loop, so it's backed by an atomic.
    var debugRawServerLog: Bool {
        get { debugRawServerLogFlag.load(ordering: .relaxed) }
        set { debugRawServerLogFlag.store(newValue, ordering: .relaxed) }
    }
    private nonisolated let debugRawServerLogFlag = Atomic<Bool>(false)

    // Delegate for server updates
    weak var delegate: IRCConnectionServiceDelegate?

    // Server lookup for reconnection callbacks
    private var serverLookup: ((UUID) -> IRCServer?)?

    /// Configure the server lookup closure. Must be called before reconnection can work.
    func configureServerLookup(_ lookup: @escaping (UUID) -> IRCServer?) {
        self.serverLookup = lookup
    }

    private var sleepObserver: Any?
    private var wakeObserver: Any?

    init() {
        setupNetworkMonitoring()
        setupSleepWakeMonitoring()
        reconnectionManager.delegate = self
        startClientEventLoop()
    }

    deinit {
        clientEvents.continuation.finish()
        pathMonitor.cancel()
        if let obs = sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        if let obs = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        // Clean up all timers
        for timer in connectionTimers.values {
            timer.invalidate()
        }
        // Cancel all ping tasks
        for task in pingTasks.values {
            task.cancel()
        }
        queueTimer?.invalidate()
        // Reconnection manager cleans up in its own deinit
    }

    // MARK: - Sleep/Wake Monitoring

    private func setupSleepWakeMonitoring() {
        let center = NSWorkspace.shared.notificationCenter

        sleepObserver = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleSleep()
        }

        wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
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
    /// loss): cancel reconnection, ping monitoring and the connect-timeout timer, mark
    /// the model disconnected, close the client, and drop per-server bookkeeping.
    /// One shared checklist so the paths can't drift apart (network loss used to skip
    /// the timers, leaking a live connect-timeout that could double-schedule reconnects).
    private func tearDownConnection(for serverID: UUID) {
        reconnectionManager.cancelReconnection(for: serverID)
        pingTasks[serverID]?.cancel()
        pingTasks.removeValue(forKey: serverID)
        lastPongReceived.removeValue(forKey: serverID)
        connectionTimers[serverID]?.invalidate()
        connectionTimers.removeValue(forKey: serverID)

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
        selfNicks.removeValue(forKey: serverID)
        registeredServerIDs.remove(serverID)
    }

    private func clearMessageQueue() {
        queueTimer?.invalidate()
        queueTimer = nil
        messageQueue.removeAll()
    }

    private func handleWake() {
        // After waking, reconnect all servers that should auto-reconnect.
        delegate?.ircConnectionServiceNetworkDidBecomeAvailable(self)
    }

    // MARK: - Network Monitoring

    private var networkWasUnavailable = false

    private func setupNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            DispatchQueue.main.async {
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
        pathMonitor.start(queue: pathMonitorQueue)
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
        delegate?.ircConnectionServiceNetworkDidBecomeAvailable(self)
    }

    // MARK: - Connection Management
    
    func connect(_ server: IRCServer) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard server.connectionStatus != .connecting && server.connectionStatus != .connected else {
            return
        }
        
        server.connectionStatus = .connecting
        
        let statusText = server.displayAttempt > 0 ?
            "Reconnecting to \(server.name) (attempt \(server.displayAttempt + 1)/\(ReconnectionManager.Policy.default.maxAttempts))" :
            "Connecting to \(server.name) (\(server.host):\(server.port))"
        logToServer(statusText, on: server)

        // Per-server nick: explicit server nickname, else last-known currentNick, else the app
        // default, else "Guest". First candidate that is a valid IRCNickName wins.
        let nick = [server.nickname, server.currentNick, defaultNick, "Guest"]
            .lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { IRCNickName($0) }
            .first ?? IRCNickName("Guest")!
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
        client.serverID = server.id
        clients[server.id] = client
        
        // Set up connection timeout
        setupConnectionTimeout(for: server)
        
        client.connect()
    }

    func disconnect(_ server: IRCServer) {
        dispatchPrecondition(condition: .onQueue(.main))
        logToServer("Disconnecting from \(server.name)…", on: server)
        
        // Cancel any timers
        cancelConnectionTimeout(for: server)
        cancelReconnectionTimer(for: server)
        stopPingMonitoring(for: server)
        
        if let c = clients.removeValue(forKey: server.id) { c.close() }
        selfNicks.removeValue(forKey: server.id)
        registeredServerIDs.remove(server.id)
        messageQueue.removeAll { $0.server.id == server.id }
        if messageQueue.isEmpty { queueTimer?.invalidate(); queueTimer = nil }
        server.channels.removeAll()
        server.connectionStatus = .disconnected
        server.displayAttempt = 0
        server.shouldAutoReconnect = false
        
        logToServer("Disconnected from \(server.name)", on: server)
    }
    
    private func setupConnectionTimeout(for server: IRCServer) {
        cancelConnectionTimeout(for: server)
        
        let timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleConnectionTimeout(for: server)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
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
            logToServer("Connection to \(server.name) timed out", on: server)
        }

        server.connectionStatus = .connectionTimeout

        // Close the client connection if it exists
        if let client = clients.removeValue(forKey: server.id) {
            client.close()
        }
        registeredServerIDs.remove(server.id)

        // Attempt reconnection if enabled
        if server.shouldAutoReconnect {
            scheduleReconnection(for: server)
        }
    }
    
    func scheduleReconnection(for server: IRCServer) {
        reconnectionManager.scheduleReconnection(for: server.id, policy: .default)
    }

    func cancelReconnectionTimer(for server: IRCServer) {
        reconnectionManager.cancelReconnection(for: server.id)
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
        dispatchPrecondition(condition: .onQueue(.main))
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
        dispatchPrecondition(condition: .onQueue(.main))
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

        logToServer("Connection to \(server.name) lost", on: server)

        if let client = clients.removeValue(forKey: server.id) {
            client.close()
        }
        registeredServerIDs.remove(server.id)

        stopPingMonitoring(for: server)
        
        if server.shouldAutoReconnect {
            scheduleReconnection(for: server)
        }
    }
    
    private func updateLastPongReceived(for serverID: UUID) {
        lastPongReceived[serverID] = Date()
    }
    
    // MARK: - Channel Operations
    
    func joinChannel(_ name: String, key: String? = nil, on server: IRCServer) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let client = clients[server.id] else {
            handleSendFailure(for: server, reason: "Cannot join channel: Not connected")
            return
        }

        guard isRegistered(server.id) else {
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
        dispatchPrecondition(condition: .onQueue(.main))
        guard let client = clients[server.id] else {
            handleSendFailure(for: server, reason: "Cannot part channel: Not connected")
            return
        }

        guard isRegistered(server.id) else {
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
        // "Parted X" is logged once, by ChatStore, when the server confirms the PART.
    }
    
    // MARK: - Topic

    func sendTopicChange(_ newTopic: String, for channelName: String, on server: IRCServer) {
        guard let client = clients[server.id], isRegistered(server.id) else { return }
        client.send(.otherCommand("TOPIC", [channelName, newTopic]))
    }

    // MARK: - Messaging

    /// Send a message to an arbitrary nick or channel (used by /msg command)
    /// Creates a PM conversation if needed
    func sendMessageToTarget(_ text: String, targetName: String, from server: IRCServer) {
        dispatchPrecondition(condition: .onQueue(.main))
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard clients[server.id] != nil else {
            handleSendFailure(for: server, reason: "Not connected")
            return
        }

        guard isRegistered(server.id) else {
            handleSendFailure(for: server, reason: "Not registered")
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
        dispatchPrecondition(condition: .onQueue(.main))
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
            enqueueLines(lines, to: target, from: server)
        }
    }

    private func sendSingleLine(_ text: String, to target: MessageTarget, from server: IRCServer) {
        guard let client = clients[server.id] else {
            handleSendFailure(for: server, target: target, reason: "Not connected")
            return
        }

        guard isRegistered(server.id) else {
            handleSendFailure(for: server, target: target, reason: "Not registered")
            handleConnectionDead(for: server)
            return
        }

        switch target {
        case .channel(let channel):
            // Echo locally so the user sees their message immediately. Servers that advertise
            // znc.in/self-message also echo it back; that echo is de-duplicated in ChatStore.
            let nick = server.currentNick ?? defaultNick
            let msg = ChatMessage(time: Date(), text: text, senderNick: nick, isPrivmsg: true, isFromMe: true)
            channel.log.append(msg)
            delegate?.ircConnectionService(self, didAppendMessage: msg, to: server)

            if let chName = IRCChannelName(channel.name) {
                sendWithFailureDetection(.PRIVMSG([ .channel(chName) ], text), to: client, server: server)
            } else {
                sendWithFailureDetection(.otherCommand("PRIVMSG", [ channel.name, text ]), to: client, server: server)
            }

        case .privateMessage(let pm):
            let nick = server.currentNick ?? defaultNick
            let msg = ChatMessage(time: Date(), text: text, senderNick: nick, isPrivmsg: true, isFromMe: true)
            pm.log.append(msg)
            delegate?.ircConnectionService(self, didAppendMessage: msg, to: server)

            sendWithFailureDetection(.otherCommand("PRIVMSG", [ pm.nickname, text ]), to: client, server: server)

        case .server:
            break
        }
    }

    private func enqueueLines(_ lines: [String], to target: MessageTarget, from server: IRCServer) {
        let immediateCount = messageQueue.isEmpty ? min(lines.count, burstLimit) : 0

        for line in lines.prefix(immediateCount) {
            sendSingleLine(line, to: target, from: server)
        }

        for line in lines.dropFirst(immediateCount) {
            messageQueue.append((text: line, target: target, server: server))
        }

        if !messageQueue.isEmpty && queueTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: queueInterval, repeats: true) { [weak self] _ in
                DispatchQueue.main.async { self?.drainQueue() }
            }
            RunLoop.main.add(timer, forMode: .common)
            queueTimer = timer
        }
    }

    private func drainQueue() {
        guard !messageQueue.isEmpty else {
            queueTimer?.invalidate()
            queueTimer = nil
            return
        }

        let item = messageQueue.removeFirst()
        sendSingleLine(item.text, to: item.target, from: item.server)

        if messageQueue.isEmpty {
            queueTimer?.invalidate()
            queueTimer = nil
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

    /// Appends a status line to the server log and notifies the delegate — the shared
    /// tail of every "something happened on this connection" message.
    private func logToServer(_ text: String, on server: IRCServer) {
        let msg = ChatMessage(time: Date(), text: text)
        server.log.append(msg)
        delegate?.ircConnectionService(self, didAppendMessage: msg, to: server)
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
        // O(1), but only resolves the CURRENT client for an id. A stale/old client — e.g. one
        // replaced by an auto-reconnect — returns nil, so its late event-loop callbacks cannot
        // clobber the live connection's state. This mirrors the original identity-scan semantics
        // (which returned nil once a client was no longer a value in `clients`).
        guard let id = client.serverID, clients[id] === client else { return nil }
        return id
    }

    /// Main-thread "is this connection registered?" query that avoids touching
    /// event-loop-owned IRCClient state.
    func isRegistered(_ serverID: UUID) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return registeredServerIDs.contains(serverID)
    }
    
    private nonisolated func formatIRCMessage(_ message: IRCMessage, direction: String) -> String {
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
    //
    // Delegate callbacks arrive on the NIO event loop. Each one does only the
    // Sendable-safe work it needs (parsing, formatting) and yields a ClientEvent
    // into `clientEvents`; a single main-actor task drains the stream in order
    // and applies the event in `handle(_:from:)`.

    /// Events forwarded from the NIO event loop to the main actor.
    private enum ClientEvent: Sendable {
        case disconnected
        case registered(nick: String)
        case failedToRegister
        case connectionStateChanged(IRCClient.ConnectionState)
        case serverLog(String, time: Date?)
        case changedNick(String)
        case message(String, from: IRCUserID, recipients: [IRCMessageRecipient], time: Date?)
        case joined(nick: String, channels: [String])
        case left(nick: String, channels: [String])
        case userChangedNick(from: String, to: String)
        case userQuit(nick: String, message: String?)
        case topicChanged(String, channel: String, by: String?)
        case pong
        case userList([String], channel: String)
        case whoReply(nick: String, channel: String)
    }

    private nonisolated let clientEvents = AsyncStream.makeStream(of: (IRCClient, ClientEvent).self)

    private nonisolated func post(_ event: ClientEvent, from client: IRCClient) {
        clientEvents.continuation.yield((client, event))
    }

    /// Drains `clientEvents` on the main actor. Started once from `init`.
    private func startClientEventLoop() {
        let events = clientEvents.stream
        Task { [weak self] in
            for await (client, event) in events {
                self?.handle(event, from: client)
            }
        }
    }

    private func handle(_ event: ClientEvent, from client: IRCClient) {
        guard let serverID = serverID(for: client) else { return }

        switch event {
        case .disconnected:
            // Update server state IMMEDIATELY before any cleanup.
            // This prevents race conditions where canSendMessage() might check
            // state between the async dispatch and cleanup completion.
            if let server = serverLookup?(serverID) {
                // Only update if we think we're still connected/connecting.
                // If already in a disconnect-related state, don't overwrite it.
                if server.connectionStatus == .connected || server.connectionStatus == .connecting {
                    server.connectionStatus = .disconnected
                }

                // Mark all channels as not joined
                for channel in server.channels {
                    channel.joined = false
                }
            }

            // Clean up all monitoring and timers for this server
            pingTasks[serverID]?.cancel()
            pingTasks.removeValue(forKey: serverID)
            lastPongReceived.removeValue(forKey: serverID)
            connectionTimers[serverID]?.invalidate()
            connectionTimers.removeValue(forKey: serverID)
            reconnectionManager.cancelReconnection(for: serverID)

            // Remove client reference
            clients.removeValue(forKey: serverID)
            selfNicks.removeValue(forKey: serverID)
            registeredServerIDs.remove(serverID)

            // Discard queued messages for this server
            messageQueue.removeAll { $0.server.id == serverID }
            if messageQueue.isEmpty { queueTimer?.invalidate(); queueTimer = nil }

            // Notify delegate so it can trigger reconnection if needed
            delegate?.ircConnectionService(self, serverDidDisconnect: serverID)

        case .registered(let nick):
            selfNicks[serverID] = nick
            registeredServerIDs.insert(serverID)
            delegate?.ircConnectionService(self, serverDidRegister: serverID, as: nick)

        case .failedToRegister:
            delegate?.ircConnectionService(self, serverFailedToRegister: serverID)

        case .connectionStateChanged(let state):
            delegate?.ircConnectionService(self, server: serverID, connectionStateChanged: state)

        case .serverLog(let text, let time):
            let m = ChatMessage(time: time ?? Date(), text: text)
            delegate?.ircConnectionService(self, didReceiveMessage: m, for: serverID, target: .server)

        case .changedNick(let nick):
            selfNicks[serverID] = nick
            delegate?.ircConnectionService(self, serverDidChangeNick: serverID, to: nick)

        case .message(let message, let user, let recipients, let serverTime):
            // Use server-time if available (for ZNC backlog), otherwise use current time
            let time = serverTime ?? Date()

            for r in recipients {
                if case .channel(let chName) = r {
                    let name = chName.stringValue
                    let selfNick = selfNicks[serverID]
                    let isMine = (selfNick != nil && user.nick.stringValue.compare(selfNick!, options: .caseInsensitive) == .orderedSame)
                    let isHighlight = !isMine && selfNick != nil && Formatting.mentionsNick(selfNick!, in: message)
                    let m = ChatMessage(time: time, text: message, senderNick: user.nick.stringValue, isPrivmsg: true, isFromMe: isMine, isHighlight: isHighlight)
                    delegate?.ircConnectionService(self, didReceiveMessage: m, for: serverID, target: .channel(name, isMine: isMine))
                } else if case .nickname(let targetNick) = r {
                    let selfNick = selfNicks[serverID] ?? ""
                    let senderIsSelf = user.nick.stringValue.compare(selfNick, options: .caseInsensitive) == .orderedSame
                    let targetIsSelf = targetNick.stringValue.compare(selfNick, options: .caseInsensitive) == .orderedSame

                    if targetIsSelf {
                        // Incoming PM: someone else is messaging us
                        // Target window = sender's nick
                        let senderNick = user.nick.stringValue
                        let isHighlight = !selfNick.isEmpty && Formatting.mentionsNick(selfNick, in: message)
                        let m = ChatMessage(time: time, text: message, senderNick: senderNick, isPrivmsg: true, isFromMe: false, isHighlight: isHighlight)
                        delegate?.ircConnectionService(self, didReceiveMessage: m, for: serverID, target: .privateMessage(senderNick))
                    } else if senderIsSelf {
                        // Self-message: we sent this PM (from ZNC buffer playback)
                        // Target window = recipient's nick
                        let m = ChatMessage(time: time, text: message, senderNick: selfNick, isPrivmsg: true, isFromMe: true)
                        delegate?.ircConnectionService(self, didReceiveMessage: m, for: serverID, target: .privateMessage(targetNick.stringValue))
                    }
                }
            }

        case .joined(let nick, let channels):
            for name in channels {
                // IRC nicks are case-insensitive; servers/bouncers may echo ours with
                // different casing, so an exact == would misclassify our own JOIN.
                let isSelf = selfNicks[serverID]?.compare(nick, options: .caseInsensitive) == .orderedSame
                delegate?.ircConnectionService(self, user: nick, joinedChannel: name, on: serverID, isSelf: isSelf)

                if isSelf, let client = clients[serverID] {
                    client.send(.otherCommand("NAMES", [ name ]))
                    client.send(.otherCommand("WHO",   [ name ]))
                }
            }

        case .left(let nick, let channels):
            for name in channels {
                let isSelf = selfNicks[serverID]?.compare(nick, options: .caseInsensitive) == .orderedSame
                delegate?.ircConnectionService(self, user: nick, leftChannel: name, on: serverID, isSelf: isSelf)
            }

        case .userChangedNick(let oldNick, let newNick):
            delegate?.ircConnectionService(self, user: oldNick, changedNickTo: newNick, on: serverID)

        case .userQuit(let nick, let message):
            delegate?.ircConnectionService(self, userQuit: nick, on: serverID, message: message)

        case .topicChanged(let topic, let channel, let nick):
            delegate?.ircConnectionService(self, didReceiveTopicChange: topic, for: channel, on: serverID, changedBy: nick)

        case .pong:
            updateLastPongReceived(for: serverID)

        case .userList(let names, let channel):
            delegate?.ircConnectionService(self, didReceiveUserList: names, for: channel, on: serverID)

        case .whoReply(let nick, let channel):
            delegate?.ircConnectionService(self, didReceiveWhoReply: nick, for: channel, on: serverID)
        }
    }

    nonisolated func clientDidDisconnect(_ client: IRCClient) {
        post(.disconnected, from: client)
    }

    nonisolated func client(_ client: IRCClient, registered nick: IRCNickName, with userInfo: IRCUserInfo) {
        post(.registered(nick: nick.stringValue), from: client)
    }

    nonisolated func clientFailedToRegister(_ client: IRCClient) {
        post(.failedToRegister, from: client)
    }

    nonisolated func client(_ client: IRCClient, connectionStateChanged state: IRCClient.ConnectionState) {
        post(.connectionStateChanged(state), from: client)
    }

    nonisolated func client(_ client: IRCClient, messageOfTheDay: String) {
        post(.serverLog("MOTD:\n\(messageOfTheDay)", time: nil), from: client)
    }

    nonisolated func client(_ client: IRCClient, changedNickTo nick: IRCNickName) {
        post(.changedNick(nick.stringValue), from: client)
    }

    nonisolated func client(_ client: IRCClient, notice message: String, for recipients: [IRCMessageRecipient], serverTime: Date?) {
        // Use server-time if available (for ZNC backlog), otherwise use current time
        post(.serverLog("NOTICE: \(message)", time: serverTime), from: client)
    }

    nonisolated func client(_ client: IRCClient, message: String, from user: IRCUserID, for recipients: [IRCMessageRecipient], serverTime: Date?) {
        post(.message(message, from: user, recipients: recipients, time: serverTime), from: client)
    }

    nonisolated func client(_ client: IRCClient, user: IRCUserID, joined channels: [IRCChannelName]) {
        post(.joined(nick: user.nick.stringValue, channels: channels.map(\.stringValue)), from: client)
    }

    nonisolated func client(_ client: IRCClient, user: IRCUserID, left channels: [IRCChannelName], with msg: String?) {
        post(.left(nick: user.nick.stringValue, channels: channels.map(\.stringValue)), from: client)
    }

    nonisolated func client(_ client: IRCClient, user: IRCUserID, changedNickTo newNick: IRCNickName) {
        post(.userChangedNick(from: user.nick.stringValue, to: newNick.stringValue), from: client)
    }

    nonisolated func client(_ client: IRCClient, userQuit user: IRCUserID, message: String?) {
        post(.userQuit(nick: user.nick.stringValue, message: message), from: client)
    }

    nonisolated func client(_ client: IRCClient, changeTopic topic: String, of channel: IRCChannelName) {
        post(.topicChanged(topic, channel: channel.stringValue, by: nil), from: client)
    }

    nonisolated func client(_ client: IRCClient, received message: IRCMessage) {
        if debugRawServerLogFlag.load(ordering: .relaxed) {
            post(.serverLog(formatIRCMessage(message, direction: "RECV"), time: nil), from: client)
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
        case .PONG(_, _):
            post(.pong, from: client)
        case .CAP(let subcmd, let capIDs):
            post(.serverLog("CAP \(subcmd.rawValue): \(capIDs.joined(separator: " "))", time: nil), from: client)
        case .numeric(.replyNameReply, let args):
            guard !args.isEmpty else { return }
            let channelName = args.first(where: { $0.hasPrefix("#") }) ?? (args.count > 2 ? args[2] : "")
            let namesList = args.last ?? ""
            let rawNames = namesList.split(separator: " ").map { String($0) }
            let cleaned = rawNames.map { name -> String in
                guard let first = name.first, "@+~&%".contains(first) else { return name }
                return String(name.dropFirst())
            }
            post(.userList(cleaned, channel: channelName), from: client)
        case .otherCommand("TOPIC", let args):
            // Live topic change: :nick!user@host TOPIC #channel :new topic
            guard args.count >= 2 else { break }
            let channelName = args[0]
            let newTopic = args[1]
            let nick: String? = {
                guard let origin = message.origin else { return nil }
                // origin is "nick!user@host" — extract nick
                if let bang = origin.firstIndex(of: "!") {
                    return String(origin[origin.startIndex..<bang])
                }
                return origin
            }()
            post(.topicChanged(newTopic, channel: channelName, by: nick), from: client)
        case .numeric(.replyEndOfNames, _):
            break
        case .numeric(.replyWhoReply, let args):
            let channelName = args.first(where: { $0.hasPrefix("#") }) ?? (args.count > 1 ? args[1] : "")
            let nick = args.count > 5 ? args[5] : ""
            guard !channelName.isEmpty, !nick.isEmpty else { return }
            post(.whoReply(nick: nick, channel: channelName), from: client)
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
    func ircConnectionServiceNetworkDidBecomeAvailable(_ service: IRCConnectionService)
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
    func ircConnectionService(_ service: IRCConnectionService, didReceiveTopicChange topic: String, for channel: String, on serverID: UUID, changedBy nick: String?)
}
