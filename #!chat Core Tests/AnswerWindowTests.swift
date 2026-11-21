import Testing
@testable import __chat

struct AnswerWindowTests {
    private let start = ContinuousClock.now

    @Test func `Before the user sends anything, no reply answers them`() {
        var window = AnswerWindow()
        let answered = window.isAnswer(at: start)
        #expect(!answered)
    }

    @Test func `A reply soon after the user sent something answers them; a late one doesn't`() {
        var window = AnswerWindow()
        window.userSent(at: start)
        let soon = window.isAnswer(at: start + .seconds(1))
        #expect(soon)

        var late = AnswerWindow()
        late.userSent(at: start)
        let tooLate = late.isAnswer(at: start + AnswerWindow.patience + .seconds(1))
        #expect(!tooLate)
    }

    @Test func `A long answer keeps coming as long as each reply follows the last in time`() {
        var window = AnswerWindow()
        window.userSent(at: start)
        for second in stride(from: 8, through: 40, by: 8) {   // past the patience from the start
            let answered = window.isAnswer(at: start + .seconds(second))
            #expect(answered)
        }
        // Then a reply long after the answer ended is somebody else's.
        let afterwards = window.isAnswer(at: start + .seconds(40) + AnswerWindow.patience + .seconds(1))
        #expect(!afterwards)
    }

    @Test func `Sending again opens it again`() {
        var window = AnswerWindow()
        window.userSent(at: start)
        let unasked = window.isAnswer(at: start + .seconds(60))
        #expect(!unasked)
        window.userSent(at: start + .seconds(60))
        let asked = window.isAnswer(at: start + .seconds(61))
        #expect(asked)
    }
}
