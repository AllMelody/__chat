import Foundation
import Testing
@testable import __chat

struct IRCServerRecordTests {
    @Test func `Decodes a legacy password and missing optionals`() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"n","host":"h","port":6697,"password":"secret"}"#
        let record = try JSONDecoder().decode(IRCServerRecord.self, from: Data(json.utf8))
        #expect(record.password == "secret")
        #expect(record.useTLS == nil)
        #expect(record.nickname == nil)
    }

    @Test func `Encoding omits the password`() throws {
        let record = IRCServerRecord(id: UUID(), name: "n", host: "h", port: 6697, password: "secret",
                                     useTLS: true, autoConnectOnLaunch: false, nickname: "me")
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        #expect(object["password"] == nil)
        #expect(object["nickname"] as? String == "me")
    }

    @Test func `The channels we were in and the SASL setting come back`() throws {
        let server = IRCServer(name: "n", host: "h", port: 6697, password: nil, useTLS: true, useSASL: true)
        server.getOrCreateChannel(named: "#swift").isSaved = true
        server.getOrCreateChannel(named: "#kicked").wasKicked = true   // never saved, or no longer
        _ = server.getOrCreateChannel(named: "#not-let-in")

        let restored = IRCServer(from: try JSONDecoder().decode(IRCServerRecord.self, from: JSONEncoder().encode(server.toRecord())))
        #expect(restored.useSASL)
        #expect(restored.channels.map(\.name) == ["#swift"])
        // They're listed to be joined, not joined yet.
        #expect(restored.channels.allSatisfy { $0.isSaved && !$0.joined })
    }

    @Test func `A server with no channels to rejoin saves no list`() throws {
        let server = IRCServer(name: "n", host: "h", port: 6697, password: nil)
        _ = server.getOrCreateChannel(named: "#not-let-in")
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(server.toRecord())) as? [String: Any])
        #expect(object["channels"] == nil)
        #expect(IRCServer(from: server.toRecord()).channels.isEmpty)
    }
}
