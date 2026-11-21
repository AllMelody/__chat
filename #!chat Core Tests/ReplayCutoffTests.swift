import Foundation
import Testing
@testable import __chat

struct ReplayCutoffTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// Notes `times` as lines a registered connection brought.
    private func see(_ times: [TimeInterval], on cutoff: inout ReplayCutoff) {
        for time in times {
            let replay = cutoff.isReplay(at(time), isRegistered: true)
            #expect(!replay, "line at \(time) taken for a replay")
        }
    }

    @Test func `After a cold start, everything replayed is new`() {
        var cutoff = ReplayCutoff()
        cutoff.connectionRegistered()
        see([0, 10, 20], on: &cutoff)
    }

    @Test func `On reconnecting, what the last connection brought is a replay, and what came since isn't`() {
        var cutoff = ReplayCutoff()
        cutoff.connectionRegistered()
        see([0, 10, 20], on: &cutoff)

        cutoff.connectionRegistered()   // a warm reconnect: the bouncer replays its buffer
        for time in [0.0, 10, 20] {
            let replay = cutoff.isReplay(at(time), isRegistered: true)
            #expect(replay, "line at \(time) shown again")
        }
        let new = cutoff.isReplay(at(30), isRegistered: true)
        #expect(!new)
    }

    @Test func `A new line replayed in one channel doesn't hide an older new line replayed in another`() {
        var cutoff = ReplayCutoff()
        cutoff.connectionRegistered()
        see([0], on: &cutoff)
        cutoff.connectionRegistered()
        // While away, #b got a line at 5 and #a one at 10. The bouncer replays #a, then #b.
        see([10, 5], on: &cutoff)
    }

    @Test func `Lines from before registration don't move the next cutoff`() {
        var cutoff = ReplayCutoff()
        cutoff.connectionRegistered()
        see([0], on: &cutoff)
        // Reconnecting: the server says something before registering, stamped now.
        let early = cutoff.isReplay(at(100), isRegistered: false)
        #expect(!early)
        cutoff.connectionRegistered()
        // What came between the connections is still new.
        see([50], on: &cutoff)
    }

    @Test func `Each connection's cutoff is the newest line from before it`() {
        var cutoff = ReplayCutoff()
        cutoff.connectionRegistered()
        see([0], on: &cutoff)
        cutoff.connectionRegistered()
        see([10], on: &cutoff)
        cutoff.connectionRegistered()
        let old = cutoff.isReplay(at(10), isRegistered: true)
        #expect(old)
        see([11], on: &cutoff)
    }

    // MARK: - Our own lines

    private func sent(_ text: String, at time: TimeInterval, isAction: Bool = false) -> ChatMessage {
        ChatMessage(time: at(time), text: text, senderNick: "me", isPrivmsg: true, isFromMe: true, isAction: isAction)
    }

    private func replayed(_ text: String, at time: TimeInterval, isFromMe: Bool = true, isAction: Bool = false) -> ChatMessage {
        ChatMessage(time: at(time), text: text, senderNick: isFromMe ? "me" : "bob", isPrivmsg: true, isFromMe: isFromMe,
                    isAction: isAction, hasServerTime: true)
    }

    @Test func `A replayed line of ours matches the one we logged as we sent it, despite the clocks`() {
        let log = [sent("hello", at: 0)]
        #expect(ReplayCutoff.echoesSentLine(replayed("hello", at: 2), in: log))
        #expect(ReplayCutoff.echoesSentLine(replayed("hello", at: -2), in: log))
    }

    @Test func `It takes the same words, the same kind of line, and about the same time`() {
        let log = [sent("hello", at: 0)]
        #expect(!ReplayCutoff.echoesSentLine(replayed("hello again", at: 1), in: log))
        #expect(!ReplayCutoff.echoesSentLine(replayed("hello", at: 1, isAction: true), in: log))
        #expect(!ReplayCutoff.echoesSentLine(replayed("hello", at: ReplayCutoff.clockTolerance + 5), in: log))
    }

    @Test func `Only lines we logged ourselves count, not ones that came from the server`() {
        // Said from another client and relayed: it has the server's time, so it's no line of ours.
        let relayed = replayed("hello", at: 0)
        #expect(!ReplayCutoff.echoesSentLine(replayed("hello", at: 1), in: [relayed]))
    }
}
