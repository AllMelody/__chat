import Testing
@testable import __chat

struct CanSendTests {
    private func server(connected: Bool) -> IRCServer {
        let server = IRCServer(name: "n", host: "h", port: 6697, password: nil)
        server.connectionStatus = connected ? .connected : .connecting
        return server
    }

    private func channel(on server: IRCServer, joined: Bool) -> SidebarItem {
        let channel = server.getOrCreateChannel(named: "#swift")
        channel.joined = joined
        return SidebarItem(server: server, kind: .channel(channel))
    }

    @Test func `Nothing typed, nothing to send`() {
        #expect(!channel(on: server(connected: true), joined: true).canSend(""))
    }

    @Test func `What people read waits for the connection, and in a channel for being in it`() {
        #expect(!channel(on: server(connected: false), joined: false).canSend("hi"))
        #expect(!channel(on: server(connected: true), joined: false).canSend("hi"))
        #expect(channel(on: server(connected: true), joined: true).canSend("hi"))
        #expect(!channel(on: server(connected: true), joined: false).canSend("/me waves"))
        #expect(!channel(on: server(connected: true), joined: false).canSend("//not a command"))
    }

    @Test func `A private conversation waits only for the connection`() {
        let connected = server(connected: true)
        let pm = SidebarItem(server: connected, kind: .privateConversation(connected.getOrCreatePrivateConversation(with: "bob")))
        #expect(pm.canSend("hi"))
        let offline = server(connected: false)
        let pmOffline = SidebarItem(server: offline, kind: .privateConversation(offline.getOrCreatePrivateConversation(with: "bob")))
        #expect(!pmOffline.canSend("hi"))
    }

    @Test func `A command can always go: it works offline, or says why not`() {
        let item = channel(on: server(connected: false), joined: false)
        for command in ["/join #a", "/query bob", "/quit", "/whois bob"] {
            #expect(item.canSend(command), "\(command)")
        }
    }

    @Test func `A server's log takes commands, never chat`() {
        let connected = server(connected: true)
        let log = SidebarItem(server: connected, kind: .server)
        #expect(!log.canSend("hello"))
        #expect(log.canSend("/join #a"))
    }
}
