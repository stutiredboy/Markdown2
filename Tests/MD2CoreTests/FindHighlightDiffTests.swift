import Foundation
import Testing
@testable import MD2Core

struct FindHighlightDiffTests {
    private func r(_ location: Int, _ length: Int) -> NSRange {
        NSRange(location: location, length: length)
    }

    @Test func emptyToNonemptyAddsEverything() {
        let result = FindHighlightDiff.diff(from: [], to: [r(0, 2), r(5, 2)])
        #expect(result.added == [r(0, 2), r(5, 2)])
        #expect(result.removed.isEmpty)
        #expect(result.unchanged.isEmpty)
    }

    @Test func nonemptyToEmptyRemovesEverything() {
        let result = FindHighlightDiff.diff(from: [r(0, 2), r(5, 2)], to: [])
        #expect(result.added.isEmpty)
        #expect(result.removed == [r(0, 2), r(5, 2)])
        #expect(result.unchanged.isEmpty)
    }

    @Test func disjointSetsAddAndRemoveIndependently() {
        let result = FindHighlightDiff.diff(from: [r(0, 2)], to: [r(10, 2)])
        #expect(result.added == [r(10, 2)])
        #expect(result.removed == [r(0, 2)])
        #expect(result.unchanged.isEmpty)
    }

    @Test func newSuffixLeavesExistingRangesUnchanged() {
        let result = FindHighlightDiff.diff(from: [r(0, 2), r(5, 2)], to: [r(0, 2), r(5, 2), r(9, 2)])
        #expect(result.added == [r(9, 2)])
        #expect(result.removed.isEmpty)
        #expect(result.unchanged == [r(0, 2), r(5, 2)])
    }

    @Test func identicalSetsProduceNoChanges() {
        let result = FindHighlightDiff.diff(from: [r(0, 2), r(5, 2)], to: [r(0, 2), r(5, 2)])
        #expect(result.added.isEmpty)
        #expect(result.removed.isEmpty)
        #expect(result.unchanged == [r(0, 2), r(5, 2)])
    }

    @Test func shiftedMatchIsOneRemoveAndOneAdd() {
        let result = FindHighlightDiff.diff(from: [r(0, 2)], to: [r(1, 2)])
        #expect(result.added == [r(1, 2)])
        #expect(result.removed == [r(0, 2)])
        #expect(result.unchanged.isEmpty)
    }

    @Test func sameSingleMatchIsUnchanged() {
        let result = FindHighlightDiff.diff(from: [r(3, 1)], to: [r(3, 1)])
        #expect(result.added.isEmpty)
        #expect(result.removed.isEmpty)
        #expect(result.unchanged == [r(3, 1)])
    }

    @Test func removedPrefixAndAddedSuffixCombine() {
        let result = FindHighlightDiff.diff(from: [r(0, 2), r(5, 2)], to: [r(3, 2), r(7, 2)])
        #expect(result.added == [r(3, 2), r(7, 2)])
        #expect(result.removed == [r(0, 2), r(5, 2)])
        #expect(result.unchanged.isEmpty)
    }
}
