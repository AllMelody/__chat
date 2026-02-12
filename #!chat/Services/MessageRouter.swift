import Foundation

final class MessageRouter {
    weak var delegate: MessageRouterDelegate?
    
    // MARK: - Slash Commands
    
    func handleInputFromComposer(_ text: String, selection: UUID?, servers: [IRCServer], connectionService: IRCConnectionService) {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        guard input.hasPrefix("/") else {
            return sendMessageToSelection(input, selection: selection, servers: servers, connectionService: connectionService)
        }

        let noSlash = String(input.dropFirst())
        var parts = noSlash.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard let cmd = parts.first?.lowercased() else { return }
        parts = Array(parts.dropFirst())

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

        switch cmd {
        case "join":
            guard let raw = parts.first else { log("Usage: /join #channel [key]"); return }
            var name = raw
            if !name.hasPrefix("#") { name = "#" + name }
            let key = parts.count >= 2 ? parts[1] : nil
            guard let s = serverForSelection(selection) else { log("Select a server to join a channel."); return }
            connectionService.joinChannel(name, key: key, on: s)

        case "part":
            if let target = parts.first {
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

        case "nick":
            guard let newNickRaw = parts.first else { log("Usage: /nick newnickname"); return }
            guard let s = serverForSelection(selection) else { log("No active server."); return }
            guard let client = connectionService.clients[s.id], client.canSend else { log("Not connected."); return }
            if let nn = IRCNickName(newNickRaw) {
                client.changeNick(nn)
                // Don't update currentNick optimistically - wait for server confirmation
                log("Attempting to change nick to \(newNickRaw)...")
            } else { log("Invalid nickname.") }

        case "msg":
            guard parts.count >= 2 else { log("Usage: /msg <target> <message>"); return }
            let target = parts[0]
            let message = parts[1]
            guard let s = serverForSelection(selection) else { log("No active server."); return }
            // Use the proper send flow which handles logging, error handling, and PM conversation creation
            connectionService.sendMessageToTarget(message, targetName: target, from: s)

        case "quit":
            if let s = serverForSelection(selection) { connectionService.disconnect(s) } else { log("No active server.") }

        case "names":
            guard let (s, ch) = channelForSelection(selection) else { log("Select a channel to list names."); return }
            guard let client = connectionService.clients[s.id], client.canSend else { log("Not connected."); return }
            client.send(.otherCommand("NAMES", [ ch.name ]))

        case "topic":
            guard let (s, ch) = channelForSelection(selection) else { log("Select a channel to set or view the topic."); return }
            guard let client = connectionService.clients[s.id], client.canSend else { log("Not connected."); return }
            if parts.isEmpty {
                // /topic with no args — request current topic from server
                client.send(.otherCommand("TOPIC", [ch.name]))
            } else {
                let newTopic = parts.joined(separator: " ")
                client.send(.otherCommand("TOPIC", [ch.name, newTopic]))
            }

        default:
            log("Unknown command: /\(cmd)")
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