import AppKit
import SwiftUI
import XCTest
@testable import MD2App
@testable import MD2Core

final class MarkdownTableEditingGUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 to run table editing GUI tests.")
    }

    @MainActor
    func testTabNavigationAppendUndoAndAutosaveReachDocument() throws {
        let source = "| A | B |\r\n| :- | -: |\r\n| 中🙂 | y |"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TableGUI-\(UUID()).md")
        try source.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let harness = try TableEditingWindow(source, fileURL: url)
        defer { harness.close() }
        let editor = harness.editor
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(editor.selectedRange(), (source as NSString).range(of: "B"))
        XCTAssertEqual(harness.store.text, source)
        XCTAssertFalse(harness.store.isDirty)
        XCTAssertFalse(harness.store.undoManager.canUndo)
        editor.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        XCTAssertEqual(editor.selectedRange(), (source as NSString).range(of: "A"))
        let oldSelection = (source as NSString).range(of: "y")
        editor.setSelectedRange(oldSelection)
        editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(harness.store.text, source + "\r\n|  |  |")
        XCTAssertTrue(harness.store.isDirty)
        let target = editor.selectedRange()
        harness.store.undoManager.undo()
        XCTAssertEqual(harness.store.text, source)
        XCTAssertEqual(editor.selectedRange(), oldSelection)
        harness.store.undoManager.redo()
        XCTAssertEqual(editor.selectedRange(), target)
        harness.spin(until: { (try? String(contentsOf: url, encoding: .utf8)) == source + "\r\n|  |  |" })
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), source + "\r\n|  |  |")
    }

    @MainActor
    func testMenuDispatchRejectionAndNativeFieldsDoNotMutateHiddenSource() throws {
        let source = "| A | B |\n| - | - |\n| x | y |"
        let harness = try TableEditingWindow(source)
        defer { harness.close() }
        for action in [MarkdownTableEditing.Action.insertRowAbove, .insertRowBelow, .deleteRow,
                       .insertColumnBefore, .insertColumnAfter, .deleteColumn] {
            harness.editor.setSelectedRange((source as NSString).range(of: "x"))
            harness.store.requestTableEdit(action)
            harness.spin(until: { harness.store.text != source })
            XCTAssertNotEqual(harness.store.text, source)
            harness.store.undoManager.undo()
            harness.spin()
            XCTAssertEqual(harness.store.text, source)
        }
        harness.editor.setSelectedRange(NSRange(location: 2, length: 0))
        harness.store.requestTableEdit(.deleteRow)
        harness.spin(until: { harness.store.tableEditingRejection != nil })
        XCTAssertEqual(harness.store.tableEditingRejection, .header)
        XCTAssertEqual(harness.store.text, source)
        // The same native field-editor ownership applies to Find and filename
        // controls. No command token should be queued behind those controls.
        let field = NSTextField(string: "filename or query")
        field.frame = NSRect(x: 40, y: 40, width: 200, height: 25)
        harness.window.contentView!.addSubview(field)
        XCTAssertTrue(harness.window.makeFirstResponder(field))
        harness.spin()
        let token = harness.store.formatCommand?.token
        harness.store.requestTableEdit(.deleteColumn)
        harness.spin()
        XCTAssertEqual(harness.store.formatCommand?.token, token)
        XCTAssertEqual(harness.store.text, source)
        XCTAssertEqual(field.stringValue, "filename or query")
    }

    @MainActor
    func testReadRevealAndModeRehostingNeverReplayTableEdit() throws {
        let source = "| A | B |\n| - | - |\n| x | y |"
        let harness = try TableEditingWindow(source)
        defer { harness.close() }
        let editor = harness.editor
        editor.setSelectedRange((source as NSString).range(of: "x"))
        harness.store.requestMode(.read)
        harness.spin(until: { editor.window == nil })
        XCTAssertNil(editor.window)
        harness.store.requestTableEdit(.insertColumnAfter)
        harness.spin(until: { editor.window != nil && !harness.store.editorSession.revealSelectionOnNextHost })
        XCTAssertEqual(harness.store.text, source)
        XCTAssertNotNil(editor.window)
        XCTAssertTrue(harness.window.makeFirstResponder(editor))
        harness.store.requestTableEdit(.insertColumnAfter)
        harness.spin(until: { harness.store.text != source })
        let changed = harness.store.text
        XCTAssertNotEqual(changed, source)
        for mode in [EditorMode.read, .split, .write] {
            harness.store.requestMode(mode)
            harness.spin(for: 0.25)
            XCTAssertEqual(harness.store.text, changed)
        }
        harness.store.undoManager.undo()
        harness.spin()
        XCTAssertEqual(harness.store.text, source)
        XCTAssertEqual(editor.selectedRange(), (source as NSString).range(of: "x"))
    }
}

@MainActor
private final class TableEditingWindow: NSObject, NSWindowDelegate {
    let store = DocumentStore(autosaveDelay: 0.3)
    let window: NSWindow
    let suite = "MarkdownTableEditingGUITests-\(UUID().uuidString)"
    var editor: MarkdownSourceTextView { store.editorSession.textView as! MarkdownSourceTextView }

    init(_ text: String, fileURL: URL? = nil) throws {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.defaultMode = .write; settings.newDocumentMode = .write
        settings.showsOutlineByDefault = false
        if let fileURL { store.open(fileURL) } else { store.text = text }
        window.isReleasedWhenClosed = false; window.animationBehavior = .none; window.delegate = self
        let hosting = NSHostingView(rootView: ContentView(document: store, settings: settings, onOpen: {}))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 650)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        spin(until: { self.store.editorSession.textView?.window != nil })
        _ = try XCTUnwrap(store.editorSession.textView)
        XCTAssertTrue(window.makeFirstResponder(editor))
    }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { store.undoManager }
    func close() {
        _ = store.closeDocument(discardRecovery: true)
        window.orderOut(nil); window.contentView = nil; window.delegate = nil
        spin()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
    func spin(for duration: TimeInterval = 0.15) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline { autoreleasepool { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) } }
    }
    func spin(until condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { autoreleasepool { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) } }
    }
}
