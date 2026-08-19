import AppKit
import SwiftUI
import Testing
@testable import MD2App

/// Regression guards for the find reveal + delete bug. Revealing a match must
/// place a collapsed caret at the end of the match — never select the whole
/// matched word — so Backspace deletes exactly one character, and a SwiftUI
/// re-entrant update with unchanged inputs must not re-index the document.
///
/// These run headless (pattern from `MarkdownEditorIMERegressionTests`), so they
/// stay in the default `swift test` run; the window-backed delete test is
/// GUI-gated separately.
@MainActor
struct FindDeleteRegressionTests {
    private func makeTextView(_ string: String) -> NSTextView {
        let textView = NSTextView()
        textView.isRichText = false
        textView.string = string
        return textView
    }

    @Test func revealingAMatchCollapsesTheCaretAtTheMatchEnd() {
        var modelText = "pre abc post"
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(get: { modelText }, set: { modelText = $0 })
        )
        let textView = makeTextView(modelText)

        coordinator.updateFind(query: "abc", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)

        // "abc" spans 4..<7 in "pre abc post"; the caret sits at 7, collapsed.
        #expect(textView.selectedRange() == NSRange(location: 7, length: 0))
    }

    @Test func revealDoesNotSelectTheWholeMatch() {
        var modelText = "abc abc"
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(get: { modelText }, set: { modelText = $0 })
        )
        let textView = makeTextView(modelText)

        coordinator.updateFind(query: "abc", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)

        // Not the full first match (0..<3) — a collapsed caret.
        #expect(textView.selectedRange() != NSRange(location: 0, length: 3))
        #expect(textView.selectedRange().length == 0)
    }

    @Test func backspaceAfterRevealDeletesExactlyOneCharacter() {
        var modelText = "pre abc post"
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(get: { modelText }, set: { modelText = $0 })
        )
        let textView = makeTextView(modelText)

        coordinator.updateFind(query: "abc", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)
        textView.deleteBackward(nil)

        // Deleting the character before the caret removes only the trailing "c",
        // leaving "pre ab post" — never the whole matched word.
        #expect(textView.string == "pre ab post")
    }

    @Test func revealPlacesCaretAfterLastMatchOnNavigation() {
        var modelText = "abc abc"
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(get: { modelText }, set: { modelText = $0 })
        )
        let textView = makeTextView(modelText)

        coordinator.updateFind(query: "abc", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)
        coordinator.navigateFind(forward: true, in: textView)

        // Second match spans 4..<7; the caret sits at 7.
        #expect(textView.selectedRange() == NSRange(location: 7, length: 0))
    }

    @Test func updateFindWithUnchangedInputDoesNotReindex() {
        var modelText = "abc abc"
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(get: { modelText }, set: { modelText = $0 })
        )
        let textView = makeTextView(modelText)

        coordinator.updateFind(query: "abc", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)
        coordinator.navigateFind(forward: true, in: textView) // now on the second match

        // A re-entrant update (SwiftUI re-render from the status update) with the
        // same query must not re-index, which would reset the current match to
        // the first one and steal the caret back.
        coordinator.updateFind(query: "abc", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)
        #expect(textView.selectedRange() == NSRange(location: 7, length: 0))
    }

    @Test func queryChangeResetsTheCurrentMatchToTheFirst() {
        var modelText = "abc abc"
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(get: { modelText }, set: { modelText = $0 })
        )
        let textView = makeTextView(modelText)

        coordinator.updateFind(query: "abc", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)
        coordinator.navigateFind(forward: true, in: textView) // second match, caret at 7

        // A genuinely new query re-indexes from the first match.
        coordinator.updateFind(query: "bc", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)
        // First match of "bc" spans 1..<3; caret at 3.
        #expect(textView.selectedRange() == NSRange(location: 3, length: 0))
    }
}
