import AppKit
import SwiftUI
import Testing
@testable import MD2App

/// Regression guards for rebuilding find highlights after the *document* text
/// changes while the find bar is open. A text edit shifts or removes match
/// positions, so the previously-painted highlight ranges live in the old
/// coordinate space; the rebuild must repaint them at the new positions without
/// leaving a stale highlight or touching out-of-bounds ranges.
///
/// Runs headless (pattern from `MarkdownEditorIMERegressionTests`).
@MainActor
struct FindEditRebuildRegressionTests {
    private func makeTextView(_ string: String) -> NSTextView {
        let textView = NSTextView()
        textView.isRichText = false
        textView.string = string
        return textView
    }

    private func highlighted(_ textView: NSTextView, at index: Int) -> Bool {
        textView.layoutManager?
            .temporaryAttribute(.backgroundColor, atCharacterIndex: index, effectiveRange: nil) != nil
    }

    @Test func deletingTextBeforeAMatchRepaintsAtTheNewPosition() {
        var modelText = "xx aaa"
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(get: { modelText }, set: { modelText = $0 })
        )
        let textView = makeTextView(modelText)

        coordinator.updateFind(query: "aaa", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)
        // "aaa" is at 3..<6.
        #expect(highlighted(textView, at: 3))

        // Delete "xx " (0..<3): the match moves to 0..<3.
        textView.string = "aaa"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        coordinator.updateFind(query: "aaa", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)

        #expect(textView.string == "aaa")
        // The match is now at 0..<3 and must be highlighted there; the rebuild
        // must not crash on the stale 3..<6 range from before the edit.
        #expect(highlighted(textView, at: 0))
    }

    @Test func insertingTextBeforeAMatchRepaintsAtTheShiftedPosition() {
        var modelText = "aaa bbb"
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(get: { modelText }, set: { modelText = $0 })
        )
        let textView = makeTextView(modelText)

        coordinator.updateFind(query: "bbb", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)
        // "bbb" is at 4..<7.
        #expect(highlighted(textView, at: 4))

        // Insert "x" at 0: "bbb" shifts to 5..<8.
        textView.string = "xaaa bbb"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        coordinator.updateFind(query: "bbb", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)

        #expect(highlighted(textView, at: 5))
    }

    @Test func shiftingEditDoesNotTruncateANonCurrentMatchHighlight() {
        var modelText = "xabc"
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(get: { modelText }, set: { modelText = $0 })
        )
        let textView = makeTextView(modelText)

        coordinator.updateFind(query: "abc", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)
        // The current match "abc" at 1..<4 is highlighted (orange).
        #expect(highlighted(textView, at: 1))

        // Edit the document so "abc" appears at 0..<3 and 3..<6. The old painted
        // current range (1..<4) lives in the previous coordinate space; the
        // rebuild must not let its stale coordinates wipe the second match's
        // freshly painted highlight.
        textView.string = "abcabc"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        coordinator.updateFind(query: "abc", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)

        #expect(textView.string == "abcabc")
        for index in 0..<6 {
            #expect(highlighted(textView, at: index), "match highlight missing at index \(index)")
        }
    }

    private func background(_ textView: NSTextView, at index: Int) -> NSColor? {
        textView.layoutManager?
            .temporaryAttribute(.backgroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
    }

    private func currentMatchColor() -> NSColor {
        NSColor.systemOrange.withAlphaComponent(0.6)
    }

    @Test func editingUnderAnOpenFindBarDoesNotJumpTheCaretToTheNextMatch() {
        var modelText = "abc abc abc"
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(get: { modelText }, set: { modelText = $0 })
        )
        let textView = makeTextView(modelText)

        coordinator.updateFind(query: "abc", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)
        // Reveal places a collapsed caret at the end of the first match (3).
        #expect(textView.selectedRange() == NSRange(location: 3, length: 0))

        // The user deletes the trailing "c" of the first match: the caret moves
        // to 2. The rebuild must re-index (the first match is gone) without
        // stealing the caret — it must not jump to the end of the next match (6).
        textView.string = "ab abc abc"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        coordinator.updateFind(query: "abc", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)

        #expect(textView.selectedRange() == NSRange(location: 2, length: 0),
                "editing under an open find bar must not jump the caret to the next match")
        // The new match set is repainted at the shifted positions.
        #expect(highlighted(textView, at: 3))
        #expect(highlighted(textView, at: 7))
    }

    @Test func anEditSupersedesAPendingQueryChangeReveal() {
        var modelText = "abc abc"
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(get: { modelText }, set: { modelText = $0 })
        )
        let textView = makeTextView(modelText)

        coordinator.updateFind(query: "abc", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)
        #expect(textView.selectedRange() == NSRange(location: 3, length: 0))

        // User types "ab": a rebuild is scheduled that would reveal match 1 of
        // "ab". Before the debounce fires, they click into the editor and edit —
        // a document edit supersedes the pending reveal.
        coordinator.updateFind(query: "ab", in: textView)
        textView.string = "abx abc"
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        coordinator.updateFind(query: "ab", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)

        #expect(textView.selectedRange() == NSRange(location: 3, length: 0),
                "an edit after a pending query change must suppress the reveal")
    }

    @Test func anEditThatCreatesAMatchAtTheCaretPromotesItToTheCurrentMatch() {
        var modelText = "abc"
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(get: { modelText }, set: { modelText = $0 })
        )
        let textView = makeTextView(modelText)

        coordinator.updateFind(query: "abc", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)

        // Insert " abc" at the caret so a new match 4..<7 ends exactly at the
        // caret (7).
        textView.string = "abc abc"
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        coordinator.updateFind(query: "abc", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)

        #expect(textView.selectedRange() == NSRange(location: 7, length: 0),
                "promotion must not move the caret")
        // The new match at 4..<7 is promoted to current (orange); the original
        // match at 0..<3 falls back to the normal highlight.
        #expect(background(textView, at: 4) == currentMatchColor())
        #expect(background(textView, at: 0) != currentMatchColor())
    }

    @Test func anEditAwayFromAnyMatchKeepsPositionSemanticsWithoutMovingTheCaret() {
        var modelText = "abc abc"
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(get: { modelText }, set: { modelText = $0 })
        )
        let textView = makeTextView(modelText)

        coordinator.updateFind(query: "abc", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)

        // Insert "x" inside the first match: the caret (2) is no longer on any
        // "abc" match, so there is nothing to promote.
        textView.string = "axbc abc"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        coordinator.updateFind(query: "abc", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)

        #expect(textView.selectedRange() == NSRange(location: 2, length: 0))
        // The surviving match (5..<8) keeps position-based current semantics.
        #expect(background(textView, at: 5) == currentMatchColor())
    }

    @Test func replaceStillRevealsTheNextMatch() {
        var modelText = "abc abc"
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(get: { modelText }, set: { modelText = $0 })
        )
        let textView = makeTextView(modelText)

        coordinator.updateFind(query: "abc", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)
        coordinator.replace(.current, replacement: "xyz", in: textView)

        // "xyz abc": the next match is at 4..<7, revealed with a collapsed caret
        // at 7.
        #expect(textView.string == "xyz abc")
        #expect(textView.selectedRange() == NSRange(location: 7, length: 0))
    }

    @Test func replaceAllStillRevealsTheFirstMatchWhenMatchesRemain() {
        var modelText = "ab ab"
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(get: { modelText }, set: { modelText = $0 })
        )
        let textView = makeTextView(modelText)

        coordinator.updateFind(query: "ab", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)
        // The replacement still contains the query, so matches remain after the
        // replace-all and the rebuild reveals the first one.
        coordinator.replace(.all, replacement: "abc", in: textView)

        #expect(textView.string == "abc abc")
        #expect(textView.selectedRange() == NSRange(location: 2, length: 0))
    }

    @Test func externalTextReplacementReindexesWithoutYankingTheCaret() {
        var modelText = "abc abc"
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(get: { modelText }, set: { modelText = $0 })
        )
        let textView = makeTextView(modelText)

        coordinator.updateFind(query: "abc", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)

        // Simulate the reload path: replace the string and clamp the selection.
        textView.string = "abc xyz abc"
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.noteExternalTextChange()
        coordinator.updateFind(query: "abc", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)

        // Highlights repaint at the new coordinates; the caret is not yanked.
        #expect(highlighted(textView, at: 0))
        #expect(highlighted(textView, at: 8))
        #expect(textView.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test func returnInTheQueryFieldRunsTheSearchButNeverAdvances() {
        var modelText = "abc abc"
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(get: { modelText }, set: { modelText = $0 })
        )
        let textView = makeTextView(modelText)

        coordinator.updateFind(query: "abc", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)
        coordinator.navigateFind(forward: true, in: textView) // now on the second match
        #expect(textView.selectedRange() == NSRange(location: 7, length: 0))

        // Return in the query field routes to `.search`, which flushes any
        // pending rebuild but never advances to the next match.
        coordinator.handleFindNavigation(.search, in: textView)
        coordinator.handleFindNavigation(.search, in: textView)
        #expect(textView.selectedRange() == NSRange(location: 7, length: 0),
                "Return must not advance to the next match")
    }
}
