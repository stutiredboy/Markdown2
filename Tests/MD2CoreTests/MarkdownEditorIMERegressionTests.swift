import AppKit
import SwiftUI
import Testing
@testable import MD2App

@MainActor
struct MarkdownEditorIMERegressionTests {
    @Test(arguments: [false, true])
    func normalizationOnlyBoundTextChangesReachTheSession(_ startsDecomposed: Bool) throws {
        let original = startsDecomposed ? "before e\u{301}" : "before \u{e9}"
        let updated = startsDecomposed ? "before \u{e9}!" : "before e\u{301}!"
        var modelText = original
        let undo = UndoManager()
        undo.groupsByEvent = false
        let session = MarkdownEditorSession(undoManager: undo)
        let editor = session.loadTextView(text: original)
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(get: { modelText }, set: { modelText = $0 }), session: session)
        undo.beginUndoGrouping()
        editor.insertText("!", replacementRange: NSRange(location: original.utf16.count, length: 0))
        undo.endUndoGrouping()
        #expect(undo.canUndo)
        modelText = updated
        #expect(editor.string == modelText, "the visible strings are canonically equivalent")
        #expect(!editor.string.utf16.elementsEqual(modelText.utf16))
        #expect(coordinator.shouldApplyBoundText(modelText, to: editor))
        // Follow the same guard/reset sequence as makeNSView and updateNSView.
        if coordinator.shouldApplyBoundText(modelText, to: editor) {
            #expect(session.resetText(to: modelText))
        }
        #expect(editor.string.utf16.elementsEqual(modelText.utf16))
        #expect(!undo.canUndo, "old UTF-16 undo ranges must not survive the bound replacement")
    }

    @Test func normalizationOnlySyncWaitsForCompositionThenBecomesEligible() {
        let original = "e\u{301}"
        var modelText = original
        let session = MarkdownEditorSession()
        let editor = session.loadTextView(text: original)
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(get: { modelText }, set: { modelText = $0 }), session: session)
        editor.setMarkedText(original, selectedRange: NSRange(location: original.utf16.count, length: 0),
                             replacementRange: NSRange(location: 0, length: original.utf16.count))
        #expect(editor.hasMarkedText())
        modelText = "\u{e9}"
        #expect(!coordinator.shouldApplyBoundText(modelText, to: editor))
        #expect(!session.resetText(to: modelText))
        #expect(editor.string.utf16.elementsEqual(original.utf16))
        editor.unmarkText()
        #expect(!editor.hasMarkedText())
        #expect(coordinator.shouldApplyBoundText(modelText, to: editor))
        if coordinator.shouldApplyBoundText(modelText, to: editor) {
            #expect(session.resetText(to: modelText))
        }
        #expect(editor.string.utf16.elementsEqual(modelText.utf16))
    }

    @Test func headingCaretUsesHeadingFontForMarkedText() {
        let textView = NSTextView()
        textView.isRichText = false
        textView.string = "## "
        MarkdownTextStyler.apply(to: textView)
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        MarkdownTextStyler.synchronizeTypingAttributes(in: textView)

        let font = textView.typingAttributes[.font] as? NSFont
        #expect(font?.pointSize == 24)

        textView.setMarkedText(
            "wubi",
            selectedRange: NSRange(location: 4, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let markedFont = textView.textStorage?.attribute(
            .font,
            at: textView.markedRange().location,
            effectiveRange: nil
        ) as? NSFont
        #expect(markedFont?.pointSize == 24)
    }

    @Test func activeCompositionIsNotPublishedOrRestyled() {
        var modelText = "正文"
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(
                get: { modelText },
                set: { modelText = $0 }
            )
        )
        let textView = NSTextView()
        textView.isRichText = false
        textView.string = modelText
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.setMarkedText(
            NSAttributedString(
                string: "wubi",
                attributes: [.font: NSFont.systemFont(ofSize: 31)]
            ),
            selectedRange: NSRange(location: 4, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let markedRange = textView.markedRange()
        textView.textStorage?.addAttribute(
            .font,
            value: NSFont.systemFont(ofSize: 31),
            range: markedRange
        )

        coordinator.textDidChange(
            Notification(name: NSText.didChangeNotification, object: textView)
        )

        #expect(textView.hasMarkedText())
        #expect(textView.markedRange() == markedRange)
        #expect(modelText == "正文")
        let markedFont = textView.textStorage?.attribute(
            .font,
            at: markedRange.location,
            effectiveRange: nil
        ) as? NSFont
        #expect(markedFont?.pointSize == 31)
    }

    @Test func boundTextCannotOverwriteAnActiveComposition() {
        var modelText = "正文"
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(
                get: { modelText },
                set: { modelText = $0 }
            )
        )
        let textView = NSTextView()
        textView.string = modelText
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.setMarkedText(
            "wubi",
            selectedRange: NSRange(location: 4, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        #expect(!coordinator.shouldApplyBoundText(modelText, to: textView))
        #expect(textView.string == "正文wubi")
        #expect(textView.hasMarkedText())
    }

    @Test func selectionChangesSynchronizeHeadingAndBodyTypingFonts() {
        var modelText = "# 标题\n正文"
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(
                get: { modelText },
                set: { modelText = $0 }
            )
        )
        let textView = NSTextView()
        textView.isRichText = false
        textView.string = modelText
        MarkdownTextStyler.apply(to: textView)

        textView.setSelectedRange(NSRange(location: 4, length: 0))
        coordinator.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
        )
        #expect((textView.typingAttributes[.font] as? NSFont)?.pointSize == 27)

        textView.setSelectedRange(NSRange(location: 7, length: 0))
        coordinator.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
        )
        #expect((textView.typingAttributes[.font] as? NSFont)?.pointSize == 16)
    }

    @Test func committedTextStillPublishesAndKeepsCaret() {
        var modelText = "正文"
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(
                get: { modelText },
                set: { modelText = $0 }
            )
        )
        let textView = NSTextView()
        textView.isRichText = false
        textView.string = "正文内容"
        textView.setSelectedRange(NSRange(location: 4, length: 0))

        coordinator.textDidChange(
            Notification(name: NSText.didChangeNotification, object: textView)
        )

        #expect(modelText == "正文内容")
        #expect(textView.selectedRange() == NSRange(location: 4, length: 0))
    }
}
