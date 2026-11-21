import Foundation
import Testing
@testable import __chat

struct LogUpdateTests {
    private let ids = (0..<6).map { _ in UUID() }

    /// The log lines with these numbers; `thumbnails` gives the fingerprints that aren't 0.
    private func lines(_ numbers: [Int], thumbnails: [Int: Int] = [:]) -> [LogUpdate.Line] {
        numbers.map { LogUpdate.Line(id: ids[$0], thumbnails: thumbnails[$0] ?? 0) }
    }

    @Test func `Nothing new, nothing to do`() {
        #expect(LogUpdate.plan(from: lines([0, 1]), to: lines([0, 1])) == .none)
        #expect(LogUpdate.plan(from: [], to: []) == .none)
    }

    @Test func `New lines are added at the end`() {
        #expect(LogUpdate.plan(from: lines([0, 1]), to: lines([0, 1, 2, 3])) == .edit(dropped: 0, changed: [], appendFrom: 2))
    }

    @Test func `Trimmed lines are dropped from the front`() {
        #expect(LogUpdate.plan(from: lines([0, 1, 2, 3]), to: lines([2, 3])) == .edit(dropped: 2, changed: [], appendFrom: 2))
        #expect(LogUpdate.plan(from: lines([0, 1, 2, 3]), to: lines([2, 3, 4])) == .edit(dropped: 2, changed: [], appendFrom: 2))
    }

    @Test func `A line whose thumbnails changed is rendered again, where it is`() {
        #expect(LogUpdate.plan(from: lines([0, 1, 2]), to: lines([0, 1, 2], thumbnails: [1: 31])) ==
                .edit(dropped: 0, changed: [1], appendFrom: 3))
        // Indexes are into the new list.
        #expect(LogUpdate.plan(from: lines([0, 1, 2]), to: lines([1, 2, 3], thumbnails: [2: 31])) ==
                .edit(dropped: 1, changed: [1], appendFrom: 2))
    }

    @Test func `What isn't the old log continued is rendered from scratch`() {
        #expect(LogUpdate.plan(from: [], to: lines([0])) == .rebuild)                    // first lines
        #expect(LogUpdate.plan(from: lines([0, 1]), to: []) == .rebuild)                 // emptied
        #expect(LogUpdate.plan(from: lines([0, 1]), to: lines([4, 5])) == .rebuild)      // another conversation
        #expect(LogUpdate.plan(from: lines([0, 1, 2]), to: lines([0, 2])) == .rebuild)   // a hole in the middle
        #expect(LogUpdate.plan(from: lines([0, 1, 2]), to: lines([1])) == .rebuild)      // shorter at the end
    }
}
