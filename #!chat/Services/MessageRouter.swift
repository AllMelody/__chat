import Foundation

final class MessageRouter {
    weak var delegate: MessageRouterDelegate?
    
    // MARK: - Slash Commands
    
    /// Result of parsing a composer input line. Pure data — no side effects — so it can be
    /// unit-tested independently of connections and view state.
    enum ParsedCommand: Equatable {
        case text(String)                       // non-slash plain message (may be empty)
        case join(channel: String, key: String?)
        case part(target: String?)              // nil = part the currently-selected channel
        case nick(String)
        case msg(target: String, message: String)
        case me(String)                         // an action: "/me waves" shows as "* nick waves"
        case quit
        case names
        case topic(String?)                     // nil = request the current topic
        case usage(String)                      // usage error; payload is the command name
        case unknown(String)                    // unrecognized command (empty = bare "/")
    }

    /// Pure parser: maps a raw composer line to a `ParsedCommand` with no side effects.
    static func parse(_ raw: String) -> ParsedCommand {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.hasPrefix("/") else { return .text(input) }

        let noSlash = String(input.dropFirst())
        var parts = noSlash.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard let cmd = parts.first?.lowercased() else { return .unknown("") }
        parts = Array(parts.dropFirst())

        switch cmd {
        case "join":
            guard let rawCh = parts.first else { return .usage("join") }
            let name = IRCName.isChannel(rawCh) ? rawCh : "#" + rawCh
            return .join(channel: name, key: parts.count >= 2 ? parts[1] : nil)
        case "part":
            return .part(target: parts.first)
        case "nick":
            guard let n = parts.first else { return .usage("nick") }
            return .nick(n)
        case "msg":
            guard parts.count >= 2 else { return .usage("msg") }
            return .msg(target: parts[0], message: parts[1])
        case "me":
            guard !parts.isEmpty else { return .usage("me") }
            return .me(parts.joined(separator: " "))
        case "quit":
            return .quit
        case "names":
            return .names
        case "topic":
            return .topic(parts.isEmpty ? nil : parts.joined(separator: " "))
        default:
            return .unknown(cmd)
        }
    }

    func handleInputFromComposer(_ text: String, selection: UUID?, servers: [IRCServer], connectionService: IRCConnectionService) {
        func serverForSelection(_ id: UUID?) -> IRCServer? {
            guard let id else { return nil }
            return servers.first { $0.id == id }
                ?? servers.first { s in
                    s.channels.contains { $0.id == id } || s.privateMessages.contains { $0.id == id }
                }
        }
        func channelForSelection(_ id: UUID?) -> (server: IRCServer, channel: IRCChannel)? {
            guard let id else { return nil }
            for s in servers {
                if let c = s.channels.first(where: { $0.id == id }) { return (s, c) }
            }
            return nil
        }
        /// Feedback line in the selected channel, or else in the selected server's log.
        func log(_ message: String) {
            let msg = ChatMessage(time: Date(), text: message)
            if let (_, c) = channelForSelection(selection) {
                c.log.append(msg)
            } else if let s = serverForSelection(selection) {
                s.log.append(msg)
            } else {
                return
            }
            delegate?.messageRouter(self, didAppendMessage: msg)
        }

        switch MessageRouter.parse(text) {
        case .text(let body):
            guard !body.isEmpty, let destination = Self.destination(for: selection, in: servers) else { return }
            connectionService.sendMessage(body, to: destination.target, from: destination.server)

        case .me(let action):
            guard let destination = Self.destination(for: selection, in: servers) else { return }
            if case .server = destination.target { log("Select a channel or private conversation to use /me."); return }
            connectionService.sendMessage(action, asAction: true, to: destination.target, from: destination.server)

        case .join(let name, let key):
            guard let s = serverForSelection(selection) else { log("Select a server to join a channel."); return }
            connectionService.joinChannel(name, key: key, on: s)

        case .part(let target):
            if let target {
                // Part a specific channel by name
                guard let s = serverForSelection(selection) else { log("No active server."); return }
                if let channel = s.channel(named: target) {
                    connectionService.partChannel(channel, from: s)
                } else {
                    log("Not in channel \(target)")
                }
            } else if let (server, ch) = channelForSelection(selection) {
                connectionService.partChannel(ch, from: server)
            } else { log("Select a channel to part.") }

        case .nick(let newNickRaw):
            guard let s = serverForSelection(selection) else { log("No active server."); return }
            guard let client = connectionService.clients[s.id], connectionService.isRegistered(s.id) else { log("Not connected."); return }
            if IRCName.isValidNickname(newNickRaw) {
                client.send(.nick(newNickRaw))
                // Don't update currentNick optimistically - wait for server confirmation
                log("Attempting to change nick to \(newNickRaw)...")
            } else { log("Invalid nickname.") }

        case .msg(let target, let message):
            guard let s = serverForSelection(selection) else { log("No active server."); return }
            // Use the proper send flow which handles logging, error handling, and PM conversation creation
            connectionService.sendMessageToTarget(message, targetName: target, from: s)

        case .quit:
            if let s = serverForSelection(selection) { connectionService.disconnect(s) } else { log("No active server.") }

        case .names:
            guard let (s, ch) = channelForSelection(selection) else { log("Select a channel to list names."); return }
            guard let client = connectionService.clients[s.id], connectionService.isRegistered(s.id) else { log("Not connected."); return }
            client.send(.names(ch.name))

        case .topic(let newTopic):
            guard let (s, ch) = channelForSelection(selection) else { log("Select a channel to set or view the topic."); return }
            guard let client = connectionService.clients[s.id], connectionService.isRegistered(s.id) else { log("Not connected."); return }
            // With no new topic, this asks the server for the current one.
            client.send(.topic(ch.name, newTopic))

        case .usage(let cmd):
            switch cmd {
            case "join": log("Usage: /join #channel [key]")
            case "nick": log("Usage: /nick newnickname")
            case "msg":  log("Usage: /msg <target> <message>")
            case "me":   log("Usage: /me <action>")
            default:     log("Usage: /\(cmd)")
            }

        case .unknown(let cmd):
            if !cmd.isEmpty { log("Unknown command: /\(cmd)") }
        }
    }
    
    /// Where text typed with `selection` selected goes: a channel, a private conversation,
    /// or the server log, along with the server it belongs to.
    private static func destination(for selection: UUID?, in servers: [IRCServer]) -> (server: IRCServer, target: MessageTarget)? {
        guard let id = selection else { return nil }
        for s in servers {
            if let ch = s.channels.first(where: { $0.id == id }) { return (s, .channel(ch)) }
            if let pm = s.privateMessages.first(where: { $0.id == id }) { return (s, .privateMessage(pm)) }
            if s.id == id { return (s, .server) }
        }
        return nil
    }
}

protocol MessageRouterDelegate: AnyObject {
    func messageRouter(_ router: MessageRouter, didAppendMessage message: ChatMessage)
}