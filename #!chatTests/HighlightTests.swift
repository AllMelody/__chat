import XCTest
@testable import __chat

@MainActor
final class HighlightTests: XCTestCase {
    // MARK: - Positive matches

    func testAddressedMention() {
        XCTAssertTrue(Formatting.mentionsNick("AllMelody", in: "AllMelody: did you see the log?"))
    }

    func testMidSentenceMention() {
        XCTAssertTrue(Formatting.mentionsNick("AllMelody", in: "I think AllMelody knows the answer"))
    }

    func testCaseInsensitiveMention() {
        XCTAssertTrue(Formatting.mentionsNick("AllMelody", in: "hey allmelody!"))
        XCTAssertTrue(Formatting.mentionsNick("allmelody", in: "HEY ALLMELODY"))
    }

    func testMentionAtEndOfLine() {
        XCTAssertTrue(Formatting.mentionsNick("AllMelody", in: "ping AllMelody"))
    }

    func testMentionSurroundedByPunctuation() {
        XCTAssertTrue(Formatting.mentionsNick("AllMelody", in: "(AllMelody)"))
        XCTAssertTrue(Formatting.mentionsNick("AllMelody", in: "@AllMelody sure"))
        XCTAssertTrue(Formatting.mentionsNick("AllMelody", in: "AllMelody, ping"))
    }

    func testNickWithIRCSpecialCharacters() {
        XCTAssertTrue(Formatting.mentionsNick("[Mel]", in: "yo [Mel] check this out"))
        XCTAssertTrue(Formatting.mentionsNick("Mel|away", in: "Mel|away: welcome back"))
    }

    func testLaterOccurrenceStillMatches() {
        // First candidate ("AllMelodyFan") fails the boundary check; the scan must keep
        // going and find the real standalone mention afterwards.
        XCTAssertTrue(Formatting.mentionsNick("AllMelody", in: "AllMelodyFan and AllMelody are different"))
    }

    // MARK: - Negative matches

    func testSubstringOfLongerWordDoesNotMatch() {
        XCTAssertFalse(Formatting.mentionsNick("AllMelody", in: "AllMelodyFan joined the channel"))
    }

    func testNickCharSuffixIsDifferentNick() {
        // AllMelody_ is somebody else (underscore is a valid nick character).
        XCTAssertFalse(Formatting.mentionsNick("AllMelody", in: "AllMelody_: hello"))
    }

    func testNickCharPrefixIsDifferentNick() {
        XCTAssertFalse(Formatting.mentionsNick("AllMelody", in: "_AllMelody says hi"))
        XCTAssertFalse(Formatting.mentionsNick("Mel", in: "[Mel] is not Mel"))
    }

    func testNoMentionAtAll() {
        XCTAssertFalse(Formatting.mentionsNick("AllMelody", in: "nothing to see here"))
    }

    func testEmptyInputs() {
        XCTAssertFalse(Formatting.mentionsNick("", in: "anything"))
        XCTAssertFalse(Formatting.mentionsNick("AllMelody", in: ""))
    }

    // MARK: - ChatMessage flag

    func testChatMessageDefaultsToNotHighlighted() {
        let msg = ChatMessage(time: Date(), text: "hi", senderNick: "someone", isPrivmsg: true)
        XCTAssertFalse(msg.isHighlight)
    }
}
