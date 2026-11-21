import Foundation
import Testing
@testable import __chat

struct HighlightTests {
    // MARK: - Positive matches

    @Test(arguments: [
        ("AllMelody", "AllMelody: did you see the log?"),   // addressed
        ("AllMelody", "I think AllMelody knows the answer"), // mid-sentence
        ("AllMelody", "hey allmelody!"),                    // case-insensitive
        ("allmelody", "HEY ALLMELODY"),
        ("AllMelody", "ping AllMelody"),                    // end of line
        ("AllMelody", "(AllMelody)"),                       // surrounded by punctuation
        ("AllMelody", "@AllMelody sure"),
        ("AllMelody", "AllMelody, ping"),
        ("[Mel]", "yo [Mel] check this out"),               // IRC special characters
        ("Mel|away", "Mel|away: welcome back"),
        // First candidate ("AllMelodyFan") fails the boundary check; the scan must keep
        // going and find the real standalone mention afterwards.
        ("AllMelody", "AllMelodyFan and AllMelody are different"),
    ])
    func `Standalone mentions of the nick`(nick: String, text: String) {
        #expect(Formatting.mentionsNick(nick, in: text))
    }

    // MARK: - Negative matches

    @Test(arguments: [
        ("AllMelody", "AllMelodyFan joined the channel"), // substring of a longer word
        ("AllMelody", "AllMelody_: hello"),               // '_' suffix: somebody else
        ("AllMelody", "_AllMelody says hi"),              // nick-char prefix
        ("Mel", "[Mel] is someone else"),                 // '[' ']' are nick chars: a different nick
        ("AllMelody", "nothing to see here"),
        ("", "anything"),                                 // empty inputs
        ("AllMelody", ""),
    ])
    func `Near misses are not mentions`(nick: String, text: String) {
        #expect(!Formatting.mentionsNick(nick, in: text))
    }

    // MARK: - ChatMessage flag

    @Test func `Chat message defaults to not highlighted`() {
        let msg = ChatMessage(time: Date(), text: "hi", senderNick: "someone", isPrivmsg: true)
        #expect(!msg.isHighlight)
    }
}
