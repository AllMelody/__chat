import Foundation
import Testing
@testable import __chat

struct IRCServerRecordTests {
    @Test func decodesLegacyPasswordAndMissingOptionals() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"n","host":"h","port":6697,"password":"secret"}"#
        let record = try JSONDecoder().decode(IRCServerRecord.self, from: Data(json.utf8))
        #expect(record.password == "secret")
        #expect(record.useTLS == nil)
        #expect(record.nickname == nil)
    }

    @Test func encodingOmitsPassword() throws {
        let record = IRCServerRecord(id: UUID(), name: "n", host: "h", port: 6697, password: "secret",
                                     useTLS: true, autoConnectOnLaunch: false, nickname: "me")
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        #expect(object["password"] == nil)
        #expect(object["nickname"] as? String == "me")
    }
}
