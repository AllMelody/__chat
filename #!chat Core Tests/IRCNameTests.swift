import Testing
@testable import __chat

struct IRCNameTests {
    @Test(arguments: [
        "alice",
        "Bob123",
        "ni_ck",       // '_' is a special character
        "nick-name",   // '-' is allowed after the first character
        "[nick]",      // so are []\`^{|}
        "`a^b{c}|d\\",
        "7guest",      // servers decide whether a leading digit is fine
        "Q",           // single-character nicks exist (QuakeNet's Q)
        "Ünïcödé",
    ])
    func `Valid nicknames`(name: String) {
        #expect(IRCName.isValidNickname(name))
    }

    @Test(arguments: [
        "",
        "has space",
        "nick!",
        "a@b",
        "-nick",       // '-' can't come first
        "#chan",
        "nick.name",
        "a,b",
        "a:b",
        "*status",
    ])
    func `Invalid nicknames`(name: String) {
        #expect(!IRCName.isValidNickname(name))
    }

    @Test(arguments: [
        ("Alice", "alice"),
        ("NICK[away]", "nick{away}"),   // RFC 1459: [ ] are uppercase { }
        ("a\\b", "A|B"),                // \ is uppercase |
        ("x^", "X~"),                   // ^ is uppercase ~
        ("#Swift", "#swift"),
    ])
    func `Equal under RFC 1459 case mapping`(a: String, b: String) {
        #expect(IRCName.equal(a, b))
    }

    @Test(arguments: [
        ("alice", "bob"),
        ("alice", "alice_"),
        ("É", "é"),                     // only ASCII folds
        ("", "a"),
    ])
    func `Different names`(a: String, b: String) {
        #expect(!IRCName.equal(a, b))
    }

    @Test(arguments: ["#swift", "&local", "+modeless", "!safe"])
    func `Channel names`(name: String) {
        #expect(IRCName.isChannel(name))
    }

    @Test(arguments: ["alice", "", "*", "@#ops"])
    func `Not channel names`(name: String) {
        #expect(!IRCName.isChannel(name))
    }
}
