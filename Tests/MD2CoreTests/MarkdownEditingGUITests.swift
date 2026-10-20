import AppKit
import SwiftUI
import XCTest
@testable import MD2App
@testable import MD2Core

/// Real window / first-responder coverage. Run with MD2_RUN_GUI_TESTS=1.
final class MarkdownEditingGUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 to run Markdown editing GUI tests.")
    }

    @MainActor
    func testReturnSoftReturnTabAndUndoReachTheDocument() throws {
        let harness = try EditingWindow("- first\n- second")
        defer { harness.close() }
        let editor = harness.editor
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        harness.spin()
        XCTAssertEqual(harness.store.text, "- first\n  - second")
        editor.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        harness.spin()
        XCTAssertEqual(harness.store.text, "- first\n- second")
        editor.interpretKeyEvents([harness.key("\r", code: 36, flags: .shift)])
        harness.spin()
        XCTAssertEqual(harness.store.text, "- first\n- second\n  ")
        harness.store.undoManager.undo()
        harness.spin()
        XCTAssertEqual(harness.store.text, "- first\n- second")
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.interpretKeyEvents([harness.key("\r", code: 36)])
        harness.spin()
        XCTAssertEqual(harness.store.text, "- first\n- second\n- ")
        XCTAssertTrue(harness.store.isDirty)
        harness.store.undoManager.undo()
        harness.spin()
        XCTAssertEqual(harness.store.text, "- first\n- second")
        harness.store.undoManager.redo()
        harness.spin()
        XCTAssertEqual(harness.store.text, "- first\n- second\n- ")
    }

    @MainActor
    func testPairingSkippingDeletionAndPasteUseNativeUndo() throws {
        let harness = try EditingWindow("")
        defer { harness.close() }
        let editor = harness.editor
        editor.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        harness.spin()
        XCTAssertEqual(harness.store.text, "()")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 0))
        editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        harness.spin()
        XCTAssertEqual(harness.store.text, "")
        harness.store.undoManager.undo()
        harness.spin()
        XCTAssertEqual(harness.store.text, "()")
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        editor.insertText(")", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(harness.store.text, "()")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 0))

        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(saved.map { entries in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            })
        }
        pasteboard.clearContents()
        pasteboard.setString("[", forType: .string)
        editor.paste(nil)
        harness.spin()
        XCTAssertEqual(harness.store.text, "()[", "a one-character paste must not create a pair")

        let linkHarness = try EditingWindow("selected label")
        defer { linkHarness.close() }
        pasteboard.clearContents()
        pasteboard.setString("https://example.com", forType: .string)
        linkHarness.editor.setSelectedRange(NSRange(location: 0, length: linkHarness.editor.string.utf16.count))
        linkHarness.editor.paste(nil)
        linkHarness.spin()
        XCTAssertEqual(linkHarness.store.text, "[selected label](https://example.com)")
    }

    @MainActor
    func testOnlyTrackedClosersSkipOrDeleteAsPairs() throws {
        let literal = try EditingWindow("foo()")
        defer { literal.close() }
        literal.editor.setSelectedRange(NSRange(location: 4, length: 0))
        literal.editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        literal.spin()
        XCTAssertEqual(literal.store.text, "foo)")
        literal.editor.setSelectedRange(NSRange(location: 3, length: 0))
        literal.editor.insertText(")", replacementRange: NSRange(location: NSNotFound, length: 0))
        literal.spin()
        XCTAssertEqual(literal.store.text, "foo))")

        let automatic = try EditingWindow("")
        defer { automatic.close() }
        automatic.editor.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        automatic.editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        automatic.spin()
        XCTAssertEqual(automatic.store.text, "(x)")
        automatic.editor.insertText(")", replacementRange: NSRange(location: NSNotFound, length: 0))
        automatic.spin()
        XCTAssertEqual(automatic.store.text, "(x)")
        XCTAssertEqual(automatic.editor.selectedRange().location, 3)
    }

    @MainActor
    func testOrderedListRenumberingUndoesWithTheInsertedItem() throws {
        let original = "1. first\n2. second\n3. third"
        let harness = try EditingWindow(original)
        defer { harness.close() }
        harness.editor.setSelectedRange(NSRange(location: "1. first".utf16.count, length: 0))
        harness.editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        harness.spin()
        XCTAssertEqual(harness.store.text, "1. first\n2. \n3. second\n4. third")
        harness.store.undoManager.undo()
        harness.spin()
        XCTAssertEqual(harness.store.text, original)
    }

    @MainActor
    func testFormattingMenuTokensAndKeyboardShortcuts() throws {
        let harness = try EditingWindow("中文🙂")
        defer { harness.close() }
        let editor = harness.editor
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        harness.store.requestFormat(.bold)
        harness.spin()
        XCTAssertEqual(harness.store.text, "**中文🙂**")
        // A fresh request toggles it; unrelated SwiftUI updates do not replay it.
        harness.store.requestFormat(.bold)
        harness.spin()
        XCTAssertEqual(harness.store.text, "中文🙂")
        XCTAssertTrue(editor.performKeyEquivalent(with: harness.key("i", code: 34, flags: .command)))
        harness.spin()
        XCTAssertEqual(harness.store.text, "*中文🙂*")
        XCTAssertTrue(editor.performKeyEquivalent(with: harness.key("2", code: 19, flags: [.command, .option])))
        harness.spin()
        XCTAssertEqual(harness.store.text, "## *中文🙂*")
        XCTAssertTrue(editor.performKeyEquivalent(with: harness.key("0", code: 29, flags: .command)))
        harness.spin()
        XCTAssertEqual(harness.store.text, "*中文🙂*")
        XCTAssertFalse(editor.performKeyEquivalent(with: harness.key("1", code: 18, flags: .command)))
    }

    @MainActor
    func testFormattingFromReadModeSwitchesToEditorWithoutReplayingInFindFields() throws {
        let harness = try EditingWindow("text")
        defer { harness.close() }
        let editor = harness.editor
        editor.setSelectedRange(NSRange(location: 0, length: 4))
        harness.store.requestFormat(.bold)
        harness.spin()
        XCTAssertEqual(harness.store.text, "**text**")
        harness.store.requestMode(.read)
        harness.spin(for: 0.5)
        harness.store.requestFormat(.italic)
        XCTAssertEqual(harness.store.formatCommand?.action, .italic)
        harness.spin(for: 0.5)
        XCTAssertEqual(harness.store.text, "***text***")
        XCTAssertTrue(harness.store.editorSession.textView === editor)
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 100, height: 24))
        harness.window.contentView?.addSubview(field)
        harness.window.makeFirstResponder(field)
        harness.store.requestFormat(.italic)
        harness.spin()
        XCTAssertEqual(harness.store.text, "***text***")
    }

    @MainActor
    func testChineseMarkedTextLetsReturnAndAllEditingCommandsPassThrough() throws {
        let harness = try EditingWindow("- ")
        defer { harness.close() }
        let editor = harness.editor
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.setMarkedText("wubi", selectedRange: NSRange(location: 4, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        let markedRange = editor.markedRange()
        XCTAssertTrue(editor.hasMarkedText())
        for selector in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)),
                         #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)),
                         #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.cancelOperation(_:))] {
            XCTAssertFalse(harness.store.editorSession.textView(editor, doCommandBy: selector), "\(selector) must reach the input method")
        }
        XCTAssertFalse(editor.performMarkdownAction(.bold))
        harness.store.requestFormat(.italic)
        XCTAssertNil(harness.store.formatCommand)
        XCTAssertEqual(editor.markedRange(), markedRange)
        XCTAssertEqual(editor.string, "- wubi")
        XCTAssertEqual(harness.store.text, "- ", "uncommitted letters must not reach autosave")
        // The NSTextInputClient commit that Chinese IMEs issue for Return.
        editor.insertText("wubi", replacementRange: NSRange(location: NSNotFound, length: 0))
        harness.spin()
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(harness.store.text, "- wubi", "committing Latin letters must not continue the list")
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        harness.spin()
        XCTAssertEqual(harness.store.text, "- wubi\n- ", "only the next Return continues the list")
    }

    @MainActor
    func testFormattingAutosavesThroughTheExistingDocumentPipeline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("md2-editing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.md")
        try "text".write(to: url, atomically: true, encoding: .utf8)
        let harness = try EditingWindow("text", fileURL: url)
        defer { harness.close() }
        XCTAssertFalse(harness.store.isDirty)
        harness.editor.setSelectedRange(NSRange(location: 0, length: 4))
        harness.store.requestFormat(.bold)
        harness.spin()
        XCTAssertTrue(harness.store.isDirty)
        let deadline = Date().addingTimeInterval(7)
        while Date() < deadline, harness.store.isDirty { harness.spin(for: 0.1) }
        XCTAssertFalse(harness.store.isDirty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "**text**")
        XCTAssertTrue(harness.store.undoManager.canUndo)
    }

    @MainActor
    func testPinyinReturnCommitsLatinLettersWithoutContinuingList() throws {
        let harness = try EditingWindow("- ")
        defer { harness.close() }
        let editor = harness.editor
        let context = try XCTUnwrap(editor.inputContext)
        let pinyin = "com.apple.inputmethod.SCIM.ITABC"
        try XCTSkipUnless(context.keyboardInputSources?.contains(pinyin) == true,
                          "Enable Simplified Chinese Pinyin to run the real input-method regression (marked-text contract is tested separately).")
        let original = context.selectedKeyboardInputSource
        defer { context.selectedKeyboardInputSource = original }
        NSApp.activate(ignoringOtherApps: true)
        context.activate()
        context.selectedKeyboardInputSource = pinyin
        harness.spin(for: 0.3)
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        for (character, code): (String, UInt16) in [("w", 13), ("u", 32), ("b", 11), ("i", 34)] {
            editor.keyDown(with: harness.key(character, code: code))
            harness.spin(for: 0.05)
        }
        XCTAssertTrue(editor.hasMarkedText(), "the real Pinyin input method must own the letters before Return")
        editor.keyDown(with: harness.key("\r", code: 36))
        harness.spin()
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(harness.store.text, "- wubi")
        editor.keyDown(with: harness.key("\r", code: 36))
        harness.spin()
        XCTAssertEqual(harness.store.text, "- wubi\n- ")
    }
}

@MainActor
private final class EditingWindow: NSObject, NSWindowDelegate {
    let store = DocumentStore()
    let window: NSWindow
    let suite = "MarkdownEditingGUITests-\(UUID().uuidString)"
    var editor: MarkdownSourceTextView { store.editorSession.textView as! MarkdownSourceTextView }

    init(_ text: String, fileURL: URL? = nil) throws {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.defaultMode = .write
        settings.newDocumentMode = .write
        settings.showsOutlineByDefault = false
        if let fileURL { store.open(fileURL) } else { store.text = text }
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.delegate = self
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
        let hosting = NSHostingView(rootView: ContentView(document: store, settings: settings, onOpen: {}))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        spin(for: 0.4)
        _ = try XCTUnwrap(store.editorSession.textView)
        XCTAssertTrue(window.makeFirstResponder(editor))
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { store.undoManager }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.delegate = nil
        spin()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    func spin(for duration: TimeInterval = 0.15) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            autoreleasepool { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }
    }

    func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
}
