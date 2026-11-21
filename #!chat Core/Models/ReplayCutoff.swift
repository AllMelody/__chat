import Foundation

/// Tells which of the lines a bouncer replays on connecting the log has from before.
///
/// A bouncer like ZNC replays what it keeps of each channel and private conversation on every
/// connection, each line stamped (IRCv3 server-time) with when it first had it. Lines the last
/// connection brought are in the log already, and stamped no later than the newest of them: so
/// a connection, on registering, takes that newest time as its cutoff. It's frozen then, rather
/// than moving as replayed lines arrive, because they arrive a conversation at a time: a new line
/// in #a from 10:10 mustn't hide a new line in #b from 10:05, replayed after it.
///
/// After a cold start there's no cutoff, and the replay is the history there is.
struct ReplayCutoff {
    /// The newest server time on a line a registered connection brought.
    private var newestSeen: Date?
    private var cutoff: Date?

    /// A connection registered: what came before it is in the log.
    mutating func connectionRegistered() {
        cutoff = newestSeen
    }

    /// Whether a line stamped `serverTime` is one the log has from before. One that isn't counts
    /// as seen, when `isRegistered`: lines that come before registration, like a server's
    /// notices, would otherwise move the next cutoff past lines replayed after them.
    mutating func isReplay(_ serverTime: Date, isRegistered: Bool) -> Bool {
        if let cutoff, serverTime <= cutoff { return true }
        if isRegistered, newestSeen.map({ serverTime > $0 }) ?? true { newestSeen = serverTime }
        return false
    }

    /// How far apart the two clocks can be for a replayed line of ours to match the line as we
    /// logged it.
    static let clockTolerance: TimeInterval = 10

    /// Whether `message`, a replayed line of our own, is one we sent from here and logged then.
    /// We log what we send with this device's clock, and the bouncer replays it with its own, a
    /// little later perhaps than the cutoff: so it's matched by what it says, at about that time.
    static func echoesSentLine(_ message: ChatMessage, in log: [ChatMessage]) -> Bool {
        log.contains { line in
            guard line.isFromMe, !line.hasServerTime else { return false }
            guard line.isAction == message.isAction, line.text == message.text else { return false }
            let apart: TimeInterval = abs(line.time.timeIntervalSince(message.time))
            return apart <= clockTolerance
        }
    }
}
