import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

final class SplitScrollPauseGUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Requires the native split editor and WebKit preview.")
    }

    @MainActor func testHoldingTableThroughSourceScrollAndEditThenResumingFromEditor() throws {
        let host = InteractionTestWindow()
        defer { host.close() }
        let web = try mount(in: host, settings: host.settings)
        let editor = try XCTUnwrap(host.store.editorSession.textView)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        try showTable(in: web, host: host)
        try waitForSource("Reference value", in: editor, host: host)
        let heldY = try tableY(in: web, host: host)
        XCTAssertEqual(heldY, 42, accuracy: 2)
        try toggle(in: host, paused: false)
        try observeFollows(in: web, host: host)

        // Scroll toward the earlier summary with an AppKit wheel event. Then
        // move the caret there and insert a new paragraph above the table.
        let beforeScroll = scroll.contentView.bounds.minY
        try scrollEditor(by: 450, in: host, editor: editor)
        XCTAssertLessThan(scroll.contentView.bounds.minY, beforeScroll - 30)
        host.spin()
        XCTAssertEqual(try tableY(in: web, host: host), heldY, accuracy: 1)
        let summary = (editor.string as NSString).range(of: "Draft summary.")
        XCTAssertNotEqual(summary.location, NSNotFound)
        let caret = NSRange(location: NSMaxRange(summary), length: 0)
        XCTAssertTrue(host.window.makeFirstResponder(editor))
        editor.setSelectedRange(caret)
        editor.scrollRangeToVisible(caret)
        editor.insertText("\n\nSummary updated.", replacementRange: caret)
        try host.waitForPage("document.querySelector('main').textContent.includes('Summary updated.')",
                             in: web, context: "the edited summary must render above the reference")
        XCTAssertEqual(try tableY(in: web, host: host), heldY, accuracy: 1,
                       "the visible table moved during the live render")
        XCTAssertEqual(try host.js("resumeCalls.length", web) as? Int, 0)

        let editorY = scroll.contentView.bounds.minY
        let topLine = try XCTUnwrap(MarkdownEditorView.Coordinator.topVisibleFractionalLine(in: scroll))
        try toggle(in: host, paused: true)
        try host.waitForPage("resumeCalls.length > 0 && document.querySelector('table').getBoundingClientRect().top > innerHeight",
                             in: web, context: "resume must bring the preview back to the editor")
        host.spin(for: 0.4)
        XCTAssertEqual(try host.js("resumeCalls.length", web) as? Int, 1, "one alignment per resume")
        XCTAssertEqual(try XCTUnwrap(try host.js("resumeCalls[0]", web) as? Double), topLine, accuracy: 0.01)
        XCTAssertEqual(scroll.contentView.bounds.minY, editorY, accuracy: 1)

        // A second editor scroll follows continuously, then a preview scroll
        // can drive the editor back to the table.
        let previewY = try XCTUnwrap(try host.js("scrollY", web) as? Double)
        try scrollEditor(by: -450, in: host, editor: editor)
        try host.waitForPage("resumeCalls.length > 1 && scrollY > \(previewY) + 50",
                             in: web, context: "ordinary editor-to-preview scrolling resumed")
        host.spin(for: 0.35)
        try showTable(in: web, host: host)
        try waitForSource("Reference value", in: editor, host: host)
    }

    @MainActor func testHoldingTableWhenAnEditLoadsANewPreviewEngine() throws {
        let host = InteractionTestWindow()
        defer { host.close() }
        let web = try mount(in: host, settings: host.settings)
        let editor = try XCTUnwrap(host.store.editorSession.textView)
        try showTable(in: web, host: host)
        try waitForSource("Reference value", in: editor, host: host)
        try toggle(in: host, paused: false)
        // Leave a sliver of the paragraph immediately above the table on
        // screen, then edit that very paragraph until it wraps across rows.
        let preceding = "Working notes for paragraph 71."
        _ = try host.js("""
            const preceding = Array.from(document.querySelectorAll('main > p')).find(p => p.textContent === '\(preceding)');
            window.scrollBy(0, preceding.getBoundingClientRect().top + 4);
            """, web)
        let heldY = try tableY(in: web, host: host)
        XCTAssertGreaterThan(heldY, 0)
        XCTAssertLessThan(heldY, 100)
        let precedingRange = (editor.string as NSString).range(of: preceding)
        XCTAssertNotEqual(precedingRange.location, NSNotFound)
        let end = NSRange(location: NSMaxRange(precedingRange), length: 0)
        let addition = String(repeating: " More detail about the reference.", count: 15)
        XCTAssertTrue(host.window.makeFirstResponder(editor))
        editor.setSelectedRange(end)
        editor.insertText(addition, replacementRange: end)
        try host.waitForPage("!preceding.isConnected && document.querySelector('main').textContent.includes('\(addition)')",
                             in: web, context: "the partially visible paragraph was replaced")
        XCTAssertEqual(try tableY(in: web, host: host), heldY, accuracy: 2,
                       "the table stays put even when the preceding visible paragraph changes height")
        _ = try host.js("window.beforeDiagram = true", web)

        let summary = (editor.string as NSString).range(of: "Draft summary.")
        XCTAssertNotEqual(summary.location, NSNotFound)
        let caret = NSRange(location: NSMaxRange(summary), length: 0)
        XCTAssertTrue(host.window.makeFirstResponder(editor))
        editor.setSelectedRange(caret)
        editor.scrollRangeToVisible(caret)
        editor.insertText("\n\n```mermaid\ngraph LR; A-->B;\n```", replacementRange: caret)
        try host.waitForPage("!window.beforeDiagram && !!document.querySelector('.diagram svg')",
                             in: web, context: "adding Mermaid should render a diagram in a fresh preview page")
        try host.waitForPage("Math.abs(document.querySelector('table').getBoundingClientRect().top - \(heldY)) <= 2",
                             in: web, context: "the replacement page should restore the reference")
        host.spin(for: 0.4)
        XCTAssertEqual(try tableY(in: web, host: host), heldY, accuracy: 2)
    }

    @MainActor func testEditingAndResumingBeforeAnAllowedImageFinishesLoading() throws {
        let server = try HeldPreviewImageServer()
        defer { server.stop() }
        let host = InteractionTestWindow()
        defer { host.close() }
        host.spin(until: { server.port != nil })
        let port = try XCTUnwrap(server.port)
        host.store.setRemoteImagesAllowed(true)
        let web = try mount(in: host, settings: host.settings, imageURL: "http://127.0.0.1:\(port)/held.png")
        let editor = try XCTUnwrap(host.store.editorSession.textView)
        let coordinator = try XCTUnwrap(web.navigationDelegate as? MarkdownPreviewView.Coordinator)
        host.spin(until: { server.hasRequest })
        XCTAssertTrue(server.hasRequest)
        XCTAssertTrue(web.isLoading)
        XCTAssertFalse(coordinator.isLoaded)
        try toggle(in: host, paused: false)
        try showTable(in: web, host: host)
        let heldY = try tableY(in: web, host: host)
        _ = try host.js("window.initialImage = document.querySelector('img'); true", web)

        let summary = (editor.string as NSString).range(of: "Draft summary.")
        XCTAssertNotEqual(summary.location, NSNotFound)
        let caret = NSRange(location: NSMaxRange(summary), length: 0)
        XCTAssertTrue(host.window.makeFirstResponder(editor))
        editor.setSelectedRange(caret)
        editor.scrollRangeToVisible(caret)
        editor.insertText("\n\nPending image summary.", replacementRange: caret)
        try host.waitForPage("""
            document.querySelector('main')?.textContent.includes('Pending image summary.')
                && window.initialImage === document.querySelector('img') && !initialImage.complete
            """, in: web, context: "the pending image survives an ordinary edit", requireLoaded: false)
        XCTAssertEqual(try tableY(in: web, host: host), heldY, accuracy: 1)

        // Adding the first diagram needs a fresh document. Its DOM and scroll
        // helpers are ready to use even while the same image is still pending.
        editor.insertText("\n\n```mermaid\ngraph LR; A-->B;\n```", replacementRange: editor.selectedRange())
        try host.waitForPage("""
            !window.initialImage && !!document.querySelector('.diagram')
                && document.querySelector('img')?.complete === false
                && Math.abs(document.querySelector('table').getBoundingClientRect().top - \(heldY)) <= 2
            """, in: web, context: "the replacement page restores the table before image load", requireLoaded: false)
        XCTAssertTrue(web.isLoading)
        XCTAssertFalse(coordinator.isLoaded)
        try observeFollows(in: web, host: host)
        try toggle(in: host, paused: true)
        try host.waitForPage("""
            resumeCalls.length === 1 && document.querySelector('table').getBoundingClientRect().top > innerHeight
                && document.querySelector('img')?.complete === false
            """, in: web, context: "resume aligns with the editor while the image is loading", requireLoaded: false)
        let alignedY = try XCTUnwrap(try host.js("scrollY", web) as? Double)

        server.release()
        try host.waitForPage("document.querySelector('img')?.naturalWidth === 1", in: web,
                             context: "the previously held image completed")
        XCTAssertEqual(try host.js("resumeCalls.length", web) as? Int, 1)
        XCTAssertEqual(try XCTUnwrap(try host.js("scrollY", web) as? Double), alignedY, accuracy: 2)
    }

    @MainActor func testResumingFromPreviewAndKeepingPauseLocalToOneWindow() throws {
        let first = InteractionTestWindow()
        defer { first.close() }
        let web = try mount(in: first, settings: first.settings)
        let editor = try XCTUnwrap(first.store.editorSession.textView)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        try toggle(in: first, paused: false)

        // The windows observe the same app preferences. Opening the second
        // while the first is paused must still produce a working follower.
        let other = InteractionTestWindow()
        defer { other.close() }
        let otherWeb = try mount(in: other, settings: first.settings)
        let otherEditor = try XCTUnwrap(other.store.editorSession.textView)
        XCTAssertNotNil(item(in: other, paused: false))
        try showTable(in: otherWeb, host: other)
        try waitForSource("Reference value", in: otherEditor, host: other)

        first.window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(first.window.makeFirstResponder(editor))
        let initial = scroll.contentView.bounds.minY
        try showTable(in: web, host: first)
        first.spin(for: 0.35)
        XCTAssertEqual(scroll.contentView.bounds.minY, initial, accuracy: 1,
                       "preview scrolling must leave the paused editor in place")
        let heldY = try tableY(in: web, host: first)
        try toggle(in: first, paused: true)
        try waitForSource("Reference value", in: editor, host: first)
        first.spin(for: 0.35)
        XCTAssertEqual(try tableY(in: web, host: first), heldY, accuracy: 1,
                       "the preview was the latest scroll source even with the insertion point in the editor")
    }

    @MainActor private func mount(in host: InteractionTestWindow, settings: AppSettings, imageURL: String? = nil) throws -> WKWebView {
        settings.language = .english
        settings.newDocumentMode = .split
        let paragraphs = (1...110).map { index in
            switch index {
            case 12: "Draft summary."
            case 72: "| Reference value | Units |\n| --- | --- |\n| 42 | hours |"
            default: "Working notes for paragraph \(index)."
            }
        }
        host.store.text = paragraphs.joined(separator: "\n\n")
            + (imageURL.map { "\n\n![Image still loading](\($0))" } ?? "")
        // Mount the fixture after its first render. Otherwise a blank page
        // can still be restoring its initial scroll during our first gesture.
        host.spin(until: { host.store.rendered.body.contains("Reference value") })
        host.window.setContentSize(NSSize(width: 1020, height: 610))
        host.window.contentView = NSHostingView(rootView: ContentView(document: host.store, settings: settings, onOpen: {}))
        host.window.makeKeyAndOrderFront(nil)
        host.spin(until: { !host.descendants(WKWebView.self).isEmpty })
        let web = try XCTUnwrap(host.descendants(WKWebView.self).first)
        try host.waitForPage("!!document.querySelector('table') && typeof window.__md2CaptureAnchor === 'function'",
                             in: web, context: "fixture table in split preview", requireLoaded: imageURL == nil)
        host.spin(for: 0.35)
        return web
    }

    @MainActor private func item(in host: InteractionTestWindow, paused: Bool) -> NSToolbarItem? {
        let title = paused ? "Resume Synchronized Scrolling" : "Pause Synchronized Scrolling"
        return host.window.toolbar?.visibleItems?.first { $0.label == title }
    }

    @MainActor private func toggle(in host: InteractionTestWindow, paused: Bool) throws {
        let control = try XCTUnwrap(item(in: host, paused: paused), "visible split scroll control")
        let view = try XCTUnwrap(control.view)
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: host.window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        host.window.postEvent(try event(.leftMouseUp), atStart: true)
        host.window.sendEvent(try event(.leftMouseDown))
        if let up = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            host.window.sendEvent(up)
        }
        host.spin(until: { self.item(in: host, paused: !paused) != nil })
        _ = try XCTUnwrap(item(in: host, paused: !paused), "the native control must change state")
    }

    @MainActor private func observeFollows(in web: WKWebView, host: InteractionTestWindow) throws {
        _ = try host.js("""
            window.resumeCalls = [];
            const follow = window.__md2FollowToAnchor;
            window.__md2FollowToAnchor = line => { window.resumeCalls.push(line); return follow(line); };
            true;
            """, web)
    }

    @MainActor private func tableY(in web: WKWebView, host: InteractionTestWindow) throws -> Double {
        try XCTUnwrap(try host.js("document.querySelector('table').getBoundingClientRect().top", web) as? Double)
    }

    @MainActor private func showTable(in web: WKWebView, host: InteractionTestWindow) throws {
        _ = try host.js("""
            window.dispatchEvent(new WheelEvent('wheel', {bubbles: true, deltaY: 600}));
            window.scrollBy(0, document.querySelector('table').getBoundingClientRect().top - 42);
            """, web)
        try host.waitForPage("Math.abs(document.querySelector('table').getBoundingClientRect().top - 42) < 2",
                             in: web, context: "the reader placed the table near the top of the preview", requireLoaded: false)
    }

    @MainActor private func waitForSource(_ text: String, in editor: NSTextView, host: InteractionTestWindow) throws {
        let range = (editor.string as NSString).range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound)
        try host.waitForTarget(range, in: editor, context: "the editor should follow the preview to \(text)")
    }

    @MainActor private func scrollEditor(by delta: Int32, in host: InteractionTestWindow, editor: NSTextView) throws {
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        let origin = scroll.contentView.bounds.minY
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                          wheel1: delta, wheel2: 0, wheel3: 0))
        // Dequeue the wheel through NSApplication so the bounds observer sees
        // NSApp.currentEvent, the same user-scroll signal as in the app.
        let center = NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY)
        let point = host.window.convertPoint(toScreen: scroll.convert(center, to: nil))
        event.location = CGPoint(x: point.x, y: try XCTUnwrap(NSScreen.screens.first).frame.maxY - point.y)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(host.window.windowNumber))
        let wheel = try XCTUnwrap(NSEvent(cgEvent: event))
        NSApp.postEvent(wheel, atStart: true)
        let next = try XCTUnwrap(NSApp.nextEvent(matching: .scrollWheel, until: Date().addingTimeInterval(2),
                                                inMode: .default, dequeue: true))
        // Target the mounted scroll view directly: an in-process CGEvent does
        // not carry an NSWindow target, even when its screen coordinates match.
        scroll.scrollWheel(with: next)
        host.spin(until: { abs(scroll.contentView.bounds.minY - origin) > 30 }, timeout: 2)
    }
}
