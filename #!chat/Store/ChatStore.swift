import AppKit
import Foundation
import Observation

@Observable
final class ChatStore {
    // Services
    private let connectionService = IRCConnectionService()
    private let imageCache = ImageCacheService()
    private let keychain = KeychainService()
    private let notificationService = NotificationService()

    // Core data
    var servers: [IRCServer] = [] { didSet { persistServers() } }

    // Selection (server or channel id)
    var selectedNodeID: UUID?

    // Thumbnail data - stored here so @Observable triggers view updates
    var messageThumbnails: [UUID: [MessageThumbnail]] = [:]

    // Bumped on every log mutation to guarantee view invalidation.
    // Works as a safety net when @Observable tracking breaks after sleep/wake.
    var logVersion: Int = 0
    
    // UI state
    var isPresentingAddServer: Bool = false
    var isPresentingEditServer: Bool = false
    var isPresentingJoinChannel: Bool = false
    var pendingJoinServerID: UUID?
    var pendingEditServerID: UUID?
    var isPresentingDeleteServer: Bool = false
    var pendingDeleteServerID: UUID?
    var isPresentingTopicEditor: Bool = false
    
    // Preferences
    weak var preferences: AppPreferences? { didSet { mirrorPreferencesToServices() } }
    @ObservationIgnored private var preferencesMirrorTask: Task<Void, Never>?
    
    init() {
        setupServices()
        loadServers()
        // Delay auto-connect to ensure UI is ready
        Task { [weak self] in
            // This task is never cancelled, so the sleep cannot throw.
            try! await Task.sleep(for: .milliseconds(100))
            self?.autoConnectFlaggedServers()
        }
    }
    
    private func setupServices() {
        connectionService.onEvent = { [weak self] event, server in
            self?.handle(event, on: server)
        }
        connectionService.onNetworkAvailable = { [weak self] in
            self?.reconnectAfterNetworkChange()
        }
        connectionService.configureServerLookup { [weak self] serverID in
            self?.servers.first { $0.id == serverID }
        }
        imageCache.onThumbnailUpdated = { [weak self] messageID, thumbnails in
            self?.messageThumbnails[messageID] = thumbnails
        }
        notificationService.onSelectNode = { [weak self] nodeID in
            guard let self, let item = self.sidebarItems.first(where: { $0.id == nodeID }) else { return }
            self.select(item)
        }
    }

    // MARK: - Highlight Notifications

    /// Posts a macOS notification for a nick mention, unless the user is plainly already
    /// looking at the conversation (app active + conversation selected) or the message is
    /// old backlog replayed on reconnect (ZNC playback carries server-time) rather than
    /// live traffic.
    private func notifyHighlight(for message: ChatMessage, conversation: String, serverName: String, nodeID: UUID) {
        guard Date().timeIntervalSince(message.time) < 60 else { return }
        if NSApp.isActive && selectedNodeID == nodeID { return }
        let sender = message.senderNick ?? "Someone"
        notificationService.postHighlight(
            sender: sender,
            text: message.isAction ? "* \(sender) \(message.text)" : message.text,
            conversation: conversation,
            serverName: serverName,
            nodeID: nodeID
        )
    }

    /// Keeps preference values that backing services mirror (currently the raw-traffic debug
    /// log) in sync. Observations emits the current value first, then every change.
    private func mirrorPreferencesToServices() {
        preferencesMirrorTask?.cancel()
        guard let preferences else { return }
        let debugRawServerLog = Observations { [weak preferences] in
            preferences?.debugRawServerLog ?? false
        }
        preferencesMirrorTask = Task { [weak self] in
            for await value in debugRawServerLog {
                self?.connectionService.debugRawServerLog = value
            }
        }
    }
    
    // MARK: - Thumbnails

    private func scanMessageForThumbnails(_ message: ChatMessage) {
        imageCache.scanMessageForThumbnails(message, showImageThumbnails: preferences?.showImageThumbnails ?? false)
    }
    
    // MARK: - Connection Management
    
    /// Connects at the user's request (or for auto-connect on launch), which also makes the
    /// server eligible for automatic reconnects, starting from a fresh set of attempts.
    func connect(_ server: IRCServer) {
        server.shouldAutoReconnect = true
        connectionService.resetReconnectionAttempts(for: server)
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

    func closePrivateMessage(_ pm: IRCPrivateMessage, from server: IRCServer) {
        discardThumbnails(for: pm.log)
        server.privateMessages.removeAll { $0.id == pm.id }
        server.log.append(ChatMessage(time: Date(), text: "Closed conversation with \(pm.nickname)"))
        noteLogsChanged()
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
    
    /// Asks the user to confirm before `deleteServer` runs: deleting can't be undone, and it
    /// also removes the server's password from the Keychain.
    func requestDeletion(of server: IRCServer) {
        pendingDeleteServerID = server.id
        isPresentingDeleteServer = true
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

    /// Every sidebar row in display order: each server followed by its channels and PMs.
    var sidebarItems: [SidebarItem] {
        servers.flatMap { s in
            [SidebarItem(server: s, kind: .server)] +
            s.channels.map { SidebarItem(server: s, kind: .channel($0)) } +
            s.privateMessages.map { SidebarItem(server: s, kind: .privateMessage($0)) }
        }
    }

    /// The selected sidebar row, unless what it showed has gone away.
    var selectedItem: SidebarItem? {
        guard let id = selectedNodeID else { return nil }
        return sidebarItems.first { $0.id == id }
    }

    /// Selects a sidebar row. Entering a conversation counts as reading it, so its
    /// unread badge clears.
    func select(_ item: SidebarItem) {
        selectedNodeID = item.id
        switch item.kind {
        case .channel(let channel): channel.unreadCount = 0
        case .privateMessage(let pm): pm.unreadCount = 0
        case .server: break
        }
    }

    /// Moves the sidebar selection by `offset` (wrapping).
    func navigateSidebar(by offset: Int) {
        let all = sidebarItems
        guard !all.isEmpty else { return }
        guard let currentID = selectedNodeID,
              let currentIndex = all.firstIndex(where: { $0.id == currentID }) else {
            selectedNodeID = all.first?.id
            return
        }
        select(all[(currentIndex + offset + all.count) % all.count])
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
        let cap = max(1, preferences?.maxLogLines ?? AppPreferences.defaultMaxLogLines)
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
        // Records are plain strings/ints/UUIDs, so encoding can't fail short of a programming error.
        let data = try! JSONEncoder().encode(servers.map { $0.toRecord() })
        UserDefaults.standard.set(data, forKey: serversPersistenceKey)
    }

    /// Writes the password to the Keychain, or deletes the entry if password is nil/empty.
    private func syncKeychain(password: String?, for id: UUID) throws(KeychainError) {
        if let password, !password.isEmpty {
            try keychain.save(password: password, for: id)
        } else {
            try keychain.delete(for: id)
        }
    }

    private func loadServers() {
        guard let data = UserDefaults.standard.data(forKey: serversPersistenceKey) else { return }
        // A list that won't decode is a bug to fix, not data to replace: crash rather than let
        // the `servers` didSet persist an empty list over the user's servers.
        let records = try! JSONDecoder().decode([IRCServerRecord].self, from: data)
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
    
    // MARK: - Connection Events

    /// Applies one event from the connection service to the model.
    private func handle(_ event: IRCConnectionService.Event, on server: IRCServer) {
        switch event {
        case .logAppended(let message):
            noteLogsChanged()
            if message.isPrivmsg {
                scanMessageForThumbnails(message)
            }
        case .messageReceived(let message, let target):
            receive(message, for: target, on: server)
        case .registered(let nick):
            serverDidRegister(server, as: nick)
        case .registrationFailed(let reason):
            serverFailedToRegister(server, reason: reason)
        case .disconnected(let reason):
            serverDidDisconnect(server, reason: reason)
        case .nicknameChanged(let nick):
            serverDidChangeNick(server, to: nick)
        case .errorReply(let subject, let text):
            showErrorReply(text, about: subject, on: server)
        case .joined(let channel, let nick, let isSelf):
            userJoined(nick, channel: channel, isSelf: isSelf, on: server)
        case .parted(let channel, let nick, let isSelf):
            userLeft(nick, channel: channel, isSelf: isSelf, on: server)
        case .kicked(let channel, let nick, let kicker, let reason, let isSelf):
            userKicked(nick, from: channel, by: kicker, reason: reason, isSelf: isSelf, on: server)
        case .nickChanged(let oldNick, let newNick):
            userChangedNick(from: oldNick, to: newNick, on: server)
        case .quit(let nick, let reason):
            userQuit(nick, reason: reason, on: server)
        case .topic(let channel, let topic, let setBy):
            topicChanged(to: topic, in: channel, by: setBy, on: server)
        case .names(let channelName, let nicks):
            server.channel(named: channelName)?.users = nicks
        }
    }

    private func reconnectAfterNetworkChange() {
        // Reconnect the servers that should auto-reconnect and are currently disconnected.
        // (Not .reconnectionFailed: running out of retries clears shouldAutoReconnect.)
        let disconnectedStates: [IRCServer.ConnectionStatus] = [.disconnected, .connectionTimeout]
        for server in servers {
            if server.shouldAutoReconnect && disconnectedStates.contains(server.connectionStatus) {
                server.log.append(ChatMessage(time: Date(), text: "Network available, reconnecting..."))
                noteLogsChanged()
                connect(server)
            }
        }
    }

    private func serverDidDisconnect(_ server: IRCServer, reason: String) {
        connectionService.cancelConnectionTimeout(for: server)

        server.connectionStatus = .connectionTimeout
        server.log.append(ChatMessage(time: Date(), text: "Connection to \(server.name) lost (\(reason))"))
        noteLogsChanged()

        if server.shouldAutoReconnect {
            connectionService.scheduleReconnection(for: server)
        }
    }

    private func serverDidRegister(_ server: IRCServer, as nick: String) {
        connectionService.cancelConnectionTimeout(for: server)
        server.connectionStatus = .connected
        server.currentNick = nick

        let statusText = server.displayAttempt > 0 ?
            "Reconnected as \(nick)" :
            "Registered as \(nick)"
        server.log.append(ChatMessage(time: Date(), text: statusText))
        noteLogsChanged()

        // Reconnection attempts reset only once the connection proves stable (its first PONG,
        // see IRCConnectionService), so a server that drops us right after the welcome can't
        // keep us redialing forever.
        server.shouldAutoReconnect = true

        for channel in server.channels {
            connectionService.joinChannel(channel.name, on: server)
        }

        connectionService.startPingMonitoring(for: server)
    }

    private func serverFailedToRegister(_ server: IRCServer, reason: String) {
        connectionService.cancelConnectionTimeout(for: server)

        server.log.append(ChatMessage(time: Date(), text: "Failed to register with server (\(reason))"))
        noteLogsChanged()

        if server.shouldAutoReconnect {
            connectionService.scheduleReconnection(for: server)
        }
    }

    /// Shows an error reply where the user will see it: in the conversation it's about, or else
    /// in the one they're looking at on that server, or else in the server log.
    private func showErrorReply(_ text: String, about subject: String?, on server: IRCServer) {
        var destination = SidebarItem(server: server, kind: .server)
        if let subject, let conversation = conversation(named: subject, on: server) {
            destination = conversation
        } else if let selected = selectedItem, selected.server.id == server.id {
            destination = selected
        }
        log("⚠️ " + (subject.map { "\($0): " } ?? "") + text, in: destination)
    }

    /// The sidebar row of the channel or private conversation called `name` on `server`.
    private func conversation(named name: String, on server: IRCServer) -> SidebarItem? {
        if let channel = server.channel(named: name) {
            return SidebarItem(server: server, kind: .channel(channel))
        }
        if let pm = server.privateMessage(with: name) {
            return SidebarItem(server: server, kind: .privateMessage(pm))
        }
        return nil
    }

    /// Adds a status line to the log a sidebar row shows.
    private func log(_ text: String, in item: SidebarItem) {
        let message = ChatMessage(time: Date(), text: text)
        switch item.kind {
        case .server: item.server.log.append(message)
        case .channel(let channel): channel.log.append(message)
        case .privateMessage(let pm): pm.log.append(message)
        }
        noteLogsChanged()
    }

    private func serverDidChangeNick(_ server: IRCServer, to nick: String) {
        // Our own entry in the member lists follows the rename too.
        if let oldNick = server.currentNick {
            for channel in server.channels {
                channel.updateUserNick(from: oldNick, to: nick)
            }
        }
        server.currentNick = nick
        server.log.append(ChatMessage(time: Date(), text: "You are now known as \(nick)"))
        noteLogsChanged()
    }

    private func receive(_ message: ChatMessage, for target: MessageTargetType, on server: IRCServer) {
        switch target {
        case .server:
            server.log.append(message)

        // Nothing to de-duplicate: lines this client sends never come back from the server
        // (see IRCConnectionService.sendSingleLine); isFromMe ones were sent from elsewhere.
        // Either way, our own lines never count as unread.
        case .channel(let name):
            let channel = server.getOrCreateChannel(named: name)
            channel.log.append(message)
            scanMessageForThumbnails(message)
            if message.isHighlight {
                notifyHighlight(for: message, conversation: channel.name, serverName: server.name, nodeID: channel.id)
            }

            if !message.isFromMe, selectedNodeID != channel.id {
                channel.unreadCount += 1
            }

        case .privateMessage(let senderNick):
            let pm = server.getOrCreatePrivateMessage(with: senderNick)
            pm.log.append(message)
            scanMessageForThumbnails(message)
            if message.isHighlight {
                notifyHighlight(for: message, conversation: "a private message", serverName: server.name, nodeID: pm.id)
            }

            if !message.isFromMe, selectedNodeID != pm.id {
                pm.unreadCount += 1
            }
        }
        noteLogsChanged()
    }

    private func userJoined(_ nick: String, channel: String, isSelf: Bool, on server: IRCServer) {
        guard isSelf else {
            server.channel(named: channel)?.addUserIfNotPresent(nick)
            return
        }
        // The member list follows in the NAMES reply the server sends with every join.
        let channelObj = server.getOrCreateChannel(named: channel)
        channelObj.joined = true
        let message = ChatMessage(time: Date(), text: "Joined \(channel)")
        channelObj.log.append(message)
        server.log.append(message)
        noteLogsChanged()
    }

    private func userLeft(_ nick: String, channel: String, isSelf: Bool, on server: IRCServer) {
        if isSelf {
            if let channelObj = server.channel(named: channel) {
                // Channel is removed below; release the thumbnail state its log was holding.
                discardThumbnails(for: channelObj.log)
            }
            server.channels.removeAll { IRCName.equal($0.name, channel) }
            server.log.append(ChatMessage(time: Date(), text: "Parted \(channel)"))
            noteLogsChanged()
        } else {
            server.channel(named: channel)?.removeUser(nick)
        }
    }

    private func userKicked(_ nick: String, from channel: String, by kicker: String?, reason: String?, isSelf: Bool, on server: IRCServer) {
        guard let channelObj = server.channel(named: channel) else { return }

        let details = (kicker.map { " by \($0)" } ?? "") + (reason.map { " (\($0))" } ?? "")
        if isSelf {
            // Keep the channel and its log so the user can read back and /join again.
            channelObj.joined = false
            channelObj.users.removeAll()
            let message = ChatMessage(time: Date(), text: "You were kicked from \(channel)\(details)")
            channelObj.log.append(message)
            server.log.append(message)
        } else {
            channelObj.removeUser(nick)
            channelObj.log.append(ChatMessage(time: Date(), text: "\(nick) was kicked\(details)"))
        }
        noteLogsChanged()
    }

    private func topicChanged(to topic: String, in channel: String, by nick: String?, on server: IRCServer) {
        guard let channelObj = server.channel(named: channel) else { return }

        channelObj.topic = topic.isEmpty ? nil : topic
        let logText = nick.map { "\($0) changed the topic to: \(topic)" } ?? "Topic: \(topic)"
        channelObj.log.append(ChatMessage(time: Date(), text: logText))
        noteLogsChanged()
    }

    private func userChangedNick(from oldNick: String, to newNick: String, on server: IRCServer) {
        let nickMessage = ChatMessage(time: Date(), text: "\(oldNick) is now known as \(newNick)")

        // Update nick in channels and log where the user is present
        for channel in server.channels {
            if channel.hasUser(oldNick) {
                channel.updateUserNick(from: oldNick, to: newNick)
                channel.log.append(nickMessage)
            }
        }

        // Update nick in PM conversations so messages go to the right target
        if let pm = server.privateMessage(with: oldNick) {
            pm.nickname = newNick
            pm.log.append(nickMessage)
        }

        server.log.append(nickMessage)
        noteLogsChanged()
    }

    private func userQuit(_ nick: String, reason: String?, on server: IRCServer) {
        let quitText = reason.map { " (\($0))" } ?? ""
        let logMessage = ChatMessage(time: Date(), text: "\(nick) has quit\(quitText)")

        for channel in server.channels {
            channel.removeUser(nick)
        }

        // Log quit in PM conversation so the user knows their DM partner left
        server.privateMessage(with: nick)?.log.append(logMessage)

        server.log.append(logMessage)
        noteLogsChanged()
    }
}

// MARK: - Composer Commands

extension ChatStore {
    /// Carries out a line typed into the composer: text goes to the selected conversation, and
    /// slash commands act on the selected server or channel. Runs through the same operations
    /// as the menus, so a `/part` or `/quit` tidies up the same way. Feedback shows up in the
    /// conversation the user is looking at.
    ///
    /// Returns false when a message couldn't be sent (when not connected, say), so the
    /// composer keeps it.
    func handleInputFromComposer(_ text: String) -> Bool {
        guard let selection = selectedItem else { return false }
        let server = selection.server
        let client = connectionService.isRegistered(server.id) ? connectionService.clients[server.id] : nil
        func feedback(_ text: String) { log(text, in: selection) }

        switch MessageRouter.parse(text) {
        case .text(let body):
            guard !body.isEmpty else { return true }
            return send(body, to: selection)

        case .me(let action):
            return send(action, asAction: true, to: selection)

        case .join(let name, let key):
            guard client != nil else { feedback("Not connected."); break }
            joinChannel(name, key: key, on: server)

        case .part(let name):
            if let name {
                guard let channel = server.channel(named: name) else { feedback("Not in \(name)."); break }
                partChannel(channel)
            } else if let channel = selection.channel {
                partChannel(channel)
            } else {
                feedback("Select a channel to part.")
            }

        case .nick(let nick):
            guard let client else { feedback("Not connected."); break }
            guard IRCName.isValidNickname(nick) else { feedback("Invalid nickname."); break }
            // The server confirms the change (or refuses it) in a reply.
            client.send(.nick(nick))
            feedback("Changing nick to \(nick)…")

        case .msg(let target, let message):
            guard client != nil else { feedback("Not connected."); return false }
            connectionService.sendMessageToTarget(message, targetName: target, from: server)

        case .quit:
            disconnect(server)

        case .names:
            guard let channel = selection.channel else { feedback("Select a channel to list names."); break }
            guard let client else { feedback("Not connected."); break }
            client.send(.names(channel.name))

        case .topic(let newTopic):
            guard let channel = selection.channel else { feedback("Select a channel to set or view the topic."); break }
            guard let client else { feedback("Not connected."); break }
            // With no new topic, this asks the server for the current one.
            client.send(.topic(channel.name, newTopic))

        case .usage(let command):
            switch command {
            case "join": feedback("Usage: /join <channel> [key]")
            case "nick": feedback("Usage: /nick <nickname>")
            case "msg":  feedback("Usage: /msg <target> <message>")
            case "me":   feedback("Usage: /me <action>")
            default:     feedback("Usage: /\(command)")
            }

        case .unknown(let command):
            if !command.isEmpty { feedback("Unknown command: /\(command)") }
        }
        return true
    }

    /// Sends a message (with `asAction`, a `/me`) to the selected conversation, or says why it
    /// can't go yet.
    private func send(_ text: String, asAction: Bool = false, to selection: SidebarItem) -> Bool {
        guard let target = selection.messageTarget else {
            log("Select a channel or private conversation first.", in: selection)
            return false
        }
        guard connectionService.isRegistered(selection.server.id) else {
            log("Not connected.", in: selection)
            return false
        }
        if let channel = selection.channel, !channel.joined {
            log("Not in \(channel.name).", in: selection)
            return false
        }
        connectionService.sendMessage(text, asAction: asAction, to: target, from: selection.server)
        return true
    }
}
