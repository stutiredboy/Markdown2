// Regressions promoted from the independent C-package review.
import AppKit
import SwiftUI
import Testing
@testable import MD2App
@testable import MD2Core

@MainActor
@Suite(.serialized)
struct PreciseFindReviewRegressionTests {
    @Test func mixedGraphemeMustRespectItsEdgeWordScalars() {
        let conjunct = "क्‍ष"
        let text = "a" + conjunct + "b"
        print("REVIEW mixed grapheme", Array(text), TextSearch.matches(of: "a", in: text, options: .init(wholeWord: true)))
        #expect(TextSearch.matches(of: "a", in: text, options: .init(wholeWord: true)).isEmpty)
        #expect(TextSearch.matches(of: "b", in: text, options: .init(wholeWord: true)).isEmpty)
        #expect(TextSearch.matches(of: conjunct, in: text, options: .init(wholeWord: true)).isEmpty)
        #expect(TextSearch.matches(of: conjunct, in: conjunct, options: .init(wholeWord: true)) == [NSRange(location: 0, length: 4)])
        #expect(TextSearch.matches(of: text, in: text, options: .init(wholeWord: true)) == [NSRange(location: 0, length: 6)])
        #expect(TextSearch.matches(of: "a", in: text).count == 1)
    }

    @Test func canonicalChangesInvalidateDeferredSnapshot() {
        let session = MarkdownEditorSession()
        let editor = session.loadTextView(text: "café")
        let snapshot = FindReplacementSnapshot(query: "café", replacement: "é", textView: editor, find: session.find)
        #expect(!snapshot.isCurrent(query: "cafe\u{301}", replacement: "é", textView: editor, find: session.find))
        #expect(!snapshot.isCurrent(query: "café", replacement: "e\u{301}", textView: editor, find: session.find))
        editor.string = "cafe\u{301}"
        #expect(!snapshot.isCurrent(query: "café", replacement: "é", textView: editor, find: session.find))
    }

    @Test func scopedCRLFReplacementAndPostTypingUndoSequence() {
        let initial = "cat\r\ncat\r\ncat"
        let session = MarkdownEditorSession(undoManager: MarkdownEditorSessionTests.stepwiseUndoManager())
        let editor = session.loadTextView(text: initial)
        let coordinator = MarkdownEditorView.Coordinator(text: .constant(initial), session: session)
        editor.setSelectedRange(NSRange(location: 5, length: 3))
        session.find.useSelection(in: editor)
        coordinator.updateFind(query: "cat", in: editor)
        coordinator.flushPendingFindRebuild(in: editor)
        coordinator.replace(.all, replacement: "😀\r\n", in: editor)
        #expect(editor.string == "cat\r\n😀\r\n\r\ncat")
        #expect(session.find.range == NSRange(location: 5, length: 4))
        MarkdownEditorSessionTests.step(session.undoManager) { editor.insertText("!", replacementRange: NSRange(location: 0, length: 0)) }
        #expect(session.find.scope == .invalid)
        session.undoManager.undo()
        #expect(editor.string == "cat\r\n😀\r\n\r\ncat")
        #expect(session.find.scope == .invalid)
        session.undoManager.undo()
        #expect(editor.string == initial)
        #expect(session.find.range == NSRange(location: 5, length: 3))
        session.undoManager.redo()
        #expect(editor.string == "cat\r\n😀\r\n\r\ncat")
        // Redo must restore the scope from immediately before Undo.
        #expect(session.find.scope == .invalid)
    }

    @Test func selectionUsesWholeGraphemesAndAdjacentWordContext() {
        let cases = [("é", "e\u{301}", NSRange(location: 0, length: 1)), ("👩", "👩‍💻", NSRange(location: 0, length: 2))]
        for (query, source, scope) in cases {
            #expect(TextSearch.matches(of: query, in: source, scope: scope).isEmpty)
        }
        #expect(TextSearch.matches(of: "foo", in: "_foo_ foo", options: .init(wholeWord: true), scope: NSRange(location: 1, length: 3)).isEmpty)
        #expect(TextSearch.matches(of: "CAFÉ", in: "CAFE\u{301}", options: .init(caseSensitive: true, wholeWord: true)) == [NSRange(location: 0, length: 5)])
    }

    @Test func oldHostLosesOwnershipAndDocumentSessionsStaySeparate() {
        let one = MarkdownEditorSession(), two = MarkdownEditorSession()
        _ = one.loadTextView(text: "cat")
        let a = MarkdownEditorView.Coordinator(text: .constant("cat"), session: one)
        let b = MarkdownEditorView.Coordinator(text: .constant("cat"), session: one)
        let old = NSScrollView(), newer = NSScrollView()
        one.host(in: old, coordinator: a)
        #expect(one.isHosted(by: a))
        one.host(in: newer, coordinator: b)
        one.unhost(from: old, coordinator: a)
        #expect(!one.isHosted(by: a))
        #expect(one.isHosted(by: b))
        one.find.options.caseSensitive = true
        one.find.scope = .invalid
        #expect(!two.find.options.caseSensitive)
        #expect(two.find.scope == .document)
    }
}
