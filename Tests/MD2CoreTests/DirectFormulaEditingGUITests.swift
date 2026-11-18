import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

final class DirectFormulaEditingGUITests: XCTestCase {
    private let selector = "button.md2-formula-action[data-md2-formula-line]"

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 to exercise native formula editing.")
    }

    @MainActor
    func testKeyboardEditsTheSecondIdenticalFormulaAndUndoRestoresExactFileBytes() throws {
        let before = "# 🧭 Cafe\u{301}\r\n\r\n$$ x^2 + 1 $$\n\n重复公式\r\r  $$  "
        let after = "  $$ \t\r\n\r\n尾部🧪\n"
        let original = before + "x^2 + 1" + after
        let replacement = #"\sqrt{7} + 2"#
        let edited = before + replacement + after
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("md2-formula-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Mixed.md")
        try bytes(original).write(to: file)

        let h = InteractionTestWindow(store: DocumentStore(autosaveDelay: 60, maximumAutosaveDelay: 60))
        defer { close(h) }
        h.store.open(file)
        XCTAssertFalse(h.store.isDirty)
        let web = try mountReader(h, actions: 2)

        // Page script must not be able to turn a rendered control into a native command.
        _ = try h.js("document.querySelectorAll('\(selector)')[1].click(); true", web)
        h.spin()
        XCTAssertNil(h.window.attachedSheet)
        XCTAssertFalse(h.store.undoManager.canUndo)

        try tabToAction(0, in: web, h)
        try tabToAction(1, in: web, h)
        XCTAssertEqual(try h.js("document.activeElement.getAttribute('aria-label')", web) as? String, "Edit Formula…")
        try sendKey(code: 49, characters: " ", in: web, window: h.window)
        let (sheet, field) = try formulaSheet(h)
        XCTAssertEqual(field.string, "x^2 + 1")
        XCTAssertEqual(field.accessibilityLabel(), "Formula (TeX)")
        XCTAssertEqual(field.accessibilityRole(), .textArea)
        XCTAssertTrue(sheet.firstResponder === field, "the formula input must start with keyboard focus")
        XCTAssertEqual(bytes(h.store.text), bytes(original))
        XCTAssertEqual(try Data(contentsOf: file), bytes(original))

        replaceInput(replacement, in: field)
        let apply = try button("formula-apply", in: sheet, h)
        XCTAssertTrue(apply.isEnabled)
        let applyKey = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: sheet.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
        sheet.sendEvent(applyKey)
        h.spin(until: { h.window.attachedSheet == nil && bytes(h.store.text) == bytes(edited) })
        XCTAssertNil(h.window.attachedSheet)
        XCTAssertEqual(bytes(h.store.text), bytes(edited))
        XCTAssertTrue(h.store.isDirty)
        XCTAssertNil(h.store.editorSession.textView?.window, "the normal command stays in Read")
        try h.waitForPage("document.querySelectorAll('\(selector)').length === 2 && document.querySelectorAll('.katex').length === 2", in: web,
                          context: "both display formulas still render after Apply")
        XCTAssertTrue(h.store.save())
        XCTAssertEqual(try Data(contentsOf: file), bytes(edited))

        XCTAssertTrue(h.store.undoManager.canUndo)
        h.store.undoManager.undo()
        XCTAssertEqual(bytes(h.store.text), bytes(original))
        XCTAssertFalse(h.store.undoManager.canUndo, "applying the formula contributes exactly one document Undo step")
        XCTAssertTrue(h.store.save())
        XCTAssertEqual(try Data(contentsOf: file), bytes(original))
        XCTAssertTrue(h.store.undoManager.canRedo)
        h.store.undoManager.redo()
        XCTAssertEqual(bytes(h.store.text), bytes(edited))
        XCTAssertFalse(h.store.undoManager.canRedo)
    }

    @MainActor
    func testInvalidInputAndMarkedTextCannotCommitAndCancelDiscardsInput() throws {
        let h = InteractionTestWindow()
        defer { close(h) }
        let original = "$$  x + 1  $$"
        h.store.text = original
        let web = try mountReader(h, actions: 1)
        try tabToAction(0, in: web, h)
        try sendKey(code: 49, characters: " ", in: web, window: h.window)
        let (sheet, field) = try formulaSheet(h)
        let apply = try button("formula-apply", in: sheet, h)

        replaceInput("x $$ y", in: field)
        h.spin(until: { !apply.isEnabled })
        XCTAssertFalse(apply.isEnabled, "entering a delimiter would make the authored Markdown ambiguous")
        XCTAssertEqual(bytes(h.store.text), bytes(original))

        replaceInput("x + 2", in: field)
        h.spin(until: { apply.isEnabled })
        XCTAssertTrue(apply.isEnabled)
        field.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0),
                            replacementRange: NSRange(location: field.string.utf16.count, length: 0))
        XCTAssertTrue(field.hasMarkedText(), "exercise AppKit's marked-text state in the actual formula input")
        h.spin(until: { !apply.isEnabled })
        XCTAssertFalse(apply.isEnabled)
        apply.performClick(nil)
        XCTAssertEqual(bytes(h.store.text), bytes(original))
        XCTAssertFalse(h.store.undoManager.canUndo)

        // Commit to the field only, then dismiss the sheet with valid text present.
        field.unmarkText()
        replaceInput("x + 3", in: field)
        h.spin(until: { apply.isEnabled })
        XCTAssertTrue(apply.isEnabled)
        try button("formula-cancel", in: sheet, h).performClick(nil)
        h.spin(until: { h.window.attachedSheet == nil })
        XCTAssertNil(h.window.attachedSheet)
        XCTAssertEqual(bytes(h.store.text), bytes(original))
        XCTAssertFalse(h.store.undoManager.canUndo)
    }

    @MainActor
    func testUnsupportedMultilineFormulaOpensItsSourceWithoutEditing() throws {
        let h = InteractionTestWindow()
        defer { close(h) }
        let original = "# 表格🧭\r\n\r\n$$\r\nx + y\r\n$$\r\n\r\n尾部\n"
        h.store.text = original
        let web = try mountReader(h, actions: 1)
        try tabToAction(0, in: web, h)
        XCTAssertEqual(try h.js("document.activeElement.getAttribute('aria-label')", web) as? String, "Open Formula in Source…")
        try sendKey(code: 49, characters: " ", in: web, window: h.window)
        let sheet = try attachedSheet(h)
        XCTAssertNil(input(in: sheet, h), "the unsupported form has no direct editing field")
        let open = try button("formula-open-source", in: sheet, h)
        XCTAssertEqual(open.title, "Open Source")
        XCTAssertEqual(bytes(h.store.text), bytes(original))
        open.performClick(nil)
        let openingLine = (original as NSString).range(of: "$$\r\n")
        h.spin(until: {
            guard let editor = h.store.editorSession.textView else { return false }
            return editor.window === h.window && editor.selectedRange() == openingLine
        })
        let editor = try XCTUnwrap(h.store.editorSession.textView)
        try h.waitForTarget(openingLine, in: editor, context: "unsupported formula source selection")
        XCTAssertTrue(h.window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), openingLine)
        XCTAssertEqual(bytes(editor.string), bytes(original))
        XCTAssertFalse(h.store.undoManager.canUndo)
    }

    @MainActor
    func testAFormulaDialogCannotOverwriteADifferentSourceRevision() throws {
        let h = InteractionTestWindow()
        defer { close(h) }
        let original = "Cafe\u{301}\n\n$$ x + 1 $$"
        // These prefixes are canonically equivalent. The rendered formula body
        // stays the same while its exact UTF-16 offset moves by one code unit.
        let newer = "Caf\u{e9}\n\n$$ x + 1 $$"
        h.store.text = original
        let web = try mountReader(h, actions: 1)
        try tabToAction(0, in: web, h)
        try sendKey(code: 49, characters: " ", in: web, window: h.window)
        let (sheet, field) = try formulaSheet(h)
        replaceInput("x + 2", in: field)
        let apply = try button("formula-apply", in: sheet, h)
        XCTAssertTrue(apply.isEnabled)
        h.store.text = newer
        if h.window.attachedSheet === sheet { apply.performClick(nil) }
        h.spin()
        XCTAssertEqual(bytes(h.store.text), bytes(newer))
        XCTAssertFalse(h.store.undoManager.canUndo, "a stale request leaves no document Undo entry")
    }

    @MainActor
    func testReplacementThatChangesBlockParsingKeepsTheDraftForCorrection() throws {
        let h = InteractionTestWindow()
        defer { close(h) }
        let original = "| Header |\n| ------ |\n$$x+y$$\n"
        h.store.text = original
        let web = try mountReader(h, actions: 1)
        try tabToAction(0, in: web, h)
        try sendKey(code: 49, characters: " ", in: web, window: h.window)
        let (sheet, field) = try formulaSheet(h)
        let apply = try button("formula-apply", in: sheet, h)

        // The pipe would turn the formula line into part of the preceding table.
        replaceInput("x|y", in: field)
        XCTAssertTrue(apply.isEnabled, "the draft must reach parser validation")
        apply.performClick(nil)
        let rejectedMessage = h.settings.text(.formulaReplacementRequiresSource)
        func showsRejection() -> Bool {
            guard let content = sheet.contentView else { return false }
            return h.descendants(NSTextField.self, in: content).contains { $0.stringValue == rejectedMessage }
        }
        h.spin(until: showsRejection)
        XCTAssertTrue(showsRejection())
        XCTAssertTrue(h.window.attachedSheet === sheet)
        XCTAssertTrue(field.isEditable)
        XCTAssertTrue(sheet.firstResponder === field)
        XCTAssertEqual(field.string, "x|y")
        XCTAssertTrue(try button("formula-open-source", in: sheet, h).isEnabled)
        XCTAssertEqual(bytes(h.store.text), bytes(original))
        XCTAssertFalse(h.store.undoManager.canUndo)

        replaceInput("x+z", in: field)
        apply.performClick(nil)
        h.spin(until: { h.window.attachedSheet == nil })
        XCTAssertNil(h.window.attachedSheet)
        XCTAssertEqual(bytes(h.store.text), bytes("| Header |\n| ------ |\n$$x+z$$\n"))
        XCTAssertTrue(h.store.undoManager.canUndo)
    }

    private func bytes(_ text: String) -> Data { Data(text.utf8) }

    @MainActor
    private func mountReader(_ h: InteractionTestWindow, actions: Int) throws -> WKWebView {
        h.settings.language = .english
        h.settings.defaultMode = .read
        h.settings.newDocumentMode = .read
        h.host(ContentView(document: h.store, settings: h.settings, onOpen: {}))
        h.spin(until: { !h.descendants(WKWebView.self).isEmpty })
        let web = try XCTUnwrap(h.descendants(WKWebView.self).first)
        try h.waitForPage("document.querySelectorAll('\(selector)').length === \(actions)", in: web,
                          context: "native Read formula actions on the loaded page")
        XCTAssertTrue(h.window.makeFirstResponder(web))
        return web
    }

    @MainActor
    private func tabToAction(_ index: Int, in web: WKWebView, _ h: InteractionTestWindow) throws {
        try sendKey(code: 48, characters: "\t", in: web, window: h.window)
        try h.waitForPage("document.activeElement === document.querySelectorAll('\(selector)')[\(index)]",
                          in: web, context: "Tab focuses formula action \(index + 1)")
    }

    @MainActor
    private func sendKey(code: UInt16, characters: String, in web: WKWebView, window: NSWindow) throws {
        for type: NSEvent.EventType in [.keyDown, .keyUp] {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            ))
            if type == .keyDown { web.keyDown(with: event) } else { web.keyUp(with: event) }
        }
    }

    @MainActor
    private func attachedSheet(_ h: InteractionTestWindow) throws -> NSWindow {
        h.spin(until: { h.window.attachedSheet != nil })
        return try XCTUnwrap(h.window.attachedSheet, "native activation must present a sheet on the document window")
    }

    @MainActor
    private func formulaSheet(_ h: InteractionTestWindow) throws -> (NSWindow, NSTextView) {
        let sheet = try attachedSheet(h)
        h.spin(until: { self.input(in: sheet, h) != nil })
        return (sheet, try XCTUnwrap(input(in: sheet, h), "the formula editor must be a native text area"))
    }

    @MainActor
    private func input(in sheet: NSWindow, _ h: InteractionTestWindow) -> NSTextView? {
        guard let content = sheet.contentView else { return nil }
        return h.descendants(NSTextView.self, in: content).first { $0.accessibilityIdentifier() == "formula-source-input" }
    }

    @MainActor
    private func button(_ id: String, in sheet: NSWindow, _ h: InteractionTestWindow) throws -> NSButton {
        let content = try XCTUnwrap(sheet.contentView)
        return try XCTUnwrap(h.descendants(NSButton.self, in: content).first { $0.accessibilityIdentifier() == id },
                             "sheet action \(id)")
    }

    @MainActor
    private func replaceInput(_ text: String, in field: NSTextView) {
        field.insertText(text, replacementRange: NSRange(location: 0, length: field.string.utf16.count))
    }

    @MainActor
    private func close(_ h: InteractionTestWindow) {
        if let sheet = h.window.attachedSheet { h.window.endSheet(sheet, returnCode: .cancel) }
        h.store.closeDocument(discardRecovery: true)
        h.close()
    }
}
