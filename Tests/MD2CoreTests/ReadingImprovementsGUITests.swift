import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import MD2App
@testable import MD2Core

final class ReadingImprovementsGUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1", "Requires AppKit and WebKit")
    }

    @MainActor func testEditorSelectionZoomAndUndo() throws {
        let host = ReadingWindow("# 标题\n\n中文 **正文** [链接](https://example.com/path)")
        defer { host.close() }
        let editor = try XCTUnwrap(host.store.editorSession.textView)
        let coordinator = try XCTUnwrap(Mirror(reflecting: host.store.editorSession).children.first { $0.label == "coordinator" }?.value as? MarkdownEditorView.Coordinator)
        var selection: String?
        let onSelection = coordinator.onSelectionChange
        coordinator.onSelectionChange = { selection = $0; onSelection($0) }
        let text = editor.string
        let selected = (text as NSString).range(of: "中文 **正文** [链接](https://example.com/path)")
        editor.setSelectedRange(selected)
        host.spin(0.35)
        XCTAssertEqual(DocumentStats(markdown: try XCTUnwrap(selection)).words, 6)

        host.settings.typography.editorFont = .monospaced
        host.settings.typography.fontSize = 20
        host.settings.zoomIn()
        host.spin(0.4)
        XCTAssertEqual(editor.string, text)
        XCTAssertEqual(editor.selectedRange(), selected)
        XCTAssertFalse(host.store.undoManager.canUndo)
        let font = try XCTUnwrap(editor.textStorage?.attribute(.font, at: selected.location, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 22, accuracy: 0.01)
        let latinFont = try XCTUnwrap(editor.textStorage?.attribute(.font, at: (text as NSString).range(of: "https").location, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(latinFont.familyName, NSFont.monospacedSystemFont(ofSize: 22, weight: .regular).familyName)
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        coordinator.onSelectionChange = { selection = $0; onSelection($0) }
        coordinator.reportSelection(in: editor)
        host.spin(0.2)
        XCTAssertNil(selection)
        editor.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        host.spin(0.15)
        host.store.undoManager.undo()
        host.spin(0.15)
        XCTAssertEqual(editor.string, text)
    }

    @MainActor func testReadSelectionAndLiveTypography() throws {
        let host = ReadingWindow("# 标题\n\n中文 **正文** [链接](https://example.com/path) ![image](missing.png)", mode: .read)
        defer { host.close() }
        let webView = try host.preview()
        let coordinator = try XCTUnwrap(webView.navigationDelegate as? MarkdownPreviewView.Coordinator)
        var selection: String?
        let onSelection = coordinator.onSelectionChange
        coordinator.onSelectionChange = { selection = $0; onSelection($0) }
        _ = try evaluate("""
        (function () {
            var range = document.createRange(); range.selectNodeContents(document.querySelector('main > p'));
            var selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
        })();
        """, in: webView)
        host.spin(until: { selection != nil })
        XCTAssertEqual(DocumentStats(plainText: RenderedPlainText.extract(from: try XCTUnwrap(selection))).words, 6)
        XCTAssertEqual(try evaluate("getComputedStyle(document.querySelector('main')).maxWidth", in: webView) as? String, "800px")
        host.settings.typography.readingWidth = .narrow
        host.settings.typography.readingFont = .serif
        host.settings.typography.fontSize = 20
        host.settings.zoomIn()
        host.spin(until: { (try? evaluate("getComputedStyle(document.body).fontSize", in: webView)) as? String == "22px" })
        XCTAssertEqual(try evaluate("getComputedStyle(document.body).fontSize", in: webView) as? String, "22px")
        XCTAssertEqual(try evaluate("getComputedStyle(document.querySelector('main')).maxWidth", in: webView) as? String, "880px")
        XCTAssertTrue((try evaluate("getComputedStyle(document.body).fontFamily", in: webView) as? String)?.contains("serif") == true)
        _ = try evaluate("window.getSelection().removeAllRanges()", in: webView)
        host.spin(0.25)
        // SwiftUI refreshes callback closures when typography changes.
        coordinator.onSelectionChange = { selection = $0; onSelection($0) }
        _ = try evaluate("document.dispatchEvent(new Event('selectionchange'))", in: webView)
        host.spin(until: { selection == nil })
        XCTAssertNil(selection)
        XCTAssertFalse(host.store.rendered.html.contains("md2-typography"))
    }

    @MainActor func testOutlinePersistsAfterJumpAndFollowsBothSurfaces() throws {
        let paragraph = String(repeating: "A long paragraph with enough text to wrap and make each section scroll. ", count: 50)
        let markdown = "# First\n\n\(paragraph)\n\n# Second\n\n\(paragraph)\n\n# Third\n\n\(paragraph)"
        let host = ReadingWindow(markdown, mode: .read)
        defer { host.close() }
        let webView = try renderedPreview(host)
        let headings = host.store.rendered.outline
        XCTAssertEqual(headings.count, 3)
        let list = try XCTUnwrap(host.find(NSTableView.self))
        // XCTest-hosted WebKit may throttle animation frames for its window.
        _ = try evaluate("window.requestAnimationFrame = function (callback) { return setTimeout(callback, 16); }; void 0;", in: webView)
        host.store.jump(to: headings[1])
        host.spin(1.5)
        XCTAssertNil(host.store.jumpHeadingID)
        let afterJump = try evaluate("JSON.stringify({anchor:window.__md2CaptureAnchor(), y:window.scrollY, height:window.innerHeight})", in: webView)
        XCTAssertEqual(list.selectedRow, 1, String(describing: afterJump))
        _ = try evaluate("window.scrollTo(0, document.getElementById('third').offsetTop + 80)", in: webView)
        host.spin(0.3)
        let afterScroll = try evaluate("JSON.stringify({anchor:window.__md2CaptureAnchor(), y:window.scrollY, height:window.innerHeight})", in: webView)
        XCTAssertEqual(list.selectedRow, 2, String(describing: afterScroll))
        host.store.requestMode(.write)
        host.spin(0.6)
        let editor = try XCTUnwrap(host.store.editorSession.textView)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        host.spin(0.3)
        XCTAssertEqual(try XCTUnwrap(host.find(NSTableView.self)).selectedRow, 0)
    }

    @MainActor func testOutlineClickKeepsAdjacentParentSelectedUntilPreviewScroll() throws {
        let paragraph = String(repeating: "Detailed section text that makes the preview scrollable. ", count: 80)
        let markdown: String
        if let fixturePath = ProcessInfo.processInfo.environment["MD2_OUTLINE_REPRO_FILE"] {
            markdown = try String(contentsOfFile: fixturePath, encoding: .utf8)
        } else {
            markdown = """
            # Introduction

            \(paragraph)

            ### 3.1　运维质量改进项目界定

            #### 3.1.1　利益相关方识别与客户需求调研

            \(paragraph)

            #### 3.1.2　核心质量指标、目标与安全约束

            \(paragraph)
            """
        }
        let host = ReadingWindow(markdown, mode: .read)
        defer { host.close() }
        let webView = try renderedPreview(host)
        let headings = host.store.rendered.outline
        let parent = try XCTUnwrap(headings.first { $0.title.contains("3.1　") })
        let child = try XCTUnwrap(headings.first { $0.title.contains("3.1.1　") })
        let list = try XCTUnwrap(host.find(NSTableView.self))
        let parentRow = try XCTUnwrap(headings.firstIndex(of: parent))
        _ = try evaluate("window.requestAnimationFrame = function (callback) { return setTimeout(callback, 16); }; void 0;", in: webView)
        // A prior preview click is not a scroll gesture. It must not make the
        // later programmatic outline jump look user initiated.
        _ = try evaluate("window.dispatchEvent(new MouseEvent('mousedown', {bubbles: true}));", in: webView)

        list.scrollRowToVisible(parentRow)
        host.spin(0.2)
        list.selectRowIndexes(IndexSet(integer: parentRow), byExtendingSelection: false)
        host.spin(1.5)
        XCTAssertEqual(list.selectedRow, parentRow, "A click should keep its selected heading until the reader scrolls (rows: \(list.numberOfRows), parent: \(parentRow))")

        _ = try evaluate("window.dispatchEvent(new WheelEvent('wheel', {deltaY: 100, bubbles: true})); window.scrollTo(0, document.getElementById('\(child.id)').offsetTop + 80);", in: webView)
        host.spin(0.3)
        let anchorLine = try XCTUnwrap((evaluate("window.__md2CaptureAnchor().line", in: webView) as? NSNumber)?.intValue)
        let activeHeading = try XCTUnwrap(headings.heading(atOrAbove: anchorLine))
        let activeRow = try XCTUnwrap(headings.firstIndex(of: activeHeading))
        XCTAssertEqual(list.selectedRow, activeRow)
        XCTAssertTrue(list.visibleRect.contains(list.rect(ofRow: activeRow)))
    }

    @MainActor func testOutlineFollowsPreviewBeyondVisibleSidebarRows() throws {
        let paragraph = String(repeating: "This section has enough text to occupy the reading viewport. ", count: 30)
        let markdown = (1...55).map { "# Section \($0)\n\n\(paragraph)" }.joined(separator: "\n\n")
        let host = ReadingWindow(markdown, mode: .read)
        defer { host.close() }
        let webView = try renderedPreview(host)
        let list = try XCTUnwrap(host.find(NSTableView.self))
        XCTAssertEqual(list.numberOfRows, 55)

        for targetRow in [20, 45, 5] {
            let target = host.store.rendered.outline[targetRow]
            _ = try evaluate("window.dispatchEvent(new WheelEvent('wheel', {deltaY: 500, bubbles: true})); window.scrollTo(0, document.getElementById('\(target.id)').offsetTop + 30);", in: webView)
            host.spin(0.45)

            let rowFrame = list.rect(ofRow: targetRow)
            XCTAssertEqual(list.selectedRow, targetRow)
            XCTAssertTrue(list.visibleRect.contains(rowFrame), "Selected row \(targetRow) is outside the sidebar viewport: \(rowFrame), \(list.visibleRect)")
            let scrollDifference = try XCTUnwrap(evaluate("Math.abs(window.scrollY - (document.getElementById('\(target.id)').offsetTop + 30))", in: webView) as? Double)
            XCTAssertLessThan(scrollDifference, 2, "Following the outline must not jump the preview")
        }

        // Browsing the outline is independent of preview scroll following.
        // A deliberate row selection must still navigate the preview.
        let clickedRow = 35
        list.scrollRowToVisible(clickedRow)
        host.spin(0.2)
        list.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        _ = try evaluate("window.requestAnimationFrame = function (callback) { return setTimeout(callback, 16); }; void 0;", in: webView)
        host.spin(1.5)
        XCTAssertEqual(list.selectedRow, clickedRow)
        let clickedID = host.store.rendered.outline[clickedRow].id
        let jumpDifference = try XCTUnwrap(evaluate("Math.abs(window.scrollY - document.getElementById('\(clickedID)').offsetTop)", in: webView) as? Double)
        XCTAssertLessThan(jumpDifference, 2)
    }

    /// A list item at the top of the preview is the anchor for a switch to the
    /// editor, so the editor opens on that item's line. While only the list
    /// carried a source span, the switch interpolated across the whole list,
    /// and a long item above the viewport pulled the editor several lines past
    /// the item the reader was on.
    ///
    /// The document opens in Write mode so the editor's text view exists and
    /// is styled before the round trip: this pins the preview's anchor, not
    /// the first mount of the editor.
    @MainActor func testReadToWriteLandsOnTheListItemAtTheTop() throws {
        let long = String(repeating: "A list item long enough to wrap across many rows of the preview. ", count: 60)
        let items = (1...150).map { "- item \($0)" }.joined(separator: "\n")
        // Line 3 is the long item, so `item k` is on line 3 + k.
        let markdown = "# List\n\n- \(long)\n\(items)\n"
        let targetLine = 63
        let host = ReadingWindow(markdown, mode: .write)
        defer { host.close() }
        host.spin(until: {
            guard let storage = host.store.editorSession.textView?.textStorage, storage.length > 0 else { return false }
            return storage.attribute(.paragraphStyle, at: storage.length - 1, effectiveRange: nil) != nil
        })
        host.store.requestMode(.read)
        let webView = try renderedPreview(host)
        _ = try evaluate("window.requestAnimationFrame = function (callback) { return setTimeout(callback, 16); }; void 0;", in: webView)

        // Put `item 60` across the anchor band, the strip below the viewport
        // top that the preview anchors on, with the next item below it.
        let placed = try XCTUnwrap(evaluate("""
        (function () {
          var item = document.querySelectorAll('main > ul > li')[60];
          var band = Math.min(64, window.innerHeight * 0.25);
          window.scrollTo(0, item.getBoundingClientRect().top + window.scrollY - band + 4);
          return item.textContent;
        })()
        """, in: webView) as? String)
        XCTAssertEqual(placed, "item 60")
        host.spin(0.3)
        let anchor = try XCTUnwrap(evaluate("JSON.stringify(window.__md2CaptureAnchor())", in: webView) as? String)
        XCTAssertTrue(anchor.contains("\"line\":\(targetLine),\"endLine\":\(targetLine)"), anchor)

        // The editor puts its target line one container inset below the top of
        // the viewport, the margin it keeps above a jump target.
        host.store.requestMode(.write)
        let target = (markdown as NSString).range(of: "- item 60\n").location
        func placement() -> (offset: CGFloat, inset: CGFloat, lineHeight: CGFloat)? {
            guard let editor = host.store.editorSession.textView, editor.window != nil,
                  let layoutManager = editor.layoutManager else { return nil }
            var line = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: target), effectiveRange: nil)
            line.origin.y += editor.textContainerOrigin.y
            return (line.minY - editor.visibleRect.minY, editor.textContainerOrigin.y, line.height)
        }
        func landed() -> Bool {
            guard let placed = placement() else { return false }
            return abs(placed.offset - placed.inset) < placed.lineHeight / 2
        }
        host.spin(until: landed)
        XCTAssertTrue(landed(), "the editor must open on line \(targetLine), the list item at the top of the preview (anchor \(anchor), placement \(String(describing: placement())))")
    }

    /// The first switch to the editor lands on the anchored line once the
    /// editor's text is styled. The text view starts as plain text, the anchor
    /// settles against that layout, and styling then changes every line's
    /// height; keeping the scroll offset in points put the editor on line 12
    /// of a document anchored at line 63.
    @MainActor func testFirstSwitchToWriteLandsOnTheAnchoredLineAfterStyling() throws {
        let paragraph = String(repeating: "Section text long enough to wrap across several rows of the editor. ", count: 8)
        let markdown = "# Title\n\n" + (1...40).map { "## Section \($0)\n\n\(paragraph)" }.joined(separator: "\n\n") + "\n"
        let heading = "## Section 20\n"
        let target = (markdown as NSString).range(of: heading).location
        let targetLine = markdown.prefix(upTo: markdown.range(of: heading)!.lowerBound).filter { $0 == "\n" }.count + 1
        let host = ReadingWindow(markdown, mode: .read)
        defer { host.close() }
        XCTAssertNil(host.store.editorSession.textView, "the editor must not have been shown yet")
        let webView = try renderedPreview(host)
        _ = try evaluate("window.requestAnimationFrame = function (callback) { return setTimeout(callback, 16); }; void 0;", in: webView)

        // Put the heading across the anchor band, with the paragraph after it
        // below the band.
        let id = try XCTUnwrap(host.store.rendered.outline.first { $0.title == "Section 20" }?.id)
        _ = try evaluate("""
        (function () {
          var heading = document.getElementById('\(id)');
          var band = Math.min(64, window.innerHeight * 0.25);
          window.scrollTo(0, heading.getBoundingClientRect().top + window.scrollY - band + 4);
        })()
        """, in: webView)
        host.spin(0.3)
        let anchor = try XCTUnwrap(evaluate("JSON.stringify(window.__md2CaptureAnchor())", in: webView) as? String)
        XCTAssertTrue(anchor.contains("\"line\":\(targetLine),"), anchor)

        host.store.requestMode(.write)
        // Styled text carries a paragraph style; the plain text a new text
        // view starts with does not.
        host.spin(until: {
            guard let storage = host.store.editorSession.textView?.textStorage, storage.length > 0 else { return false }
            return storage.attribute(.paragraphStyle, at: storage.length - 1, effectiveRange: nil) != nil
        })
        host.spin(0.5)
        let editor = try XCTUnwrap(host.store.editorSession.textView)
        let scrollView = try XCTUnwrap(editor.enclosingScrollView)
        let layoutManager = try XCTUnwrap(editor.layoutManager)
        var line = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: target), effectiveRange: nil)
        line.origin.y += editor.textContainerOrigin.y
        // The editor keeps one container inset above a jump target.
        let offset = line.minY - editor.visibleRect.minY
        XCTAssertEqual(
            offset, editor.textContainerOrigin.y, accuracy: line.height / 2,
            "the editor must open on line \(targetLine) (anchor \(anchor)); top visible line is \(String(describing: MarkdownEditorView.Coordinator.topVisibleLine(in: scrollView)))"
        )
    }

    /// A number low in the preview opens an editor shown for the first time
    /// with the number's line selected at the top, also once the editor's text
    /// is styled, which makes every line above it taller. Before, the clicked
    /// line ended up far below the viewport.
    @MainActor func testPreviewNumberLowInReadModeOpensItsLineAtTheTop() throws {
        let paragraph = String(repeating: "Section text long enough to wrap across several rows of the editor. ", count: 8)
        let markdown = "# Title\n\n" + (1...40).map { "## Section \($0)\n\n\(paragraph)" }.joined(separator: "\n\n") + "\n"
        let host = ReadingWindow(markdown, mode: .read)
        defer { host.close() }
        host.settings.showsLineNumbersInPreview = true
        let webView = try renderedPreview(host)
        host.spin(until: { (try? evaluate("!!document.querySelector('.md2-line-gutter span')", in: webView)) as? Bool == true })
        _ = try evaluate("window.scrollTo(0, document.getElementById('section-10').offsetTop)", in: webView)
        host.spin(0.3)
        // The lowest number in the bottom third of the viewport.
        let picked = try XCTUnwrap(evaluate("""
        (function () {
          var spans = document.querySelectorAll('.md2-line-gutter span');
          var line = null;
          for (var i = 0; i < spans.length; i++) {
            var top = spans[i].getBoundingClientRect().top;
            if (top > window.innerHeight * 0.66 && top < window.innerHeight - 40) { line = spans[i].getAttribute('data-md2-gutter'); }
          }
          return line;
        })()
        """, in: webView) as? String)
        let line = try XCTUnwrap(Int(picked))
        let target = try XCTUnwrap(MarkdownEditorView.Coordinator.sourceLineRange(forLine: line, in: markdown as NSString))

        try click(".md2-line-gutter span[data-md2-gutter=\"\(line)\"]", in: webView, window: host.window)
        host.spin(until: {
            guard let editor = host.store.editorSession.textView, let storage = editor.textStorage,
                  editor.window != nil, editor.selectedRange() == target else { return false }
            return storage.attribute(.paragraphStyle, at: storage.length - 1, effectiveRange: nil) != nil
        })
        host.spin(0.5)
        let editor = try XCTUnwrap(host.store.editorSession.textView)
        XCTAssertEqual(editor.selectedRange(), target, "line \(line) must be selected")
        let layoutManager = try XCTUnwrap(editor.layoutManager)
        var lineRect = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: target.location), effectiveRange: nil)
        lineRect.origin.y += editor.textContainerOrigin.y
        // The editor keeps one container inset above a jump target.
        XCTAssertEqual(
            lineRect.minY - editor.visibleRect.minY, editor.textContainerOrigin.y, accuracy: lineRect.height / 2,
            "line \(line) must be at the top once styled: \(lineRect) in \(editor.visibleRect)"
        )
    }

    /// A preview gutter number selects its line in the editor. Read mode opens
    /// the editor on it; Side by Side selects it in place and keeps the preview.
    @MainActor func testPreviewGutterNumberSelectsItsLineInTheEditor() throws {
        let paragraph = String(repeating: "Reading text that wraps across the preview. ", count: 12)
        let markdown = "# Top\n\n\(paragraph)\n\nTarget paragraph.\n\n\(paragraph)"
        let target = (markdown as NSString).range(of: "Target paragraph.\n")
        let number = ".md2-line-gutter span[data-md2-gutter=\"5\"]"
        for mode in [EditorMode.read, .split] {
            let host = ReadingWindow(markdown, mode: mode)
            defer { host.close() }
            host.settings.showsLineNumbersInPreview = true
            let webView = try renderedPreview(host)
            host.spin(until: { (try? evaluate("!!document.querySelector('\(number)')", in: webView)) as? Bool == true })

            try click(number, in: webView, window: host.window)
            // Read mode creates the editor's text view when the editor mounts.
            host.spin(until: {
                guard let editor = host.store.editorSession.textView else { return false }
                return editor.window != nil && editor.selectedRange() == target
            })
            let editor = try XCTUnwrap(
                host.store.editorSession.textView,
                "\(mode): the editor must open; the number is at \(String(describing: try? rect(of: number, in: webView)))"
            )

            XCTAssertEqual(editor.selectedRange(), target, "\(mode): the clicked line must be selected")
            XCTAssertTrue(editor.window?.firstResponder === editor, "\(mode): the editor must take focus")
            let layoutManager = try XCTUnwrap(editor.layoutManager)
            var lineRect = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: target.location), effectiveRange: nil)
            lineRect.origin.y += editor.textContainerOrigin.y
            XCTAssertTrue(editor.visibleRect.intersects(lineRect), "\(mode): the selected line must be on screen")
            if mode == .split {
                XCTAssertNotNil(host.find(WKWebView.self), "Side by Side keeps the preview")
            }
        }
    }

    /// Clicks the center of `selector` in `webView` with real mouse events, so
    /// the page sees a trusted click. It waits until the element stops moving:
    /// the sidebar and the window settle after the page loads, and a reflow
    /// between measuring and clicking would miss a small target. The events go
    /// to the web view itself: the test process cannot make its window key,
    /// and a window that is not key would spend the first click on activating
    /// itself.
    @MainActor private func click(_ selector: String, in webView: WKWebView, window: NSWindow) throws {
        var box = try rect(of: selector, in: webView)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let settle = expectation(description: "layout settles")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { settle.fulfill() }
            wait(for: [settle], timeout: 1)
            let next = try rect(of: selector, in: webView)
            if next == box { break }
            box = next
        }
        let center = [box[0] + box[2] / 2, box[1] + box[3] / 2]
        let y = webView.isFlipped ? center[1] : Double(webView.bounds.height) - center[1]
        let location = webView.convert(NSPoint(x: center[0], y: y), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ))
            if type == .leftMouseDown { webView.mouseDown(with: event) } else { webView.mouseUp(with: event) }
        }
    }

    /// The viewport rect of `selector` as `[left, top, width, height]`.
    @MainActor private func rect(of selector: String, in webView: WKWebView) throws -> [Double] {
        try XCTUnwrap(
            evaluate("(function () { var r = document.querySelector('\(selector)').getBoundingClientRect(); return [r.left, r.top, r.width, r.height]; })()", in: webView) as? [Double],
            "no element matches \(selector)"
        )
    }

    /// The preview once every outline heading is in the page. The render worker
    /// can deliver the document after the first page load on a slow runner, so
    /// a web view that has stopped loading may still show an earlier render, and
    /// looking a heading up by its id would find nothing.
    @MainActor private func renderedPreview(_ host: ReadingWindow) throws -> WKWebView {
        let webView = try host.preview()
        let ids = String(decoding: try JSONSerialization.data(withJSONObject: host.store.rendered.outline.map(\.id)), as: UTF8.self)
        let allPresent = "\(ids).every(id => document.getElementById(id) !== null)"
        host.spin(until: { (try? evaluate(allPresent, in: webView)) as? Bool == true })
        return webView
    }

    @MainActor private func evaluate(_ script: String, in webView: WKWebView) throws -> Any? {
        let done = expectation(description: "JavaScript")
        var output: Any?
        var failure: Error?
        webView.evaluateJavaScript(script) { value, error in output = value; failure = error; done.fulfill() }
        wait(for: [done], timeout: 5)
        if let failure { throw failure }
        return output
    }
}

@MainActor private final class ReadingWindow: NSObject, NSWindowDelegate {
    let suite = "ReadingImprovementsGUITests-\(UUID())"
    let store = DocumentStore()
    let settings: AppSettings
    let window: NSWindow
    let hosting: NSHostingView<ContentView>

    init(_ text: String, mode: EditorMode = .write) {
        _ = NSApplication.shared
        settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.language = .english
        settings.newDocumentMode = mode
        store.text = text
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        hosting = NSHostingView(rootView: ContentView(document: store, settings: settings, onOpen: {}))
        super.init()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        spin(0.6)
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { store.undoManager }

    func find<T: NSView>(_ type: T.Type, in view: NSView? = nil) -> T? {
        let view = view ?? hosting
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }

    func preview() throws -> WKWebView {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let web = find(WKWebView.self), !web.isLoading, web.url != nil { spin(0.3); return web }
            spin(0.05)
        }
        return try XCTUnwrap(find(WKWebView.self))
    }

    func spin(_ duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    /// Spins until `condition` holds or `timeout` passes. Waiting on the outcome
    /// instead of a fixed interval lets a slow CI runner take longer to deliver
    /// a WebKit round trip without failing the assertion that follows.
    func spin(until condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { spin(0.02) }
    }
    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.delegate = nil
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}
