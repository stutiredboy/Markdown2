import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

final class ReadFormattingSelectionGUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 to run interaction GUI tests.")
    }

    @MainActor
    func testFormattingRevealWaitsForAVisibleHost() throws {
        try assertDelayedReveal()
    }

    @MainActor
    func testInsertionPointRevealWaitsForAVisibleHost() throws {
        try assertDelayedReveal(caret: true)
    }

    @MainActor
    func testPendingFormattingRevealYieldsToANewSelection() throws {
        try assertDelayedReveal(reselect: true)
    }

    @MainActor
    func testPendingFormattingRevealYieldsToANewUnmatchedQuery() throws {
        try assertDelayedReveal(query: "no-such-text")
    }

    @MainActor
    func testRepeatedFormatDoesNotEditBeforeTheTargetCanBeRevealed() throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        let source = String(repeating: "Filler paragraph.\n\n", count: 70) + "Alpha"
        harness.store.text = source
        let editor = harness.store.editorSession.loadTextView(text: source)
        let target = (source as NSString).range(of: "Alpha")
        editor.setSelectedRange(target)
        harness.store.requestFormat(.bold)
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(get: { harness.store.text }, set: { harness.store.text = $0 }),
            session: harness.store.editorSession)
        let scroll = NSScrollView(frame: .zero)
        harness.store.editorSession.host(in: scroll, coordinator: coordinator)
        coordinator.observe(scrollView: scroll)
        coordinator.scheduleStyle(in: editor)
        coordinator.requestSelectionReveal(in: editor)
        let container = NSView(frame: harness.window.contentView!.bounds)
        container.addSubview(scroll)
        harness.window.contentView = container
        harness.window.makeKeyAndOrderFront(nil)
        harness.spin(until: { (editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 16 })
        XCTAssertNotNil(editor.window)
        XCTAssertEqual(editor.enclosingScrollView?.contentSize.height, 0)
        XCTAssertTrue(harness.store.editorSession.revealSelectionOnNextHost)
        XCTAssertTrue(harness.window.makeFirstResponder(editor))
        harness.store.requestFormat(.bold)
        harness.spin()
        XCTAssertNil(harness.store.formatCommand, "a premature second command must not be queued for later")
        XCTAssertEqual(harness.store.text, source, "window/focus alone must not authorize editing an unrevealed target")
        let bold = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                   timestamp: 0, windowNumber: harness.window.windowNumber, context: nil,
                                   characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11)!
        XCTAssertTrue(editor.performKeyEquivalent(with: bold), "consume the shortcut without bubbling to a menu")
        XCTAssertEqual(editor.string, source, "the native shortcut must obey the same pending-reveal boundary")
        harness.host(ContentView(document: harness.store, settings: harness.settings, onOpen: {}))
        try harness.waitForTarget(target, in: editor, context: "second format after the visible host settles")
        XCTAssertEqual(harness.store.text, source, "no premature command may replay after the reveal")
        XCTAssertTrue(harness.window.makeFirstResponder(editor))
        XCTAssertTrue(editor.performKeyEquivalent(with: bold))
        XCTAssertEqual(harness.store.text, source.replacingOccurrences(of: "Alpha", with: "**Alpha**"))
    }

    @MainActor
    private func assertDelayedReveal(caret: Bool = false, reselect: Bool = false, query: String? = nil) throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        let source = String(repeating: "Filler paragraph.\n\n", count: 70) + "Alpha"
        let session = harness.store.editorSession
        let editor = session.loadTextView(text: source)
        var target = (source as NSString).range(of: "Alpha")
        if caret { target.length = 0 }
        editor.setSelectedRange(target)
        session.revealSelectionOnNextHost = true
        var reportedLines: [Int] = []
        let host = NSHostingView(rootView: MarkdownEditorView(
            text: .constant(source), jumpLine: .constant(nil), jumpFraction: .constant(nil),
            jumpAnchor: .constant(nil), onAnchorLineChange: { line, _ in reportedLines.append(line) },
            findQuery: .constant(""), findNavigation: .constant(nil),
            findReplacement: .constant(""), replaceCommand: .constant(nil), focusToken: UUID(),
            lineSelection: .constant(nil), session: session
        ))
        // Create and style the editor before its window is attached, as can
        // happen while SwiftUI replaces the Read surface. Elapsed time cannot
        // make an unhosted selection visible.
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 650)
        host.layoutSubtreeIfNeeded()
        harness.spin(until: { editor.enclosingScrollView != nil })
        harness.spin(until: { (editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 16 })
        XCTAssertEqual((editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 16)
        XCTAssertNil(editor.window)
        XCTAssertTrue(session.revealSelectionOnNextHost, "an unhosted reveal must remain pending")
        if reselect { editor.setSelectedRange(NSRange(location: 0, length: 0)) }
        if let query {
            // Replace the constant binding itself; the unmatched search must
            // cancel even though no search result changes the selection.
            host.rootView = MarkdownEditorView(
                text: .constant(source), jumpLine: .constant(nil), jumpFraction: .constant(nil),
                jumpAnchor: .constant(nil), findQuery: .constant(query), findNavigation: .constant(nil),
                findReplacement: .constant(""), replaceCommand: .constant(nil), focusToken: UUID(),
                lineSelection: .constant(nil), session: session
            )
            host.layoutSubtreeIfNeeded()
        }
        if reselect || query != nil {
            harness.spin(until: { !session.revealSelectionOnNextHost })
            XCTAssertFalse(session.revealSelectionOnNextHost, "the explicit new action must cancel the old reveal")
        }
        harness.window.contentView = host
        harness.window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        harness.spin(until: { !session.revealSelectionOnNextHost })
        XCTAssertFalse(session.revealSelectionOnNextHost)
        XCTAssertEqual(editor.selectedRange(), reselect ? NSRange(location: 0, length: 0) : target)
        let layout = try XCTUnwrap(editor.layoutManager)
        let container = try XCTUnwrap(editor.textContainer)
        layout.ensureLayout(for: container)
        let visibleTarget = reselect ? NSRange(location: 0, length: 1) : NSRange(location: target.location, length: max(1, target.length))
        var rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: visibleTarget, actualCharacterRange: nil), in: container)
        rect.origin.x += editor.textContainerOrigin.x
        rect.origin.y += editor.textContainerOrigin.y
        if query == nil {
            XCTAssertTrue(editor.visibleRect.intersects(rect), "delayed host target must be visible: visible=\(editor.visibleRect), target=\(rect), frame=\(editor.frame)")
            if !reselect {
                XCTAssertEqual(reportedLines.last, MarkdownEditorView.Coordinator.topVisibleLine(in: try XCTUnwrap(editor.enclosingScrollView)),
                               "the outline must receive the final revealed viewport")
            }
        } else {
            XCTAssertFalse(editor.visibleRect.intersects(rect), "a cancelled reveal must not pull the viewport back to the old target")
        }
    }

    @MainActor
    func testReadFormattingRevealsSourceWithoutGuessingRenderedSelections() throws {
        for renderedText in ["Beta\n\nBeta", "[Beta](https://example.com)", "$Beta$", "Beta first\n\nBeta second"] {
            let harness = InteractionTestWindow()
            defer { harness.close() }
            let original = renderedText + "\n\n" + String(repeating: "Filler paragraph.\n\n", count: 70) + "Alpha"
            harness.store.text = original
            harness.host(ContentView(document: harness.store, settings: harness.settings, onOpen: {}))
            let editor = try XCTUnwrap(harness.store.editorSession.textView)
            let target = (original as NSString).range(of: "Alpha")
            // A persisted search must not move the revealed formatting target
            // when the editor's new coordinator rebuilds its match index.
            harness.store.requestFind(.show)
            harness.spin()
            try harness.enterQuery("Beta")
            harness.spin(for: 0.4)
            try harness.press(.closeFind)
            editor.setSelectedRange(target)
            harness.store.requestMode(.read)
            harness.spin(until: { editor.window == nil && !harness.descendants(WKWebView.self).isEmpty })
            let web = try XCTUnwrap(harness.descendants(WKWebView.self).first)
            try harness.waitForPage("""
                document.readyState === 'complete' && typeof window.__md2Find === 'function' &&
                document.querySelector('main')?.textContent.includes('Alpha') &&
                Array.from(document.querySelectorAll('p')).some(p=>p.textContent.includes('Beta') && p.getBoundingClientRect().height > 0)
                """, in: web, context: "Read fixture \(renderedText)")
            let selection = try harness.js("""
                (() => {
                    const paragraphs = Array.from(document.querySelectorAll('p')).filter(p=>p.textContent.includes('Beta'));
                    const range = document.createRange();
                    range.setStartBefore(paragraphs[0]); range.setEndAfter(paragraphs[paragraphs.length-1]);
                    const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
                    paragraphs[0].scrollIntoView(); return selection.toString();
                })()
                """, web) as? String
            XCTAssertTrue(selection?.contains("Beta") == true)
            harness.store.requestFormat(.bold)
            XCTAssertEqual(harness.store.text, original)
            try harness.waitForTarget(target, in: editor, context: "Reveal fixture \(renderedText)")
            XCTAssertEqual(harness.store.text, original)
            XCTAssertEqual(editor.selectedRange(), target)
            XCTAssertTrue(harness.store.showsFormattingTargetNotice)
            let layout = try XCTUnwrap(editor.layoutManager)
            let container = try XCTUnwrap(editor.textContainer)
            var rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: target, actualCharacterRange: nil), in: container)
            rect.origin.x += editor.textContainerOrigin.x
            rect.origin.y += editor.textContainerOrigin.y
            XCTAssertTrue(editor.visibleRect.intersects(rect), "the revealed source target must actually be visible")
            if renderedText == "Beta\n\nBeta" {
                harness.store.requestFind(.show)
                harness.spin()
                try harness.enterQuery("Filler")
                harness.spin(for: 0.4)
                XCTAssertFalse(harness.store.showsFormattingTargetNotice)
                XCTAssertEqual(editor.selectedRange().location, NSMaxRange((original as NSString).range(of: "Filler")),
                               "a deliberate new search must still reveal its match")
                try harness.press(.closeFind)
                editor.setSelectedRange(target)
            }
            XCTAssertTrue(harness.window.makeFirstResponder(editor))
            harness.store.requestFormat(.bold)
            harness.spin()
            XCTAssertEqual(harness.store.text, original.replacingOccurrences(of: "Alpha", with: "**Alpha**"))
        }
    }


}
