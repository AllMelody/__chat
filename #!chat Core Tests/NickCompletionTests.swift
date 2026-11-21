import Foundation
import Testing
@testable import __chat

struct NickCompletionTests {
    @Test(arguments: [
        ("al", 2, NSRange(location: 0, length: 2)),
        ("hey al", 6, NSRange(location: 4, length: 2)),
        ("hey al and bob", 6, NSRange(location: 4, length: 2)),   // cursor in the middle of the line
        ("one\nal", 6, NSRange(location: 4, length: 2)),          // after a pasted line break
        ("👋 al", 5, NSRange(location: 3, length: 2)),            // offsets count UTF-16 units
    ])
    func `The word before the cursor is what gets completed`(text: String, cursor: Int, word: NSRange) {
        #expect(NickCompletion.partialWord(in: text, endingAt: cursor) == word)
    }

    @Test(arguments: [("hey ", 4), ("", 0), ("hey", 7)])
    func `Without a word before the cursor there's nothing to complete`(text: String, cursor: Int) {
        #expect(NickCompletion.partialWord(in: text, endingAt: cursor) == nil)
    }

    @Test func `Matches ignore case and keep the order offered`() {
        #expect(NickCompletion.matches(for: "AL", among: ["bob", "alice", "Alfred", "carol"]) == ["alice", "Alfred"])
        #expect(NickCompletion.matches(for: "z", among: ["bob", "alice"]) == [])
    }

    @Test func `A nick that opens the line addresses someone`() {
        #expect(NickCompletion.insertion(for: "alice", atStartOfLine: true) == "alice: ")
        #expect(NickCompletion.insertion(for: "alice", atStartOfLine: false) == "alice ")
    }

    @Test func `Recent speakers come first, then the other members, never us`() {
        func said(_ nick: String, fromMe: Bool = false) -> ChatMessage {
            ChatMessage(time: Date(), text: "hi", senderNick: nick, isPrivmsg: true, isFromMe: fromMe)
        }
        let log = [
            said("carol"),
            said("BOB"),                                    // spelled as the member list has it
            said("me", fromMe: true),
            ChatMessage(time: Date(), text: "dave joined"), // a status line is nobody speaking
            said("gone"),                                   // has left since
            said("carol"),
        ]
        let candidates = NickCompletion.candidates(members: ["alice", "bob", "carol", "dave", "me"], log: log, ownNick: "Me")
        #expect(candidates == ["carol", "bob", "alice", "dave"])
    }
}
