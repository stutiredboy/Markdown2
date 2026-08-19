import Foundation
import Testing
@testable import MD2Core

struct FindRevealTests {
    @Test func caretCollapsesAtEndOfMatch() {
        // "pre abc post": the match spans 4..<7; the caret sits at 7.
        #expect(FindReveal.caretRange(for: NSRange(location: 4, length: 3)) == NSRange(location: 7, length: 0))
    }

    @Test func matchReachingEndOfStringPlacesCaretAtLength() {
        #expect(FindReveal.caretRange(for: NSRange(location: 7, length: 3)) == NSRange(location: 10, length: 0))
    }

    @Test func emptyMatchCollapsesAtItsOwnLocation() {
        #expect(FindReveal.caretRange(for: NSRange(location: 5, length: 0)) == NSRange(location: 5, length: 0))
    }

    @Test func zeroLengthMatchAtStartStaysAtZero() {
        #expect(FindReveal.caretRange(for: NSRange(location: 0, length: 0)) == NSRange(location: 0, length: 0))
    }

    @Test func revealNeverSpansTheMatch() {
        // The whole point of the fix: never select the matched text as a unit.
        #expect(FindReveal.caretRange(for: NSRange(location: 2, length: 5)).length == 0)
    }
}
