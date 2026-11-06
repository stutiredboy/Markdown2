import AppKit
import Testing
@testable import MD2App

@MainActor
struct MarkdownEditorLinkCommandTests {
    @Test func linkCommandUsesItsClipboardProviderAndPreservesUndo() throws {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let session = MarkdownEditorSession(undoManager: undo)
        let editor = try #require(session.loadTextView(text: "selected label") as? MarkdownSourceTextView)
        var requests = 0
        editor.linkClipboardText = {
            requests += 1
            return "https://example.com"
        }
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        undo.beginUndoGrouping()
        #expect(editor.performMarkdownAction(.link))
        undo.endUndoGrouping()
        #expect(requests == 1)
        #expect(editor.string == "[selected label](https://example.com)")
        #expect(editor.selectedRange() == NSRange(location: 1, length: 14))
        undo.undo()
        #expect(editor.string == "selected label")
    }
}
