import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

final class PreciseFindGUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 to run interaction GUI tests.")
    }

    @MainActor private func button(_ key: L10nKey, _ harness: InteractionTestWindow) throws -> NSButton {
        if key == .replace || key == .replaceAll {
            // SwiftUI's existing borderless text buttons have empty NSButton
            // titles. Locate their native replacement row, then its two controls.
            let field = try XCTUnwrap(harness.descendants(NSTextField.self).first { $0.placeholderString == harness.settings.text(.replace) })
            let row = field.convert(field.bounds, to: nil)
            let controls = harness.descendants(NSButton.self).filter {
                let frame = $0.convert($0.bounds, to: nil)
                return frame.midY >= row.minY && frame.midY <= row.maxY && frame.minX >= row.maxX
            }.sorted { $0.convert($0.bounds, to: nil).midX < $1.convert($1.bounds, to: nil).midX }
            XCTAssertEqual(controls.count, 2)
            return try XCTUnwrap(key == .replace ? controls.first : controls.last)
        }
        return try XCTUnwrap(harness.descendants(NSButton.self).first { $0.title == harness.settings.text(key) }, "Missing native option: \(key)")
    }

    @MainActor private func wait(_ harness: InteractionTestWindow, _ message: String, _ condition: () -> Bool) throws {
        harness.spin(until: condition)
        _ = try XCTUnwrap(condition() ? true : nil, message)
    }

    @MainActor private func highlighted(_ editor: NSTextView, at index: Int) -> Bool {
        editor.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: index, effectiveRange: nil) != nil
    }

    @MainActor
    func testNativeOptionsReindexSourceAndSelectionReplacementSurvivesReadUndoRedo() throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        harness.store.text = "Cat cat scatter cat"
        harness.host(ContentView(document: harness.store, settings: harness.settings, onOpen: {}))
        let editor = try XCTUnwrap(harness.store.editorSession.textView)
        XCTAssertTrue(harness.window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 4, length: 3))
        harness.store.requestFind(.showReplace)
        try wait(harness, "find fields mounted") { harness.queryField != nil }
        try harness.enterQuery("cat")
        try wait(harness, "default search sees all three forms") { highlighted(editor, at: 0) && highlighted(editor, at: 9) }
        try button(.findMatchCase, harness).performClick(nil)
        try wait(harness, "case option reindexes without query change") { !highlighted(editor, at: 0) && highlighted(editor, at: 4) }
        try button(.findWholeWord, harness).performClick(nil)
        try wait(harness, "whole-word option excludes substring") { !highlighted(editor, at: 9) && highlighted(editor, at: 4) }
        try button(.findOnlySelection, harness).performClick(nil)
        try wait(harness, "scope uses selection captured before query reveal") { harness.store.editorSession.find.range == NSRange(location: 4, length: 3) && !highlighted(editor, at: 16) }
        let replacement = try XCTUnwrap(harness.descendants(NSTextField.self).first { $0.placeholderString == harness.settings.text(.replace) })
        XCTAssertTrue(harness.window.makeFirstResponder(replacement))
        let fieldEditor = try XCTUnwrap(replacement.currentEditor())
        fieldEditor.insertText("😀cat!")
        try button(.replaceAll, harness).performClick(nil)
        try wait(harness, "only frozen range replaced") { harness.store.text == "Cat 😀cat! scatter cat" }
        XCTAssertEqual(harness.store.editorSession.find.range, NSRange(location: 4, length: 6))
        XCTAssertEqual(harness.store.editorSession.find.replacementCount, 1)
        harness.store.requestMode(.read)
        try wait(harness, "Read surface mounted") { !harness.descendants(WKWebView.self).isEmpty }
        harness.store.requestFind(.show)
        try wait(harness, "Read find field mounted") { harness.queryField != nil }
        XCTAssertFalse(try button(.findOnlySelection, harness).isEnabled)
        XCTAssertEqual(harness.store.editorSession.find.range, NSRange(location: 4, length: 6))
        harness.store.undoManager.undo()
        XCTAssertEqual(harness.store.text, "Cat cat scatter cat")
        XCTAssertEqual(harness.store.editorSession.find.range, NSRange(location: 4, length: 3))
        harness.store.undoManager.redo()
        XCTAssertEqual(harness.store.text, "Cat 😀cat! scatter cat")
        harness.store.requestMode(.write)
        try wait(harness, "source editor rehosted") { editor.window === harness.window }
        XCTAssertEqual(harness.store.editorSession.find.range, NSRange(location: 4, length: 6))
        XCTAssertTrue(harness.store.editorSession.find.options.caseSensitive)
        XCTAssertTrue(harness.window.makeFirstResponder(editor))
        editor.insertText("!", replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
        XCTAssertEqual(harness.store.editorSession.find.scope, .invalid)
        harness.store.requestFind(.showReplace)
        try wait(harness, "invalid source bar mounted") { harness.queryField != nil }
        let replaceAll = try button(.replaceAll, harness)
        try wait(harness, "invalid scope remains visible with replacement disabled") { !replaceAll.isEnabled }
        try harness.capture("precise-find-invalid-scope")
    }

    @MainActor
    func testPreviewUsesSharedUnicodeOptionsAndInlineWordBoundaries() throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        harness.store.text = "CAFÉ café cafe\u{301} foo**bar** foo 中文测试 中文 👩‍💻 👩"
        harness.settings.newDocumentMode = .read
        harness.host(ContentView(document: harness.store, settings: harness.settings, onOpen: {}))
        let web = try XCTUnwrap(harness.descendants(WKWebView.self).first)
        harness.store.requestFind(.show)
        try wait(harness, "preview find mounted") { harness.queryField != nil }
        try harness.enterQuery("cafe")
        try harness.waitForPage("document.querySelectorAll('mark.md2-find').length === 3", in: web, context: "preview folds both composed and decomposed accents")
        try button(.findMatchCase, harness).performClick(nil)
        try harness.waitForPage("document.querySelectorAll('mark.md2-find').length === 2", in: web, context: "case change reindexes preview")
        try button(.findWholeWord, harness).performClick(nil)
        try harness.enterQuery("foo")
        try harness.waitForPage("document.querySelectorAll('mark.md2-find').length === 1", in: web, context: "inline strong edge is not a word boundary")
        try harness.enterQuery("中文")
        try harness.waitForPage("document.querySelectorAll('mark.md2-find').length === 1", in: web, context: "Chinese uses continuous Unicode word runs")
        try harness.enterQuery("👩")
        try harness.waitForPage("document.querySelectorAll('mark.md2-find').length === 1 && document.querySelector('mark.md2-find').textContent === '👩'", in: web, context: "emoji grapheme cannot split")
        try harness.enterQuery("foobar")
        try harness.waitForPage("document.querySelectorAll('mark.md2-find').length === 2 && document.querySelectorAll('mark.md2-find-current').length === 2", in: web, context: "one logical match spans inline nodes")
        let result = try harness.js("window.__md2FindNext(true)", web) as? [String: Int]
        XCTAssertEqual(result?["total"], 1)
        XCTAssertEqual(result?["index"], 1)
    }

    @MainActor
    func testPreviewBudgetAndStaleSnapshotsNeverProducePartialMatches() throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        harness.settings.newDocumentMode = .read
        harness.store.text = "needle"
        harness.host(ContentView(document: harness.store, settings: harness.settings, onOpen: {}))
        let web = try XCTUnwrap(harness.descendants(WKWebView.self).first)
        try harness.waitForPage("typeof window.__md2FindSnapshot === 'function'", in: web, context: "preview API ready")
        let stale = try harness.js("""
            const snapshot = window.__md2FindSnapshot();
            document.querySelector('main p').firstChild.nodeValue = 'changed';
            window.__md2Find('needle', {id:snapshot.id,ranges:[[0,6]]}).stale;
            """, web) as? Bool
        XCTAssertEqual(stale, true)
        XCTAssertEqual(try harness.js("document.querySelectorAll('mark.md2-find').length", web) as? Int, 0)
        _ = try harness.js("document.querySelector('main').textContent = 'a'.repeat(20001); true;", web)
        harness.store.requestFind(.show)
        try wait(harness, "preview field mounted") { harness.queryField != nil }
        try harness.enterQuery("a")
        try wait(harness, "over-budget result is explicit") { harness.store.editorSession.find.previewUnavailable }
        XCTAssertEqual(try harness.js("document.querySelectorAll('mark.md2-find').length", web) as? Int, 0)
        _ = try harness.js("document.querySelector('main').textContent = 'x'.repeat(2000001); true;", web)
        XCTAssertEqual(try harness.js("window.__md2FindSnapshot().unavailable", web) as? Bool, true)
    }

    @MainActor
    func testAllOptionsAndInvalidScopeFitAt360PointsInBothLanguages() throws {
        for language in [AppLanguage.english, .zhHans] {
            for scope in [FindSession.Scope.document, .selection(NSRange(location: 2, length: 5)), .invalid] {
                let harness = InteractionTestWindow()
                defer { harness.close() }
                harness.settings.language = language
                let find = FindSession()
                find.scope = scope
                let bar = EditorFindBar(query: .constant("needle"), replacement: .constant("replacement"),
                    showsReplace: true, focusToken: UUID(), statusText: "999 of 999", settings: harness.settings,
                    onSubmitQuery: {}, onNext: {}, onPrevious: {}, onReplace: {}, onReplaceAll: {}, onClose: {},
                    findSession: find, matchCount: 999)
                let measurement = NativeFindBarController(rootView: bar)
                for width: CGFloat? in [nil, .infinity, 360] {
                    let size = measurement.barSize(for: width)
                    XCTAssertTrue(size.width.isFinite && size.height.isFinite && size.height > 0)
                }
                harness.host(NativeFindBar(pane: .editor) { bar }.frame(width: 360), width: 360, height: 250)
                for control in harness.descendants(NSButton.self).map({ $0 as NSView }) + harness.descendants(NSTextField.self).filter({ $0.isEditable }) {
                    let frame = harness.window.convertToScreen(control.convert(control.bounds, to: nil))
                    XCTAssertFalse(frame.isEmpty)
                    XCTAssertTrue(harness.screenBounds.insetBy(dx: -1, dy: -1).contains(frame), "\(language) \(scope): clipped control \(frame)")
                }
                XCTAssertTrue(try button(.findMatchCase, harness).isEnabled)
                XCTAssertTrue(try button(.findWholeWord, harness).isEnabled)
                for field in harness.descendants(NSTextField.self).filter({ $0.isEditable }) {
                    XCTAssertGreaterThan(field.frame.width, 35)
                    XCTAssertTrue(harness.window.makeFirstResponder(field))
                }
                try harness.capture("precise-find-\(language.rawValue)-\(scope == .invalid ? "invalid" : (scope == .document ? "all" : "selection"))")
            }
        }
    }
}
