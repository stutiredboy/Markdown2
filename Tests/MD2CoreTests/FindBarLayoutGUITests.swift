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

    @MainActor func testPreviewFindLeavesTheHeadingMatchAndScrollbarAccessibleAt980Points() throws {
        let filler = String(repeating: "Filler paragraph.\n\n", count: 65)
        for mode in [EditorMode.read, .split] {
            for isLong in [false, true] {
                let h = InteractionTestWindow()
                defer { h.close() }
                h.settings.newDocumentMode = mode
                h.store.text = isLong
                    ? filler + "# Middle section\n\nNeedle in this section.\n\n" + filler
                    : "# Needle in the heading\n\nFirst line below it."
                h.host(ContentView(document: h.store, settings: h.settings, onOpen: {}), width: 980)
                let web = try XCTUnwrap(h.descendants(WKWebView.self).first)
                try h.waitForPage("document.querySelector('h1')?.nextElementSibling?.tagName === 'P'",
                                  in: web, context: "fixture loaded")
                let show = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber,
                    context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
                XCTAssertTrue(web.performKeyEquivalent(with: show))
                h.spin(until: { h.queryField != nil })
                try h.enterQuery("Needle")
                let visible = """
                    (() => {
                        const heading = document.querySelector('main h1');
                        const current = document.querySelector('mark.md2-find-current');
                        return !!current && [heading, heading.nextElementSibling, current].every(element => {
                            const r = element.getBoundingClientRect();
                            return r.height > 0 && r.top >= 0 && r.bottom <= innerHeight;
                        });
                    })()
                    """
                try h.waitForPage(visible, in: web, context: "visible heading, first line and hit in \(mode), long=\(isLong)")
                var responder: NSResponder? = h.queryField
                while let current = responder, !(current is NativeFindPaneOwner) { responder = current.nextResponder }
                XCTAssertEqual((responder as? NativeFindPaneOwner)?.findPane, .preview)
                let bar = try XCTUnwrap((responder as? NSViewController)?.view)
                let viewport = web.convert(web.bounds, to: nil)
                let findBounds = bar.convert(bar.bounds, to: nil)
                XCTAssertGreaterThan(findBounds.height, 20)
                XCTAssertGreaterThanOrEqual(findBounds.minY, viewport.maxY - 0.5,
                    "Find covers the WebKit viewport in \(mode): \(findBounds) vs \(viewport)")
                let root = try XCTUnwrap(h.window.contentView)
                for y in [viewport.minY + 2, viewport.midY, viewport.maxY - 2] {
                    let edge = NSPoint(x: viewport.maxX - 2, y: y)
                    let hit = try XCTUnwrap(root.hitTest(root.convert(edge, from: nil)))
                    XCTAssertTrue(hit === web || hit.isDescendant(of: web),
                                  "preview scrollbar lane hits \(hit) instead of WebKit in \(mode)")
                }
                try verifyPaintedMatch(in: web, h, name: "preview-find-\(mode.rawValue)-\(isLong ? "middle" : "first-line")")
                if isLong { try scrollViaTrack(in: web, h) }
            }
        }
    }

    /// AppKit can cache an earlier frame of WebKit's remote layer even after a
    /// DOM geometry read. Inspect the painted match in WebKit's own snapshot.
    @MainActor private func verifyPaintedMatch(in web: WKWebView, _ h: InteractionTestWindow, name: String) throws {
        let metrics = try XCTUnwrap(try h.js("""
            (() => {
                const m = document.querySelector('mark.md2-find-current'), r = m.getBoundingClientRect();
                const rgb = getComputedStyle(m).backgroundColor.match(/[0-9.]+/g).map(Number);
                return [r.left, r.top, r.width, r.height, ...rgb];
            })()
            """, web) as? [CGFloat])
        XCTAssertEqual(metrics.count, 7)
        guard metrics.count == 7 else { return }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        let done = expectation(description: "WebKit paints the located match")
        var image: NSImage?
        web.takeSnapshot(with: config) { value, _ in image = value; done.fulfill() }
        wait(for: [done], timeout: 8)
        let frame = try XCTUnwrap(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let sx = CGFloat(frame.width) / web.bounds.width, sy = CGFloat(frame.height) / web.bounds.height
        let box = CGRect(x: metrics[0] * sx, y: metrics[1] * sy, width: metrics[2] * sx, height: metrics[3] * sy)
        let crop = try XCTUnwrap(frame.cropping(to: box.integral))
        // Render into a known sRGB byte layout. AppKit's colorAt may label RGB
        // bytes as calibrated RGB and convert them a second time on readback.
        let width = 12, height = 8, bytesPerPixel = 4
        let colors = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let sample = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * bytesPerPixel, space: colors, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        sample.interpolationQuality = .none
        sample.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = try XCTUnwrap(sample.data).assumingMemoryBound(to: UInt8.self)
        let matching = (0..<(width * height)).filter { index in
            (0..<3).allSatisfy { channel in
                abs(CGFloat(bytes[index * bytesPerPixel + channel]) - metrics[4 + channel]) < 10
            }
        }
        XCTAssertGreaterThan(matching.count, 12, "only \(matching.count) of 96 points paint the match background at \(box) in \(name)")
        if let dir = ProcessInfo.processInfo.environment["MD2_INTERACTION_EVIDENCE_DIR"] {
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }

    @MainActor private func scrollViaTrack(in web: WKWebView, _ h: InteractionTestWindow) throws {
        let foundAt = try XCTUnwrap(try h.js("scrollY", web) as? Double)
        XCTAssertGreaterThan(foundAt, 0, "Find must reach the middle of the document")
        // Wake the transient system scrollbar on Macs configured to hide it.
        // The track click must then advance past the original match position.
        _ = try h.js("scrollBy(0, -8); true", web)
        let location = web.convert(NSPoint(x: web.bounds.maxX - 5, y: web.bounds.height * 0.85), to: nil)
        for kind: NSEvent.EventType in [.mouseMoved, .leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: kind == .mouseMoved ? 0 : 1, pressure: kind == .leftMouseDown ? 1 : 0))
            switch kind {
            case .mouseMoved: web.mouseMoved(with: event)
            case .leftMouseDown: web.mouseDown(with: event)
            default: web.mouseUp(with: event)
            }
        }
        try h.waitForPage("scrollY > \(foundAt + 10)", in: web,
                          context: "native track click advances scrollbar past \(foundAt)")
        XCTAssertNotNil(h.queryField)
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
        XCTAssertEqual(buttons.count, 9, "previous, next, close, four options, replace, replace all")
        XCTAssertEqual(buttons.filter { $0.accessibilityIdentifier() == "findRegex" }.count, 1)
        XCTAssertEqual(fields.count, 2, "query and replacement must both be measured")
        XCTAssertTrue(fields.contains { $0 === query })
        XCTAssertEqual(fields.filter { $0.placeholderString == harness.settings.text(.replaceWith) }.count, 1)
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
