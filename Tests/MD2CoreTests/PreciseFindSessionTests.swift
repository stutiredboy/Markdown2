import AppKit
import SwiftUI
import Testing
@testable import MD2App

@MainActor
struct PreciseFindSessionTests {
    private func fixture(_ text: String) -> (MarkdownEditorSession, NSTextView, MarkdownEditorView.Coordinator) {
        let session = MarkdownEditorSession(undoManager: MarkdownEditorSessionTests.stepwiseUndoManager())
        let editor = session.loadTextView(text: text)
        let coordinator = MarkdownEditorView.Coordinator(text: .constant(text), session: session)
        return (session, editor, coordinator)
    }

    private func search(_ query: String, _ coordinator: MarkdownEditorView.Coordinator, _ editor: NSTextView) {
        coordinator.updateFind(query: query, in: editor)
        coordinator.flushPendingFindRebuild(in: editor)
    }

    @Test func selectionCapturedBeforeQueryRemainsFrozenAndOneUndoRestoresIt() {
        let (session, editor, coordinator) = fixture("cat cat cat")
        let originalRange = NSRange(location: 4, length: 3)
        editor.setSelectedRange(originalRange)
        session.find.rememberSelection(in: editor)
        search("cat", coordinator, editor) // collapses the native selection
        session.find.useSelection(in: editor)
        #expect(session.find.scope == .selection(originalRange))
        search("cat", coordinator, editor)
        coordinator.replace(.all, replacement: "😀cat!", in: editor)
        #expect(editor.string == "cat 😀cat! cat")
        #expect(session.find.range == NSRange(location: 4, length: 6))
        #expect(session.find.replacementCount == 1)
        session.undoManager.undo()
        #expect(editor.string == "cat cat cat")
        #expect(session.find.range == originalRange)
        #expect(!session.undoManager.canUndo)
        session.undoManager.redo()
        #expect(editor.string == "cat 😀cat! cat")
        #expect(session.find.range == NSRange(location: 4, length: 6))
    }

    @Test func repeatedReplacementAdjustsBoundsAndNeverRecursivelyReplaces() {
        let (session, editor, coordinator) = fixture("a a a a")
        editor.setSelectedRange(NSRange(location: 2, length: 3))
        session.find.useSelection(in: editor)
        search("a", coordinator, editor)
        coordinator.replace(.all, replacement: "aa", in: editor)
        #expect(editor.string == "a aa aa a")
        #expect(session.find.range == NSRange(location: 2, length: 5))
        #expect(session.find.replacementCount == 2)
        search("aa", coordinator, editor)
        coordinator.replace(.current, replacement: "", in: editor)
        #expect(editor.string == "a  aa a")
        #expect(session.find.range == NSRange(location: 2, length: 3))
        session.undoManager.undo()
        #expect(editor.string == "a aa aa a")
        #expect(session.find.range == NSRange(location: 2, length: 5))
        session.undoManager.undo()
        #expect(editor.string == "a a a a")
        #expect(session.find.range == NSRange(location: 2, length: 3))
    }

    @Test func deletingEntireSelectionKeepsAnEmptyScopeInsteadOfWholeDocument() {
        let (session, editor, coordinator) = fixture("cat cat")
        editor.setSelectedRange(NSRange(location: 0, length: 3))
        session.find.useSelection(in: editor)
        search("cat", coordinator, editor)
        coordinator.replace(.all, replacement: "", in: editor)
        #expect(editor.string == " cat")
        #expect(session.find.range == NSRange(location: 0, length: 0))
        coordinator.replace(.all, replacement: "wrong", in: editor)
        #expect(editor.string == " cat")
        session.undoManager.undo()
        #expect(editor.string == "cat cat")
        #expect(session.find.range == NSRange(location: 0, length: 3))
    }

    @Test func ordinaryEditInvalidatesScopeAndDoesNotAllowFullDocumentReplacement() {
        let (session, editor, coordinator) = fixture("cat cat")
        editor.setSelectedRange(NSRange(location: 0, length: 3))
        session.find.useSelection(in: editor)
        search("cat", coordinator, editor)
        MarkdownEditorSessionTests.step(session.undoManager) {
            editor.insertText("!", replacementRange: NSRange(location: 7, length: 0))
        }
        #expect(session.find.scope == .invalid)
        coordinator.replace(.all, replacement: "WRONG", in: editor)
        #expect(editor.string == "cat cat!")
        session.undoManager.undo()
        #expect(session.find.scope == .invalid, "undoing unrelated typing does not silently reactivate stale bounds")
        #expect(editor.string == "cat cat")
        editor.setSelectedRange(NSRange(location: 4, length: 3))
        session.find.useSelection(in: editor)
        search("cat", coordinator, editor)
        coordinator.replace(.all, replacement: "dog", in: editor)
        #expect(editor.string == "cat dog")
    }

    @Test func optionsTriggerReindexWithoutChangingQuery() {
        let (session, editor, coordinator) = fixture("Cat cat scatter")
        search("cat", coordinator, editor)
        session.find.options.caseSensitive = true
        session.find.options.wholeWord = true
        coordinator.replace(.all, replacement: "dog", in: editor)
        #expect(editor.string == "Cat dog scatter")
        #expect(session.find.replacementCount == 1)
    }

    @Test func missingSelectionAndExternalResetStayInvalidAcrossSessionUse() {
        let (session, editor, coordinator) = fixture("cat cat")
        session.find.useSelection(in: editor)
        #expect(session.find.scope == .invalid)
        search("cat", coordinator, editor)
        coordinator.replace(.all, replacement: "wrong", in: editor)
        #expect(editor.string == "cat cat")
        editor.setSelectedRange(NSRange(location: 0, length: 3))
        session.find.useSelection(in: editor)
        #expect(session.resetText(to: "cat cat cat"))
        #expect(session.find.scope == .invalid)
        let other = MarkdownEditorSession()
        #expect(other.find.scope == .document)
        #expect(!other.find.options.caseSensitive)
    }

    @Test func noopAndZeroMatchesAddNoUndoOperation() {
        let (session, editor, coordinator) = fixture("cat")
        search("cat", coordinator, editor)
        coordinator.replace(.all, replacement: "cat", in: editor)
        #expect(!session.undoManager.canUndo)
        #expect(session.find.replacementCount == 0)
        search("dog", coordinator, editor)
        coordinator.replace(.all, replacement: "x", in: editor)
        #expect(!session.undoManager.canUndo)
        #expect(session.find.replacementCount == 0)
    }

    @Test func findReplacementIsSeparateFromEarlierTyping() {
        let (session, editor, coordinator) = fixture("cat")
        MarkdownEditorSessionTests.step(session.undoManager) {
            editor.insertText(" cat", replacementRange: NSRange(location: 3, length: 0))
        }
        search("cat", coordinator, editor)
        coordinator.replace(.all, replacement: "dog", in: editor)
        #expect(editor.string == "dog dog")
        session.undoManager.undo()
        #expect(editor.string == "cat cat")
        session.undoManager.undo()
        #expect(editor.string == "cat")
        session.undoManager.redo()
        session.undoManager.redo()
        #expect(editor.string == "dog dog")
    }

    @Test func markedTextBlocksReplacementAndNavigation() {
        let session = MarkdownEditorSession()
        let editor = session.loadTextView(text: "cat cat")
        let coordinator = MarkdownEditorView.Coordinator(text: .constant("cat cat"), session: session)
        search("cat", coordinator, editor)
        editor.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: 7, length: 0))
        let original = editor.string
        let marked = editor.markedRange()
        coordinator.replace(.all, replacement: "wrong", in: editor)
        coordinator.navigateFind(forward: true, in: editor)
        #expect(editor.hasMarkedText())
        #expect(editor.markedRange() == marked)
        #expect(editor.string == original)
        editor.unmarkText()
    }
}

@MainActor
struct DeferredFindReplacementTests {
    @Test(arguments: ["query", "replacement", "source", "selection", "options", "scope", "identity", "composition"])
    func changedInvocationContextCancelsInsteadOfEditing(_ change: String) {
        let session = MarkdownEditorSession()
        let editor = session.loadTextView(text: "cat cat")
        let coordinator = MarkdownEditorView.Coordinator(text: .constant("cat cat"), session: session)
        coordinator.updateFind(query: "cat", in: editor)
        coordinator.flushPendingFindRebuild(in: editor)
        let snapshot = FindReplacementSnapshot(query: "cat", replacement: "dog", textView: editor, find: session.find)
        var query = "cat", replacement = "dog"
        switch change {
        case "query": query = "other"
        case "replacement": replacement = "unexpected"
        case "source": editor.string = "new cat"
        case "selection": editor.setSelectedRange(NSRange(location: 0, length: 1))
        case "options": session.find.options.caseSensitive = true
        case "scope": session.find.scope = .invalid
        case "identity": session.find.reset()
        case "composition": editor.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: 7, length: 0))
        default: break
        }
        let original = editor.string
        #expect(!coordinator.replaceIfUnchanged(.all, snapshot: snapshot, query: query, replacement: replacement, in: editor))
        #expect(editor.string == original)
        #expect(session.find.replacementCancelled == (change != "identity"))
        if editor.hasMarkedText() { editor.unmarkText() }
    }

    @Test func unchangedRequestRunsOnceAndCannotBeReplayedAgainstChangedText() {
        let session = MarkdownEditorSession(undoManager: MarkdownEditorSessionTests.stepwiseUndoManager())
        let editor = session.loadTextView(text: "cat cat")
        let coordinator = MarkdownEditorView.Coordinator(text: .constant("cat cat"), session: session)
        coordinator.updateFind(query: "cat", in: editor)
        coordinator.flushPendingFindRebuild(in: editor)
        let snapshot = FindReplacementSnapshot(query: "cat", replacement: "dog", textView: editor, find: session.find)
        #expect(coordinator.replaceIfUnchanged(.all, snapshot: snapshot, query: "cat", replacement: "dog", in: editor))
        #expect(editor.string == "dog dog")
        #expect(!coordinator.replaceIfUnchanged(.all, snapshot: snapshot, query: "cat", replacement: "dog", in: editor))
        session.undoManager.undo()
        #expect(editor.string == "cat cat")
        #expect(!session.undoManager.canUndo)
    }
}
