import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

final class FindBarLayoutGUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 to run interaction GUI tests.")
    }

    @MainActor
    func testFindReplaceControlsFitAtMinimumEditorWidthInBothLanguages() throws {
        for language in [AppLanguage.english, .zhHans] {
            for query in ["", "needle", "missing"] {
                let harness = InteractionTestWindow()
                defer { harness.close() }
                harness.settings.language = language
                var pressed = Set<String>()
                var queryValue = query
                var replacement = "replacement"
                let bar = EditorFindBar(
                    query: Binding(get: { queryValue }, set: { queryValue = $0 }),
                    replacement: Binding(get: { replacement }, set: { replacement = $0 }),
                    showsReplace: true, focusToken: UUID(),
                    statusText: query.isEmpty ? "" : (query == "missing" ? harness.settings.text(.noResults) : "999 of 999"),
                    settings: harness.settings, onSubmitQuery: {},
                    onNext: { pressed.insert("next") }, onPrevious: { pressed.insert("previous") },
                    onReplace: { pressed.insert("replace") }, onReplaceAll: { pressed.insert("all") },
                    onClose: { pressed.insert("close") })
                let measurement = NativeFindBarController(rootView: bar)
                let widths: [CGFloat?] = [nil, .infinity, DocumentLayoutMetrics.splitEditorMinWidth]
                for width in widths {
                    let size = measurement.barSize(for: width)
                    XCTAssertTrue(size.width.isFinite && size.height.isFinite && size.height > 0,
                                  "\(language) query=\(query): invalid native bar measurement \(size) at width \(String(describing: width))")
                }
                harness.host(NativeFindBar(pane: .editor) { bar }.frame(width: DocumentLayoutMetrics.splitEditorMinWidth),
                             width: 360, height: 150)
                let buttons = harness.descendants(NSButton.self)
                XCTAssertEqual(buttons.count, 5)
                for (index, button) in buttons.enumerated() {
                    let frame = harness.window.convertToScreen(button.convert(button.bounds, to: nil))
                    XCTAssertFalse(frame.isEmpty)
                    XCTAssertTrue(harness.screenBounds.insetBy(dx: -1, dy: -1).contains(frame),
                                  "\(language) query=\(query): button \(index) \(frame) outside \(harness.screenBounds)")
                    if button.isEnabled { button.performClick(nil); harness.spin() }
                }
                XCTAssertEqual(pressed, query.isEmpty ? ["close"] : ["previous", "next", "close", "replace", "all"])
                for field in harness.descendants(NSTextField.self).filter({ $0.isEditable }) {
                    let frame = harness.window.convertToScreen(field.convert(field.bounds, to: nil))
                    XCTAssertTrue(harness.screenBounds.insetBy(dx: -1, dy: -1).contains(frame),
                                  "\(language) field clipped: \(frame)")
                    XCTAssertGreaterThan(frame.width, 35)
                    XCTAssertTrue(harness.window.makeFirstResponder(field))
                }
            }
        }
    }

    @MainActor
    func testSplitWithOutlineKeepsFindControlsInside360PointEditor() throws {
        for language in [AppLanguage.english, .zhHans] {
            let harness = InteractionTestWindow()
            defer { harness.close() }
            harness.settings.language = language
            harness.settings.newDocumentMode = .split
            harness.settings.showsOutlineByDefault = true
            harness.store.text = "# Heading\n\nneedle one\n\nneedle two"
            harness.host(ContentView(document: harness.store, settings: harness.settings, onOpen: {}), width: 1046)
            let split = try XCTUnwrap(harness.descendants(NSSplitView.self).first)
            split.setPosition(360, ofDividerAt: 0)
            harness.spin()
            harness.store.requestFind(.showReplace)
            harness.spin()
            for query in ["", "needle", "missing"] {
                try harness.enterQuery(query)
                harness.spin(for: 0.4)
                let editor = try XCTUnwrap(harness.store.editorSession.textView)
                let pane = try XCTUnwrap(split.subviews.first)
                let bounds = harness.window.convertToScreen(pane.convert(pane.bounds, to: nil))
                let scroll = try XCTUnwrap(editor.enclosingScrollView)
                let sourceBounds = harness.window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
                XCTAssertEqual(bounds.width, 360, accuracy: 1)
                for control in harness.descendants(NSButton.self).map({ $0 as NSView }) + harness.descendants(NSTextField.self).filter({ $0.isEditable }) {
                    let frame = harness.window.convertToScreen(control.convert(control.bounds, to: nil))
                    XCTAssertTrue(bounds.insetBy(dx: -1, dy: -1).contains(frame), "\(language) query=\(query): \(frame) outside editor \(bounds)")
                    XCTAssertGreaterThanOrEqual(frame.minY, sourceBounds.maxY - 1, "the bar must not obscure source text")
                }
                try harness.capture("split-\(language.rawValue)-\(query.isEmpty ? "empty" : query)")
            }
        }
    }


}
