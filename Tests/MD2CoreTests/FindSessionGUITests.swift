import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

final class FindSessionGUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 to run interaction GUI tests.")
    }

    @MainActor
    func testUnchangedFindFieldFocusRoutesMenuNavigationToItsSplitPane() throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        harness.settings.newDocumentMode = .split
        harness.store.text = "needle one\n\nneedle two\n\nneedle three"
        harness.host(ContentView(document: harness.store, settings: harness.settings, onOpen: {}))
        let editor = try XCTUnwrap(harness.store.editorSession.textView)
        let web = try XCTUnwrap(harness.descendants(WKWebView.self).first)
        harness.store.requestFind(.show)
        harness.spin()
        try harness.enterQuery("needle")
        harness.spin(for: 0.4)
        let show = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                   timestamp: 0, windowNumber: harness.window.windowNumber, context: nil,
                                   characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
        XCTAssertTrue(web.performKeyEquivalent(with: show))
        harness.spin(for: 0.4)
        harness.store.requestFind(.next)
        harness.spin()
        let index = "Array.from(document.querySelectorAll('mark.md2-find')).findIndex(e=>e.classList.contains('md2-find-current'))"
        XCTAssertEqual(try harness.js(index, web) as? Int, 1)
        let fields = harness.descendants(NSTextField.self).filter { $0.placeholderString == harness.settings.text(.findPlaceholder) }
        XCTAssertEqual(fields.count, 2)
        let sourceField = try XCTUnwrap(fields.min { $0.convert($0.bounds, to: nil).midX < $1.convert($1.bounds, to: nil).midX })
        XCTAssertTrue(harness.window.makeFirstResponder(sourceField))
        harness.spin()
        XCTAssertTrue(sourceField.currentEditor() === harness.window.firstResponder, "source find field must own keyboard")
        // Merely refocus the unchanged query. No binding setter fires here.
        harness.store.requestFind(.next)
        harness.spin()
        XCTAssertEqual(editor.selectedRange().location, 18)
        XCTAssertEqual(try harness.js(index, web) as? Int, 1, "menu navigation must leave the other pane's match alone")
    }

    @MainActor
    func testPreviewNavigationWaitsForPendingSearchAfterModeSwitch() throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        let web = WKWebView(frame: .zero)
        let coordinator = MarkdownPreviewView.Coordinator()
        // Real WebKit, held before didFinish, with the same page API contract.
        _ = try harness.js("""
            window.index = 0;
            window.__md2Find = function(q) { window.index = 1; return {total:3,index:window.index}; };
            window.__md2FindNext = function(forward) { window.index += forward ? 1 : -1; return {total:3,index:window.index}; };
            true;
            """, web)
        coordinator.runFindWhenReady("needle", in: web)
        coordinator.handleFindNavigation(.next, in: web)
        coordinator.handleFindNavigation(.next, in: web)
        coordinator.handleFindNavigation(.previous, in: web)
        XCTAssertEqual(try harness.js("window.index", web) as? Int, 0, "navigation must wait for the incoming page's matches")
        coordinator.webView(web, didFinish: nil)
        harness.spin(for: 0.3)
        XCTAssertEqual(try harness.js("window.index", web) as? Int, 2, "queued commands execute once and in order after search")
    }

    @MainActor
    func testHiddenFindNavigatesAndReopensWithLastQueryAcrossAllModes() throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        let original = "needle one\n\nneedle two\n\n[needle three](https://example.com/needle)"
        harness.store.text = original
        harness.host(ContentView(document: harness.store, settings: harness.settings, onOpen: {}))
        let editor = try XCTUnwrap(harness.store.editorSession.textView)
        harness.store.requestFind(.show)
        harness.spin()
        try harness.enterQuery("needle")
        harness.spin(for: 0.5)
        XCTAssertEqual(editor.selectedRange().location, 6)
        try harness.press(.closeFind)
        XCTAssertTrue(editor.performKeyEquivalent(with: harness.findKey()))
        harness.spin()
        XCTAssertEqual(editor.selectedRange().location, 18)
        XCTAssertNil(harness.queryField)
        XCTAssertTrue(editor.performKeyEquivalent(with: harness.findKey(previous: true)))
        harness.spin()
        XCTAssertEqual(editor.selectedRange().location, 6)
        XCTAssertTrue(editor.performKeyEquivalent(with: harness.findKey(previous: true)))
        harness.spin()
        let sourceOnlyMatch = (original as NSString).range(of: "needle", options: .backwards)
        XCTAssertEqual(editor.selectedRange().location, NSMaxRange(sourceOnlyMatch), "source search includes link destinations")
        XCTAssertTrue(editor.performKeyEquivalent(with: harness.findKey()))
        harness.spin()
        XCTAssertEqual(editor.selectedRange().location, 6)
        harness.store.requestFind(.show)
        harness.spin()
        XCTAssertEqual(harness.queryField?.stringValue, "needle")
        try harness.press(.closeFind)

        harness.store.requestMode(.read)
        harness.spin(until: { harness.descendants(WKWebView.self).first != nil && editor.window == nil })
        let web = try XCTUnwrap(harness.descendants(WKWebView.self).first)
        harness.spin(for: 1.2)
        XCTAssertEqual(try harness.js("document.querySelectorAll('mark.md2-find').length", web) as? Int, 3)
        XCTAssertTrue(web.performKeyEquivalent(with: harness.findKey()))
        harness.spin()
        XCTAssertEqual(try harness.js("Array.from(document.querySelectorAll('mark.md2-find')).findIndex(e=>e.classList.contains('md2-find-current'))", web) as? Int, 1)
        XCTAssertNil(harness.queryField)
        XCTAssertTrue(web.performKeyEquivalent(with: harness.findKey(previous: true)))
        harness.spin()
        XCTAssertEqual(try harness.js("Array.from(document.querySelectorAll('mark.md2-find')).findIndex(e=>e.classList.contains('md2-find-current'))", web) as? Int, 0)
        harness.store.requestFind(.show)
        harness.spin()
        XCTAssertEqual(harness.queryField?.stringValue, "needle")
        try harness.press(.closeFind)

        harness.store.requestMode(.split)
        harness.spin(until: { editor.window != nil })
        harness.spin(for: 0.6)
        harness.store.requestFind(.next)
        harness.spin()
        XCTAssertEqual(editor.selectedRange().location, 18)
        XCTAssertNil(harness.queryField)
        XCTAssertEqual(harness.store.text, original)
    }
}
