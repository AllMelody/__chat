/// Tells replies to what the user sent from here, which show where they're looking, from
/// replies to other clients sharing the connection through a bouncer (HexChat's periodic WHO
/// and ISON, say), which go to the server log: a bouncer passes every reply to every client.
///
/// IRC doesn't say which command a reply answers, so this goes by time. Once the user sends
/// something the server may answer, replies are answers while each comes within `patience`
/// of the last, so a long answer, like LIST's, has time to arrive.
struct AnswerWindow {
    static let patience: Duration = .seconds(10)

    private var openUntil: ContinuousClock.Instant?

    /// The user sent the server something it may answer.
    mutating func userSent(at now: ContinuousClock.Instant = .now) {
        openUntil = now + Self.patience
    }

    /// Whether a reply arriving `now` answers the user; if it does, the rest of the answer
    /// gets time to come.
    mutating func isAnswer(at now: ContinuousClock.Instant = .now) -> Bool {
        guard let openUntil, now <= openUntil else { return false }
        self.openUntil = now + Self.patience
        return true
    }
}
