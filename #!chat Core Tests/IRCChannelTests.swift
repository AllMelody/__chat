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
}
