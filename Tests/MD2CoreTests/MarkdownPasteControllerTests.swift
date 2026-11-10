import AppKit
import SwiftUI
import Testing
@testable import MD2App
@testable import MD2Core

@MainActor
struct MarkdownPasteControllerTests {
    private func editor(_ source: String = "abc") throws -> (MarkdownEditorSession, MarkdownSourceTextView) {
        let undo = UndoManager(); undo.groupsByEvent = false
        let session = MarkdownEditorSession(undoManager: undo)
        let editor = try #require(session.loadTextView(text: source) as? MarkdownSourceTextView)
        editor.markdownPasteController.isFocusedSource = { _ in true }
        return (session, editor)
    }
    @Test func plainShortcutIsReservedFromModeAssignments() {
        #expect(ModeShortcutValidator.validate(MarkdownPasteCommand.plainShortcut, for: .write, in: .default) == .appCommand(commandName: "Paste as Plain Text"))
        #expect(ModeShortcutValidator.isValidConfiguration(.default))
    }
    @Test func explicitPlainReplacesWithoutPairingLinkAndSingleUndo() async throws {
        let (session, editor) = try editor("label")
        var reads: [MarkdownPaste.Kind] = []
        editor.markdownPasteController.capture = { kind in reads.append(kind); return .success(.init(plainText: "https://example.com")) }
        editor.setSelectedRange(NSRange(location: 0, length: 5))
        #expect(editor.markdownPasteController.perform(.plainText))
        await editor.markdownPasteController.waitForPendingPaste()
        #expect(reads == [.plainText]); #expect(editor.string == "https://example.com")
        session.undoManager.undo(); #expect(editor.string == "label"); #expect(!session.undoManager.canUndo)
        session.undoManager.redo(); #expect(editor.string == "https://example.com")
        editor.markdownPasteController.capture = { _ in .success(.init(plainText: "[")) }
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.pasteAsPlainText(nil)
        await editor.markdownPasteController.waitForPendingPaste()
        #expect(editor.string == "https://example.com[")
    }
    @Test func nativePlainInsertionPreservesUnicodeAndLineEndings() async throws {
        let (session, editor) = try editor("replace")
        let text = "e\u{301}🙂\r\nline\rnext  \n"
        editor.setSelectedRange(NSRange(location: 0, length: 7))
        editor.markdownPasteController.capture = { _ in .success(.init(plainText: text)) }
        editor.pasteAsPlainText(nil)
        await editor.markdownPasteController.waitForPendingPaste()
        #expect(Array(editor.string.utf16) == Array(text.utf16))
        session.undoManager.undo()
        #expect(editor.string == "replace")
    }
    @Test func unsafeRichProducesLiteralWholeFallbackAndNotice() async throws {
        let (session, editor) = try editor("")
        var notices: [MarkdownPasteNotice?] = []
        editor.markdownPasteController.onNotice = { notices.append($0) }
        editor.markdownPasteController.capture = { _ in .success(.init(plainText: "![x](https://example.com)", html: Data("<img src='x'>".utf8))) }
        editor.pasteAsMarkdown(nil)
        await editor.markdownPasteController.waitForPendingPaste()
        #expect(!MarkdownRenderer().render(editor.string).body.contains("<img"))
        #expect(notices.last == .literalFallback)
        withExtendedLifetime(session) {}
    }
    @Test func noFocusMarkedTextAndMultipleSelectionsNeverReadClipboard() throws {
        let (session, editor) = try editor()
        var requests = 0
        editor.markdownPasteController.capture = { _ in requests += 1; return .success(.init(plainText: "x")) }
        editor.markdownPasteController.isFocusedSource = { _ in false }
        #expect(!editor.markdownPasteController.perform(.markdown))
        editor.markdownPasteController.isFocusedSource = { _ in true }
        session.undoManager.disableUndoRegistration()
        editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        #expect(!editor.markdownPasteController.perform(.plainText))
        editor.unmarkText()
        session.undoManager.enableUndoRegistration()
        editor.selectedRanges = [NSValue(range: NSRange(location: 0, length: 1)), NSValue(range: NSRange(location: 2, length: 1))]
        #expect(editor.selectedRanges.count == 2)
        #expect(!editor.markdownPasteController.perform(.table))
        #expect(requests == 0)
        withExtendedLifetime(session) {}
    }
    private actor ConversionGate {
        var continuation: CheckedContinuation<Result<MarkdownPaste.Output, MarkdownPaste.Failure>, Never>?
        func wait() async -> Result<MarkdownPaste.Output, MarkdownPaste.Failure> {
            await withCheckedContinuation { continuation = $0 }
        }
        var ready: Bool { continuation != nil }
        func finish(_ result: Result<MarkdownPaste.Output, MarkdownPaste.Failure>) { continuation?.resume(returning: result) }
    }
    @Test func changedSourceAndSelectionCancelWithoutFallback() async throws {
        for change in ["source", "selection", "focus", "composition", "normalization", "reset", "host", "resign"] {
            let (session, editor) = try editor("e\u{301}abc")
            let gate = ConversionGate()
            editor.markdownPasteController.capture = { _ in .success(.init(plainText: "fallback")) }
            editor.markdownPasteController.convert = { _, _ in
                await gate.wait()
            }
            #expect(editor.markdownPasteController.perform(.markdown))
            // Let the request reach its deterministic conversion boundary.
            while !(await gate.ready) { await Task.yield() }
            switch change {
            case "source": editor.string = "changed"
            case "normalization": editor.string = "éabc" // Swift == would wrongly call this unchanged.
            case "selection": editor.setSelectedRange(NSRange(location: 1, length: 0))
            case "focus": editor.markdownPasteController.isFocusedSource = { _ in false }
            case "host":
                let scroll = NSScrollView()
                let coordinator = MarkdownEditorView.Coordinator(text: .constant(editor.string), session: session)
                session.host(in: scroll, coordinator: coordinator)
            case "resign": _ = editor.resignFirstResponder()
            case "composition":
                session.undoManager.disableUndoRegistration()
                editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
                session.undoManager.enableUndoRegistration()
            default: _ = session.resetText(to: "reset")
            }
            let before = Array(editor.string.utf16)
            await gate.finish(MarkdownPaste.convert(.markdown, payload: .init(plainText: "fallback", html: Data("<img>".utf8))))
            await editor.markdownPasteController.waitForPendingPaste()
            await Task.yield()
            #expect(Array(editor.string.utf16) == before)
            withExtendedLifetime(session) {}
        }
    }
    @Test func emptyClipboardCannotDeleteSelectionOrCreateUndo() async throws {
        let (session, editor) = try editor("keep me")
        editor.setSelectedRange(NSRange(location: 0, length: 7))
        editor.markdownPasteController.capture = { _ in .success(.init(plainText: "")) }
        for kind in [MarkdownPaste.Kind.plainText, .markdown, .table] {
            #expect(editor.markdownPasteController.perform(kind))
            await editor.markdownPasteController.waitForPendingPaste()
            #expect(editor.string == "keep me")
            #expect(editor.selectedRange() == NSRange(location: 0, length: 7))
            #expect(!session.undoManager.canUndo)
        }
    }
    @Test func unsafeFallbackContextKeepsTextSelectionAndUndo() async throws {
        for source in ["![x](PLACE)", "<img src=\"PLACE\">", "before **PLACE** after"] {
            let (session, editor) = try editor(source)
            let range = (source as NSString).range(of: "PLACE")
            editor.setSelectedRange(range)
            var notice: MarkdownPasteNotice?
            editor.markdownPasteController.onNotice = { notice = $0 }
            editor.markdownPasteController.capture = { _ in .success(.init(plainText: "https://example.com/a", html: Data("<img>".utf8))) }
            editor.pasteAsMarkdown(nil)
            await editor.markdownPasteController.waitForPendingPaste()
            #expect(editor.string == source); #expect(editor.selectedRange() == range)
            #expect(!session.undoManager.canUndo); #expect(notice == .unsafeContext)
        }
    }
    @Test func newerRequestInvalidatesOldConversion() async throws {
        let (session, editor) = try editor("")
        actor Gate {
            var pending: [CheckedContinuation<Result<MarkdownPaste.Output, MarkdownPaste.Failure>, Never>] = []
            func wait() async -> Result<MarkdownPaste.Output, MarkdownPaste.Failure> { await withCheckedContinuation { pending.append($0) } }
            var count: Int { pending.count }
            func resolve(_ index: Int, text: String) { pending[index].resume(returning: MarkdownPaste.convert(.plainText, payload: .init(plainText: text))) }
        }
        let gate = Gate()
        editor.markdownPasteController.capture = { _ in .success(.init(plainText: "x")) }
        editor.markdownPasteController.convert = { _, _ in await gate.wait() }
        editor.pasteAsPlainText(nil)
        while await gate.count < 1 { await Task.yield() }
        editor.pasteAsPlainText(nil)
        while await gate.count < 2 { await Task.yield() }
        await gate.resolve(1, text: "new")
        await editor.markdownPasteController.waitForPendingPaste()
        await gate.resolve(0, text: "old")
        await Task.yield()
        #expect(editor.string == "new")
        withExtendedLifetime(session) {}
    }
    @Test func commandAvailabilityRefreshesForNoDocumentNativeFieldAndSource() throws {
        let (session, editor) = try editor()
        let state = MarkdownPasteCommandState(observe: false)
        var responder: NSResponder?
        state.responder = { responder }; state.types = { [.string, .html] }
        state.refresh(); #expect(!state.canPlainText && !state.canMarkdown && !state.canTable)
        responder = editor; state.refresh(); #expect(state.canPlainText && state.canMarkdown && state.canTable)
        let native = NSTextView(); native.isEditable = true
        responder = native; state.refresh(); #expect(state.canPlainText && !state.canMarkdown && !state.canTable)
        // Markdown/table must not bypass a focused search/name/settings field.
        var reads = 0
        editor.markdownPasteController.capture = { _ in reads += 1; return .success(.init(plainText: "bad")) }
        state.perform(.markdown); state.perform(.table)
        #expect(reads == 0); #expect(editor.string == "abc")
        responder = nil; state.refresh(); #expect(!state.canPlainText && !state.canMarkdown && !state.canTable)
        responder = editor; state.types = { [.png] }; state.refresh()
        #expect(!state.canPlainText && !state.canMarkdown && !state.canTable)
        withExtendedLifetime(session) {}
    }
}
