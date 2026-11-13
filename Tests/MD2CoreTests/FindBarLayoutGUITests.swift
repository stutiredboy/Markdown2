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
        var outlierDiagnostics: [String] = []
        defer {
            if !outlierDiagnostics.isEmpty {
                FileHandle.standardError.write(Data((outlierDiagnostics.joined(separator: "\n") + "\n").utf8))
            }
        }
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
                // Document-wide controls can live above the split. Identify the
                // native find owner, then measure every control in that bar;
                // geometry must never decide which find controls are tested.
                let controls = try editorFindControls(in: harness)
                for control in harness.descendants(NSButton.self).map({ $0 as NSView }) + harness.descendants(NSTextField.self).filter({ $0.isEditable }) {
                    let frame = harness.window.convertToScreen(control.convert(control.bounds, to: nil))
                    if !bounds.insetBy(dx: -1, dy: -1).contains(frame) {
                        outlierDiagnostics.append(controlIdentity(control, frame: frame, editorBounds: bounds,
                            language: language.rawValue, query: query))
                    }
                }
                for control in controls {
                    let frame = harness.window.convertToScreen(control.convert(control.bounds, to: nil))
                    XCTAssertTrue(bounds.insetBy(dx: -1, dy: -1).contains(frame), "\(language) query=\(query): \(frame) outside editor \(bounds)")
                    XCTAssertGreaterThanOrEqual(frame.minY, sourceBounds.maxY - 1, "the bar must not obscure source text")
                }
                try harness.capture("split-\(language.rawValue)-\(query.isEmpty ? "empty" : query)")
            }
        }
    }

    @MainActor
    private func editorFindControls(in harness: InteractionTestWindow) throws -> [NSView] {
        let query = try XCTUnwrap(harness.queryField)
        var owners: [NSViewController] = []
        var responder: NSResponder? = query
        while let current = responder, current !== harness.window {
            if let owner = current as? NativeFindPaneOwner {
                XCTAssertTrue(owner.findPane == .editor)
                owners.append(try XCTUnwrap(current as? NSViewController))
            }
            responder = current.nextResponder
        }
        XCTAssertEqual(owners.count, 1, "the query must belong to exactly one native editor find bar")
        let root = try XCTUnwrap(owners.first).view
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(root)
        let buttons = views.compactMap { $0 as? NSButton }
        let fields = views.compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        XCTAssertEqual(buttons.count, 8, "previous, next, close, three options, replace, replace all")
        XCTAssertEqual(fields.count, 2, "query and replacement must both be measured")
        XCTAssertTrue(fields.contains { $0 === query })
        XCTAssertEqual(fields.filter { $0.placeholderString == harness.settings.text(.replace) }.count, 1)
        return buttons.map { $0 as NSView } + fields
    }

    /// Keep unrelated whole-window outliers visible in CI evidence. This does
    /// not determine membership or change any find-control geometry assertion.
    @MainActor
    private func controlIdentity(_ control: NSView, frame: NSRect, editorBounds: NSRect,
                                 language: String, query: String) -> String {
        var owner = "none"
        var responder: NSResponder? = control
        while let current = responder {
            if let paneOwner = current as? NativeFindPaneOwner { owner = String(describing: paneOwner.findPane) }
            responder = current.nextResponder
        }
        let row: [String: String] = ["language": language, "query": query,
            "class": String(describing: type(of: control)), "title": (control as? NSButton)?.title ?? "",
            "identifier": control.accessibilityIdentifier() ?? "", "owner": owner,
            "frame": NSStringFromRect(frame), "editor": NSStringFromRect(editorBounds)]
        let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        return "MD2_FIND_LAYOUT_OUTLIER " + String(decoding: data, as: UTF8.self)
    }


}
