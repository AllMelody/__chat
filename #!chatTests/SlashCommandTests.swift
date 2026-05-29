import XCTest
@testable import __chat

@MainActor
final class SlashCommandTests: XCTestCase {
    func testPlainTextIsText() {
        XCTAssertEqual(MessageRouter.parse("hello"), .text("hello"))
    }

    func testJoinAddsHash() {
        XCTAssertEqual(MessageRouter.parse("/join swift"), .join(channel: "#swift", key: nil))
    }

    func testJoinKeepsHashAndKey() {
        XCTAssertEqual(MessageRouter.parse("/join #swift hunter2"), .join(channel: "#swift", key: "hunter2"))
    }

    func testJoinWithoutArgsIsUsage() {
        XCTAssertEqual(MessageRouter.parse("/join"), .usage("join"))
    }

    func testMsgSplitsTargetAndMessage() {
        XCTAssertEqual(MessageRouter.parse("/msg alice hello there world"),
                       .msg(target: "alice", message: "hello there world"))
    }

    func testMsgRequiresMessage() {
        XCTAssertEqual(MessageRouter.parse("/msg alice"), .usage("msg"))
    }

    func testPartTargetOptional() {
        XCTAssertEqual(MessageRouter.parse("/part"), .part(target: nil))
        XCTAssertEqual(MessageRouter.parse("/part #foo"), .part(target: "#foo"))
    }

    func testTopicNoArgsRequestsCurrent() {
        XCTAssertEqual(MessageRouter.parse("/topic"), .topic(nil))
    }

    func testTopicWithArgsJoinsRemainder() {
        XCTAssertEqual(MessageRouter.parse("/topic new topic here"), .topic("new topic here"))
    }

    func testCaseInsensitiveCommand() {
        XCTAssertEqual(MessageRouter.parse("/QUIT"), .quit)
    }

    func testUnknownCommand() {
        XCTAssertEqual(MessageRouter.parse("/wat"), .unknown("wat"))
    }

    func testBareSlashIsEmptyUnknown() {
        XCTAssertEqual(MessageRouter.parse("/"), .unknown(""))
    }
}
