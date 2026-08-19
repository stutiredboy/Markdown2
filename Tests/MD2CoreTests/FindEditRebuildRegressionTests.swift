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
}
