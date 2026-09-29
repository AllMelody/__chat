import Testing
@testable import __chat

struct IRCNickNameTests {
    @Test(arguments: [
        "alice",
        "Bob123",
        "ni_ck",     // '_' is an allowed special char
        "nick-name", // '-' allowed as an inner char
        "[nick]",    // '[' and ']' are allowed special chars
        "7guest",    // leading digit allowed by default flags
    ])
    func validNick(_ name: String) {
        #expect(IRCNickName(name) != nil)
    }

    @Test(arguments: [
        "",          // empty
        "a",         // too short (needs count > 1)
        "has space", // space not allowed
        "nick!",     // '!' not allowed
        "a@b",       // '@' not allowed
    ])
    func invalidNick(_ name: String) {
        #expect(IRCNickName(name) == nil)
    }

    @Test func `Strict length limit`() {
        let long = String(repeating: "a", count: 10) // 10 > strict max of 9
        #expect(IRCNickName(long, validationFlags: [.strictLengthLimit]) == nil)
        #expect(IRCNickName(long) != nil)            // default allows up to 1024
    }

    @Test func `Leading digit rejected when disallowed`() {
        // Without .allowStartingDigit, a leading digit is invalid (and length must still be > 1).
        #expect(IRCNickName("7guest", validationFlags: [.strictLengthLimit]) == nil)
        #expect(IRCNickName("guest7", validationFlags: [.strictLengthLimit]) != nil)
    }

    @Test func `Case-insensitive equality`() {
        #expect(IRCNickName("Alice") == IRCNickName("alice"))
        #expect(IRCNickName("alice") != IRCNickName("bob"))
    }
}
