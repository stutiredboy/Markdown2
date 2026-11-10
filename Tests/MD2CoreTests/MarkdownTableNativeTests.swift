import AppKit
import Testing
@testable import MD2App
@testable import MD2Core

@MainActor
struct MarkdownTableNativeTests {
    @Test(arguments: [MarkdownTableEditing.Action.insertRowBelow, .insertColumnBefore, .deleteRow, .deleteColumn])
    func nativeUndoRestoresExactTextAndSelection(_ action: MarkdownTableEditing.Action) throws {
        let source = "before\r\n\r\n| 中🙂 | B |\r\n| :-- | --: |\r\n| é | y |\r\nafter"
        let session = MarkdownEditorSession()
        session.undoManager.groupsByEvent = false
        let editor = try #require(session.loadTextView(text: source) as? MarkdownSourceTextView)
        let selection = (source as NSString).range(of: "é")
        editor.setSelectedRange(selection)
        #expect(editor.performMarkdownAction(.tableEdit(action)))
        let changed = editor.string, target = editor.selectedRange()
        #expect(changed != source)
        #expect(session.undoManager.canUndo)
        session.undoManager.undo()
        #expect(editor.string.utf16.elementsEqual(source.utf16))
        #expect(editor.selectedRange() == selection)
        #expect(!session.undoManager.canUndo)
        session.undoManager.redo()
        #expect(editor.string.utf16.elementsEqual(changed.utf16))
        #expect(editor.selectedRange() == target)
    }

    @Test func navigationHasNoUndoOrTextNotificationAndLastCellAppendDoes() throws {
        let source = "| A | B |\n| - | - |\n| x | y |"
        let session = MarkdownEditorSession()
        session.undoManager.groupsByEvent = false
        var changes: [String] = []
        session.onUnmountedTextChange = { changes.append($0) }
        let editor = try #require(session.loadTextView(text: source) as? MarkdownSourceTextView)
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(editor.performMarkdownAction(.indent))
        #expect(editor.selectedRange() == (source as NSString).range(of: "B"))
        #expect(changes.isEmpty)
        #expect(!session.undoManager.canUndo)
        editor.setSelectedRange((source as NSString).range(of: "y"))
        #expect(editor.performMarkdownAction(.indent))
        #expect(editor.string.hasSuffix("\n|  |  |"))
        #expect(changes.count == 1)
        session.undoManager.undo()
        #expect(editor.string == source)
        #expect(editor.selectedRange() == (source as NSString).range(of: "y"))
    }

    @Test func markedTextAndMultiSelectionDoNotEditOrPublishARejection() throws {
        let source = "| A | B |\n| - | - |\n| x | y |"
        let session = MarkdownEditorSession()
        var resultCount = 0
        session.onTableEditingResult = { _ in resultCount += 1 }
        let editor = try #require(session.loadTextView(text: source) as? MarkdownSourceTextView)
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = editor.string, range = editor.markedRange()
        for action in [MarkdownEditing.Action.indent, .outdent, .tableEdit(.deleteColumn)] {
            #expect(!editor.performMarkdownAction(action))
        }
        #expect(editor.string == marked)
        #expect(editor.markedRange() == range)
        #expect(resultCount == 0)
        editor.unmarkText()
        editor.setSelectedRanges([NSValue(range: NSRange(location: 2, length: 1)),
                                  NSValue(range: (editor.string as NSString).range(of: "y"))], affinity: .downstream, stillSelecting: false)
        #expect(editor.selectedRanges.count == 2)
        #expect(!editor.performMarkdownAction(.tableEdit(.deleteColumn)))
        #expect(resultCount == 0)
    }

    @Test func explicitRejectionAndPendingRevealDoNotChangeSource() throws {
        let session = MarkdownEditorSession()
        var rejection: MarkdownTableEditing.Rejection?
        session.onTableEditingResult = { rejection = $0 }
        let editor = try #require(session.loadTextView(text: "plain") as? MarkdownSourceTextView)
        #expect(!editor.performMarkdownAction(.tableEdit(.deleteColumn)))
        #expect(rejection == .unsupported)
        #expect(editor.string == "plain")
        #expect(!session.undoManager.canUndo)
        session.revealSelectionOnNextHost = true
        #expect(editor.performMarkdownAction(.tableEdit(.insertRowBelow)))
        #expect(editor.string == "plain")
    }
}
