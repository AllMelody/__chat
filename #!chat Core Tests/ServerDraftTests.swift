import Testing
@testable import __chat

struct ServerDraftTests {
    /// A draft that could be saved as it is.
    private func complete() -> ServerDraft {
        var draft = ServerDraft(server: nil)
        draft.name = "Libera"
        draft.host = "irc.libera.chat"
        return draft
    }

    @Test func `A new server starts out encrypted, on the usual TLS port`() {
        let draft = ServerDraft(server: nil)
        #expect(draft.useTLS)
        #expect(draft.port == "6697")
    }

    @Test func `Editing starts from the server's settings, port and all`() {
        let server = IRCServer(name: "n", host: "h", port: 6667, password: "pw", useTLS: false, useSASL: true, nickname: "me")
        let draft = ServerDraft(server: server)
        #expect(!draft.useTLS)
        #expect(draft.port == "6667")   // not swapped for having TLS off
        #expect(draft.password == "pw")
        #expect(draft.useSASL)
        #expect(draft.nickname == "me")
    }

    @Test func `Turning TLS off and on moves between the usual ports, but leaves others alone`() {
        var draft = ServerDraft(server: nil)
        draft.useTLS = false
        #expect(draft.port == "6667")
        draft.useTLS = true
        #expect(draft.port == "6697")
        draft.port = "7000"
        draft.useTLS = false
        #expect(draft.port == "7000")
    }

    @Test func `Needs a name, a host and a real port`() {
        #expect(complete().canSave)
        var draft = complete()
        draft.name = "  "
        #expect(!draft.canSave)
        draft = complete()
        draft.host = ""
        #expect(!draft.canSave)
        for port in ["0", "65536", "port", ""] {
            draft = complete()
            draft.port = port
            #expect(!draft.canSave, "port \(port)")
        }
    }

    @Test func `A nickname is optional, but has to be one`() {
        var draft = complete()
        draft.nickname = "all melody"   // no spaces in a nickname
        #expect(!draft.canSave)
        draft.nickname = "AllMelody"
        #expect(draft.canSave)
    }

    @Test func `SASL needs both a nickname and a password`() {
        var draft = complete()
        draft.useSASL = true
        #expect(!draft.canSave)
        draft.nickname = "me"
        #expect(!draft.canSave)
        draft.password = "secret"
        #expect(draft.canSave)
    }
}
