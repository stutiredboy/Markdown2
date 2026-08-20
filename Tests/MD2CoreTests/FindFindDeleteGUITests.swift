import AppKit
import SwiftUI
import XCTest
import MD2Core
@testable import MD2App

/// GUI-gated verification for the find reveal/delete fix and find-mode
/// responsiveness. `swift test` and CI skip these (`MD2_RUN_GUI_TESTS` unset);
/// run with `MD2_RUN_GUI_TESTS=1 swift test --filter FindFindDeleteGUITests`.
///
/// These need a GUI session: the delete test drives a real key window and first
/// responder (the find query field owns focus until the user clicks into the
/// editor, so the delete path only runs with the editor focused), and the
/// benchmark times the real highlight repaint, which needs layout.
final class FindFindDeleteGUITests: XCTestCase {
    @MainActor
    func testBackspaceAfterRevealDeletesOneCharacterInKeyWindow() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this find/delete GUI test."
        )
        _ = NSApplication.shared

        var modelText = "pre abc post"
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(get: { modelText }, set: { modelText = $0 })
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 280))
        textView.isRichText = false
        textView.string = modelText
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        coordinator.updateFind(query: "abc", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)
        // Reveal leaves the caret collapsed at the match end; the editor must be
        // first responder for Backspace to reach the text view (the find query
        // field owns focus otherwise).
        XCTAssertTrue(window.makeFirstResponder(textView), "editor should become first responder")
        textView.deleteBackward(nil)

        // Only the trailing "c" is deleted — never the whole matched word.
        XCTAssertEqual(textView.string, "pre ab post")
        XCTAssertEqual(textView.selectedRange().length, 0, "caret stays collapsed after delete")
    }

    @MainActor
    func testSettledSearchAndNavigationCompleteWithinBoundOnLargeDocument() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this find responsiveness benchmark."
        )

        // ~1 MB document of prose, so a single-letter query yields tens of
        // thousands of matches.
        let sentence = "the quick brown fox jumps over the lazy dog "
        var large = ""
        while large.utf8.count < 1_000_000 {
            large += sentence
        }
        let textView = NSTextView()
        textView.isRichText = false
        textView.string = large
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(get: { large }, set: { large = $0 })
        )

        let clock = ContinuousClock()

        // The settled search + highlight update: the cost the debounce now pays
        // once per settled query instead of per keystroke.
        let searchStart = clock.now
        coordinator.updateFind(query: "e", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)
        let searchElapsed = clock.now - searchStart
        let searchSeconds = Self.seconds(searchElapsed)
        XCTAssertLessThan(
            searchSeconds, 5.0,
            "settled search + highlight repaint took \(searchSeconds)s on a ~1 MB document"
        )

        // Navigation must swap only the two affected highlight colors, so it must
        // be far cheaper than a full re-paint of every match.
        let navStart = clock.now
        for _ in 0..<50 {
            coordinator.navigateFind(forward: true, in: textView)
        }
        let navElapsed = clock.now - navStart
        let navSeconds = Self.seconds(navElapsed)
        XCTAssertLessThan(
            navSeconds, 1.0,
            "50 find-navigation steps took \(navSeconds)s — the per-navigation highlight swap is not incremental"
        )
    }

    @MainActor
    func testEditingUnderOpenFindBarDoesNotJumpCaretInKeyWindow() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this find/edit GUI test."
        )
        _ = NSApplication.shared

        // Matches far apart vertically so a reveal that wrongly ran would scroll.
        var lines = [String]()
        for i in 0..<80 {
            lines.append(i == 0 ? "abc" : i == 60 ? "abc" : "line \(i)")
        }
        var modelText = lines.joined(separator: "\n")
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(get: { modelText }, set: { modelText = $0 })
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 280))
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 4000))
        textView.isRichText = false
        textView.string = modelText
        textView.delegate = coordinator
        scrollView.documentView = textView
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        coordinator.observe(scrollView: scrollView)
        coordinator.updateFind(query: "abc", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)
        XCTAssertTrue(window.makeFirstResponder(textView), "editor should become first responder")

        // Caret collapsed at the end of the first match (3); delete the "c".
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        let originBeforeEdit = scrollView.contentView.bounds.origin
        textView.deleteBackward(nil)
        // The coordinator's textDidChange (via the delegate) bumps the find
        // generation. SwiftUI would call updateFind after the edit; drive it.
        coordinator.updateFind(query: "abc", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)

        // The caret stays where the delete left it (2) — not jumped to the next
        // match on line 60.
        XCTAssertEqual(textView.selectedRange().location, 2, "caret must not jump to the next match")
        XCTAssertEqual(textView.selectedRange().length, 0, "caret stays collapsed after delete")

        // A document-edit rebuild suppresses reveal, so the re-index must not
        // scroll. The suppression is synchronous (revealCurrentMatch is skipped),
        // so the clip origin is checked right after the rebuild — no runloop spin
        // (spinning here would race AppKit's window-animation teardown in CI).
        let settledOrigin = scrollView.contentView.bounds.origin
        XCTAssertLessThan(
            abs(settledOrigin.y - originBeforeEdit.y), 1.0,
            "a document-edit re-index must not scroll (origin \(settledOrigin) vs \(originBeforeEdit))"
        )
    }

    @MainActor
    func testReturnInQueryFieldDoesNotAdvanceInKeyWindow() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this find Return GUI test."
        )
        _ = NSApplication.shared

        var modelText = "abc abc"
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(get: { modelText }, set: { modelText = $0 })
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 280))
        textView.isRichText = false
        textView.string = modelText
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        coordinator.updateFind(query: "abc", in: textView)
        coordinator.flushPendingFindRebuild(in: textView)
        // Move to the second match.
        coordinator.navigateFind(forward: true, in: textView)
        XCTAssertEqual(textView.selectedRange().location, 7)

        // Return in the query field routes to `.search` (the seam `updateNSView`
        // calls): run the current search now, never advance to the next match.
        coordinator.handleFindNavigation(.search, in: textView)
        coordinator.handleFindNavigation(.search, in: textView)
        XCTAssertEqual(textView.selectedRange().location, 7, "Return must not advance to the next match")
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
