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
            let name = rawCh.hasPrefix("#") ? rawCh : "#" + rawCh
            return .join(channel: name, key: parts.count >= 2 ? parts[1] : nil)
        case "part":
            return .part(target: parts.first)
        case "nick":
            guard let n = parts.first else { return .usage("nick") }
            return .nick(n)
        case "msg":
            guard parts.count >= 2 else { return .usage("msg") }
            return .msg(target: parts[0], message: parts[1])
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
            if let id {
                if let s = servers.first(where: { $0.id == id }) { return s }
                for s in servers {
                    if s.channels.contains(where: { $0.id == id }) ||
                       s.privateMessages.contains(where: { $0.id == id }) { return s }
                }
            }
            return nil
        }
        func channelForSelection(_ id: UUID?) -> (server: IRCServer, channel: IRCChannel)? {
            guard let id else { return nil }
            for s in servers { if let c = s.channels.first(where: { $0.id == id }) { return (s, c) } }
            return nil
        }
        func log(_ message: String) {
            if let (_, c) = channelForSelection(selection) {
                let msg = ChatMessage(time: Date(), text: message)
                c.log.append(msg)
                delegate?.messageRouter(self, didAppendMessage: msg)
            }
            else if let s = serverForSelection(selection) {
                let msg = ChatMessage(time: Date(), text: message)
                s.log.append(msg)
                delegate?.messageRouter(self, didAppendMessage: msg)
            }
        }

        switch MessageRouter.parse(text) {
        case .text(let body):
            guard !body.isEmpty else { return }
            sendMessageToSelection(body, selection: selection, servers: servers, connectionService: connectionService)

        case .join(let name, let key):
            guard let s = serverForSelection(selection) else { log("Select a server to join a channel."); return }
            connectionService.joinChannel(name, key: key, on: s)

        case .part(let target):
            if let target {
                // Part a specific channel by name
                guard let s = serverForSelection(selection) else { log("No active server."); return }
                if let channel = s.channels.first(where: { $0.name.lowercased() == target.lowercased() }) {
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
            if let nn = IRCNickName(newNickRaw) {
                client.changeNick(nn)
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
            client.send(.otherCommand("NAMES", [ ch.name ]))

        case .topic(let newTopic):
            guard let (s, ch) = channelForSelection(selection) else { log("Select a channel to set or view the topic."); return }
            guard let client = connectionService.clients[s.id], connectionService.isRegistered(s.id) else { log("Not connected."); return }
            if let newTopic {
                client.send(.otherCommand("TOPIC", [ch.name, newTopic]))
            } else {
                // /topic with no args — request current topic from server
                client.send(.otherCommand("TOPIC", [ch.name]))
            }

        case .usage(let cmd):
            switch cmd {
            case "join": log("Usage: /join #channel [key]")
            case "nick": log("Usage: /nick newnickname")
            case "msg":  log("Usage: /msg <target> <message>")
            default:     log("Usage: /\(cmd)")
            }

        case .unknown(let cmd):
            if !cmd.isEmpty { log("Unknown command: /\(cmd)") }
        }
    }
    
    private func sendMessageToSelection(_ text: String, selection: UUID?, servers: [IRCServer], connectionService: IRCConnectionService) {
        guard let id = selection else { return }
        
        for s in servers {
            // Handle channel messages
            if let ch = s.channels.first(where: { $0.id == id }) {
                connectionService.sendMessage(text, to: .channel(ch), from: s)
                return
            }
            // Handle private messages
            if let pm = s.privateMessages.first(where: { $0.id == id }) {
                connectionService.sendMessage(text, to: .privateMessage(pm), from: s)
                return
            }
            // Handle server messages
            if s.id == id {
                connectionService.sendMessage(text, to: .server, from: s)
                return
            }
        }
    }
}

protocol MessageRouterDelegate: AnyObject {
    func messageRouter(_ router: MessageRouter, didAppendMessage message: ChatMessage)
}