import AppKit
import SwiftUI
import Testing
@testable import MD2App
@testable import MD2Core

@MainActor
struct MarkdownTableNativeTests {
    @Test(arguments: ["rows", "cells", "table", "source", "lines"])
    func recognizedTableGrowthBudgetConsumesTab(_ limit: String) async throws {
        let shortTable = "| A |\n| - |\n| z |"
        let source: String
        switch limit {
        case "rows":
            source = "| A |\n| - |\n" + String(repeating: "| x |\n", count: MarkdownTableEditing.maximumRows - 3) + "| z |"
        case "cells":
            let row = "|" + String(repeating: " x |", count: 40) + "\n"
            let delimiter = "|" + String(repeating: " - |", count: 40) + "\n"
            source = row + delimiter + String(repeating: row, count: MarkdownTableEditing.maximumCells / 40 - 3)
                + "|" + String(repeating: " x |", count: 39) + " z |"
        case "table":
            source = "| A |\n| - |\n| " + String(repeating: "x", count: MarkdownTableEditing.maximumTableUTF16 - shortTable.utf16.count) + "z |"
        case "source":
            source = String(repeating: "p", count: MarkdownTableEditing.maximumSourceUTF16 - shortTable.utf16.count - 2) + "\n\n" + shortTable
        default:
            source = String(repeating: "\n", count: MarkdownTableEditing.maximumSourceLines - 3) + shortTable
        }
        let target = (source as NSString).range(of: "z", options: .backwards)
        #expect(MarkdownTableEditing.result(source, selection: target, action: .nextCell) == .failure(.budget))
        let pureTab = try #require(MarkdownEditing.edit(source, selection: target, action: .indent))
        #expect(pureTab.range.length == 0 && pureTab.replacement.isEmpty && pureTab.selection == target)
        await allowQueuedMainCallbacks()
        let session = MarkdownEditorSession()
        session.undoManager.groupsByEvent = false
        var rejection: MarkdownTableEditing.Rejection?
        var changes = 0
        session.onTableEditingResult = { rejection = $0 }
        session.onUnmountedTextChange = { _ in changes += 1 }
        let editor = try #require(session.loadTextView(text: source) as? MarkdownSourceTextView)
        let coordinator = MarkdownEditorView.Coordinator(text: Binding(get: { source }, set: { _ in changes += 1 }), session: session)
        let host = NSScrollView()
        session.host(in: host, coordinator: coordinator)
        defer { session.unhost(from: host, coordinator: coordinator) }
        editor.setSelectedRange(target)
        let tab = #selector(NSResponder.insertTab(_:))
        let handled = session.textView(editor, doCommandBy: tab)
        #expect(handled)
        if !handled {
            session.undoManager.beginUndoGrouping()
            editor.doCommand(by: tab)
            session.undoManager.endUndoGrouping()
        }
        #expect(editor.string == source)
        #expect(editor.selectedRange() == target)
        #expect(rejection == .budget)
        #expect(changes == 0)
        #expect(!session.undoManager.canUndo)
        await allowQueuedMainCallbacks()
        // Navigation within the same supported table does not grow it.
        #expect(editor.performMarkdownAction(.outdent))
        #expect(editor.selectedRange() != target)
        #expect(editor.string == source)
        #expect(rejection == nil)
        #expect(!session.undoManager.canUndo)
        await allowQueuedMainCallbacks()
        #expect(session.textView(editor, doCommandBy: tab))
        let returnedCell = editor.selectedRange()
        #expect(returnedCell.location <= target.location && NSMaxRange(returnedCell) == NSMaxRange(target))
        #expect(editor.string == source)
        #expect(changes == 0)
        #expect(!session.undoManager.canUndo)
    }

    /// These are separate user commands; allow the real main queue to service
    /// pending callbacks between them without yielding inside a tested command.
    private func allowQueuedMainCallbacks() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test(arguments: [false, true])
    func unrecognizedLargeSourceRetainsOrdinaryListTab(_ backwards: Bool) throws {
        let source = String(repeating: "p", count: MarkdownTableEditing.maximumSourceUTF16) + "\n\n- parent\n  - item"
        let target = (source as NSString).range(of: "item")
        let action: MarkdownEditing.Action = backwards ? .outdent : .indent
        let tableAction: MarkdownTableEditing.Action = backwards ? .previousCell : .nextCell
        #expect(MarkdownTableEditing.result(source, selection: target, action: tableAction) == .failure(.budget))
        #expect(MarkdownTableEditing.navigationResult(source, selection: target, backwards: backwards) == nil)
        let expected = try #require(MarkdownEditing.edit(source, selection: target, action: action))
        let session = MarkdownEditorSession()
        session.undoManager.groupsByEvent = false
        var published = false
        session.onTableEditingResult = { _ in published = true }
        let editor = try #require(session.loadTextView(text: source) as? MarkdownSourceTextView)
        let coordinator = MarkdownEditorView.Coordinator(text: .constant(source), session: session)
        let host = NSScrollView()
        session.host(in: host, coordinator: coordinator)
        defer { session.unhost(from: host, coordinator: coordinator) }
        editor.setSelectedRange(target)
        session.undoManager.beginUndoGrouping()
        let selector = backwards ? #selector(NSResponder.insertBacktab(_:)) : #selector(NSResponder.insertTab(_:))
        let handled = session.textView(editor, doCommandBy: selector)
        #expect(handled)
        if !handled { editor.doCommand(by: selector) }
        session.undoManager.endUndoGrouping()
        #expect(editor.string == (source as NSString).replacingCharacters(in: expected.range, with: expected.replacement))
        #expect(editor.selectedRange() == expected.selection)
        #expect(!published)
        #expect(session.undoManager.canUndo)
        session.undoManager.undo()
        #expect(editor.string == source)
    }

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

    @Test func pendingReadRevealConsumesBothTableTabDirections() throws {
        let source = "| A | B |\n| - | - |\n| x | y |"
        let session = MarkdownEditorSession()
        session.undoManager.groupsByEvent = false
        let editor = try #require(session.loadTextView(text: source) as? MarkdownSourceTextView)
        let target = (source as NSString).range(of: "y")
        editor.setSelectedRange(target)
        session.revealSelectionOnNextHost = true
        for action in [MarkdownEditing.Action.indent, .outdent] {
            #expect(editor.performMarkdownAction(action))
            #expect(editor.string == source)
            #expect(editor.selectedRange() == target)
            #expect(!session.undoManager.canUndo)
        }
        session.undoManager.beginUndoGrouping()
        editor.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        session.undoManager.endUndoGrouping()
        let marked = editor.markedRange(), sourceWithComposition = editor.string
        #expect(!editor.performMarkdownAction(.indent), "IME still owns Tab during a pending reveal")
        #expect(!editor.performMarkdownAction(.outdent))
        #expect(editor.markedRange() == marked)
        #expect(editor.string == sourceWithComposition)
    }
}
