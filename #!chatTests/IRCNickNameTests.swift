import XCTest
@testable import __chat

@MainActor
final class IRCNickNameTests: XCTestCase {
    func testValidNicks() {
        XCTAssertNotNil(IRCNickName("alice"))
        XCTAssertNotNil(IRCNickName("Bob123"))
        XCTAssertNotNil(IRCNickName("ni_ck"))      // '_' is an allowed special char
        XCTAssertNotNil(IRCNickName("nick-name"))  // '-' allowed as an inner char
        XCTAssertNotNil(IRCNickName("[nick]"))     // '[' and ']' are allowed special chars
        XCTAssertNotNil(IRCNickName("7guest"))     // leading digit allowed by default flags
    }

    func testInvalidNicks() {
        XCTAssertNil(IRCNickName(""))           // empty
        XCTAssertNil(IRCNickName("a"))          // too short (needs count > 1)
        XCTAssertNil(IRCNickName("has space"))  // space not allowed
        XCTAssertNil(IRCNickName("nick!"))      // '!' not allowed
        XCTAssertNil(IRCNickName("a@b"))        // '@' not allowed
    }

    func testStrictLengthLimit() {
        let long = String(repeating: "a", count: 10) // 10 > strict max of 9
        XCTAssertNil(IRCNickName(long, validationFlags: [.strictLengthLimit]))
        XCTAssertNotNil(IRCNickName(long))            // default allows up to 1024
    }

    func testLeadingDigitRejectedWhenDisallowed() {
        // Without .allowStartingDigit, a leading digit is invalid (and length must still be > 1).
        XCTAssertNil(IRCNickName("7guest", validationFlags: [.strictLengthLimit]))
        XCTAssertNotNil(IRCNickName("guest7", validationFlags: [.strictLengthLimit]))
    }

    func testCaseInsensitiveEquality() {
        XCTAssertEqual(IRCNickName("Alice"), IRCNickName("alice"))
        XCTAssertNotEqual(IRCNickName("alice"), IRCNickName("bob"))
    }
}
