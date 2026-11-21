import Testing
@testable import __chat

struct IRCChannelTests {
    @Test func `Members stay in the member list's order as they come, go and rename`() {
        let channel = IRCChannel(name: "#swift")
        channel.setUsers(["dave", "Bob", "alice10", "alice9", "carol"])
        #expect(channel.users == ["alice9", "alice10", "Bob", "carol", "dave"])   // case aside, numbers counting up

        channel.addUserIfNotPresent("Charlie")
        channel.addUserIfNotPresent("BOB")   // already here, however it's spelled
        #expect(channel.users == ["alice9", "alice10", "Bob", "carol", "Charlie", "dave"])

        channel.updateUserNick(from: "DAVE", to: "aaron")
        channel.removeUser("ALICE9")
        #expect(channel.users == ["aaron", "alice10", "Bob", "carol", "Charlie"])

        channel.updateUserNick(from: "nobody", to: "somebody")   // not here: nothing changes
        #expect(channel.users == ["aaron", "alice10", "Bob", "carol", "Charlie"])

        channel.removeAllUsers()
        #expect(channel.users.isEmpty)
    }

    private func line(_ text: String, fromMe: Bool = false, mentionsMe: Bool = false) -> ChatMessage {
        ChatMessage(time: .now, text: text, senderNick: fromMe ? "me" : "bob", isPrivmsg: true, isFromMe: fromMe, isHighlight: mentionsMe)
    }

    @Test func `What others say counts as unread, and mentions of us as mentions`() {
        let channel = IRCChannel(name: "#swift")
        channel.countUnread(line("hi"), isOnScreen: false)
        channel.countUnread(line("me: you there?", mentionsMe: true), isOnScreen: false)
        #expect(channel.unreadCount == 2)
        #expect(channel.mentionCount == 1)
    }

    @Test func `What arrives in front of the user is read already`() {
        let channel = IRCChannel(name: "#swift")
        channel.countUnread(line("me: look", mentionsMe: true), isOnScreen: true)
        #expect(channel.unreadCount == 0)
        #expect(channel.mentionCount == 0)
    }

    @Test func `A line of our own marks what came before it read, but not what comes after`() {
        let channel = IRCChannel(name: "#swift")
        channel.countUnread(line("me: ping", mentionsMe: true), isOnScreen: false)
        channel.countUnread(line("pong", fromMe: true), isOnScreen: false)   // said from another client
        #expect(channel.unreadCount == 0)
        #expect(channel.mentionCount == 0)

        channel.countUnread(line("me: thanks", mentionsMe: true), isOnScreen: false)
        #expect(channel.unreadCount == 1)
        #expect(channel.mentionCount == 1)
    }

    @Test func `In a private conversation too`() {
        let pm = IRCPrivateConversation(nickname: "bob")
        pm.countUnread(line("hey"), isOnScreen: false)
        pm.countUnread(line("hey"), isOnScreen: false)
        pm.countUnread(line("hi!", fromMe: true), isOnScreen: false)
        #expect(pm.unreadCount == 0)
        pm.countUnread(line("how are you?"), isOnScreen: false)
        #expect(pm.unreadCount == 1)
    }
}
