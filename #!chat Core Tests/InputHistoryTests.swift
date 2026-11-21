import Testing
@testable import __chat

struct InputHistoryTests {
    @Test func `Goes back through what was sent, and forward again to the draft`() {
        var history = InputHistory()
        history.add("first")
        history.add("second")
        #expect(history.older(than: "half-typed") == "second")
        #expect(history.older(than: "second") == "first")
        #expect(history.older(than: "first") == nil)   // nothing older
        #expect(history.newer() == "second")
        #expect(history.newer() == "half-typed")
        #expect(history.newer() == nil)                // back on a line of our own
    }

    @Test func `With nothing sent, there's nowhere to go`() {
        var history = InputHistory()
        #expect(history.older(than: "draft") == nil)
        #expect(history.newer() == nil)
    }

    @Test func `Blank lines and immediate repeats aren't kept`() {
        var history = InputHistory()
        history.add("hello")
        history.add("hello")
        history.add("   ")
        history.add("")
        #expect(history.older(than: "") == "hello")
        #expect(history.older(than: "hello") == nil)
    }

    @Test func `Sending starts over from the newest line`() {
        var history = InputHistory()
        history.add("first")
        history.add("second")
        _ = history.older(than: "")
        _ = history.older(than: "second")
        history.add("third")
        #expect(history.older(than: "") == "third")
    }

    @Test func `Keeps the most recent lines only`() {
        var history = InputHistory()
        for number in 1...(InputHistory.capacity + 5) { history.add("line \(number)") }
        var oldest: String?
        while let line = history.older(than: "") { oldest = line }
        #expect(oldest == "line 6")
    }
}
