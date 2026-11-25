import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

final class HalfScreenWindowGUITests: XCTestCase {
    @MainActor
    func testResizeAndModeSwitchKeepTheDocumentAndScrollbarsUsable() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1", "Requires AppKit and WebKit")
        let h = InteractionTestWindow()
        defer { h.close() }
        h.settings.showsOutlineByDefault = true
        h.store.text = "# Document\n\n" + String(repeating: "A paragraph for scrolling.\n\n", count: 120)
        h.window.styleMask.insert(.resizable)
        h.window.setContentSize(NSSize(width: 980, height: 650))
        // Install the hosting view directly, as in makeDocumentWindow, so its
        // constraints can actually clamp the requested window size.
        let root = NSHostingView(rootView: ContentView(document: h.store, settings: h.settings, onOpen: {}))
        h.window.contentView = root
        h.window.makeKeyAndOrderFront(nil)
        h.spin(until: { !h.descendants(NSTableView.self).isEmpty })
        XCTAssertFalse(h.descendants(NSTableView.self).isEmpty, "the outline starts open")

        h.window.setContentSize(NSSize(width: 720, height: 650))
        h.spin(until: { h.descendants(NSTableView.self).isEmpty })
        XCTAssertTrue(h.descendants(NSTableView.self).isEmpty)
        XCTAssertEqual(h.window.frame.width, 720, accuracy: 1)
        let editor = try XCTUnwrap(h.descendants(MarkdownSourceTextView.self).first)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        XCTAssertGreaterThan(scroll.bounds.width, 700)
        XCTAssertTrue(h.window.makeFirstResponder(editor))
        editor.insertText("Edited ", replacementRange: NSRange(location: 2, length: 0))
        XCTAssertTrue(h.store.text.hasPrefix("# Edited Document"))
        scroll.scrollerStyle = .legacy
        scroll.tile()
        let track = try XCTUnwrap(scroll.verticalScroller)
        let trackPoint = track.convert(NSPoint(x: track.bounds.midX, y: track.bounds.midY), to: nil)
        let trackHit = try XCTUnwrap(root.hitTest(root.convert(trackPoint, from: nil)))
        XCTAssertTrue(trackHit === track || trackHit.isDescendant(of: track))
        editor.pageDown(nil)
        h.spin(until: { editor.visibleRect.minY > 20 })
        XCTAssertGreaterThan(editor.visibleRect.minY, 20)

        h.store.requestMode(.read)
        h.spin(until: { !h.descendants(WKWebView.self).isEmpty })
        let web = try XCTUnwrap(h.descendants(WKWebView.self).first)
        try h.waitForPage("document.querySelector('main h1')?.textContent === 'Edited Document'", in: web,
                          context: "edited text in half-screen Read")
        XCTAssertEqual(h.window.frame.width, 720, accuracy: 1)
        let viewport = web.convert(web.bounds, to: nil)
        XCTAssertGreaterThan(viewport.width, 700)
        for x in [viewport.midX, viewport.maxX - 2] {
            let point = NSPoint(x: x, y: viewport.midY)
            let hit = try XCTUnwrap(root.hitTest(root.convert(point, from: nil)))
            XCTAssertTrue(hit === web || hit.isDescendant(of: web), "preview text and scrollbar must receive input")
        }
        _ = try h.js("scrollTo(0, 160); true", web)
        try h.clickPreviewScrollTrack(in: web)
        try h.waitForPage("scrollY > 170", in: web, context: "native scrollbar advances the document at 720 pt")

        h.store.requestMode(.split)
        h.spin(until: { !h.descendants(NSSplitView.self).isEmpty && h.window.frame.width >= 816 })
        XCTAssertEqual(h.window.frame.width, 816, accuracy: 1, "only the split pane minima require more room")
        XCTAssertTrue(h.descendants(NSTableView.self).isEmpty)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(h.descendants(WKWebView.self).first).bounds.width, 420)

        h.store.requestMode(.read)
        h.spin(until: { h.descendants(NSSplitView.self).isEmpty })
        h.window.setContentSize(NSSize(width: 980, height: 650))
        h.spin(until: { !h.descendants(NSTableView.self).isEmpty })
        XCTAssertFalse(h.descendants(NSTableView.self).isEmpty, "an automatically collapsed outline returns")
        h.store.requestMode(.split)
        h.spin(until: { !h.descendants(NSSplitView.self).isEmpty && h.descendants(NSTableView.self).isEmpty })
        XCTAssertFalse(h.descendants(NSSplitView.self).isEmpty)
        XCTAssertTrue(h.descendants(NSTableView.self).isEmpty)
        XCTAssertEqual(h.window.frame.width, 980, accuracy: 1, "switching to split must not widen for the outline")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(h.descendants(WKWebView.self).first).bounds.width, 420)
    }
}
