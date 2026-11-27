import AppKit
import MD2Core
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

final class PreviewTableResizeGUITests: XCTestCase {
    private static let table = """
        | First column | Second column | Third column |
        | --- | --- | --- |
        | Monthly notes and status | Notes and other details | Owner and follow-up |
        """

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Requires a native preview and mouse events.")
    }

    @MainActor func testDraggingWidensOnlyTargetColumnAndKeepsOverflowInsideTable() throws {
        let host = InteractionTestWindow()
        defer { host.close() }
        let web = try mount(Self.table, in: host, width: 420)
        let before = try headerWidths(in: web, host: host)
        let beforePageWidth = try host.js("document.documentElement.scrollWidth", web) as? Int
        XCTAssertEqual(beforePageWidth, 420)

        try dragColumn(1, by: 120, in: web, host: host)
        let after = try headerWidths(in: web, host: host)
        XCTAssertEqual(after[0], before[0], accuracy: 2)
        XCTAssertEqual(after[1], before[1] + 120, accuracy: 2)
        XCTAssertEqual(after[2], before[2], accuracy: 2)

        let scroll = try XCTUnwrap(try host.js("""
            (() => {
                const table = document.querySelector('main table');
                table.scrollLeft = table.scrollWidth;
                document.scrollingElement.scrollLeft = document.documentElement.scrollWidth;
                return [table.clientWidth, table.scrollWidth, table.scrollLeft,
                        document.documentElement.scrollWidth, scrollX];
            })()
            """, web) as? [Int])
        XCTAssertGreaterThan(scroll[1], scroll[0])
        XCTAssertGreaterThan(scroll[2], 0)
        XCTAssertEqual(scroll[3], beforePageWidth)
        XCTAssertEqual(scroll[4], 0)
    }

    @MainActor func testBothSidesOfBoundaryShowResizeCursorAndAccentLine() throws {
        let host = InteractionTestWindow()
        defer { host.close() }
        let web = try mount(Self.table, in: host, width: 420)
        _ = try host.js("""
            document.addEventListener('mousemove', event => {
                if (event.isTrusted) { window.__pointerX = event.clientX; }
            });
            true
            """, web)
        for inset in [2.0, -2.0] {
            let edge = try headerEdge(1, in: web, host: host, inset: inset)
            try hover(at: edge, in: web, host: host)
            try host.waitForPage("""
                (() => {
                    const hot = document.querySelector('thead th:nth-child(2)');
                    const cursor = getComputedStyle(document.elementFromPoint(\(edge.x), \(edge.y))).cursor;
                    const shadow = getComputedStyle(hot).boxShadow;
                    return Math.abs(window.__pointerX - \(edge.x)) <= 1
                        && hot.classList.contains('md2-col-resize-hot') && cursor === 'col-resize'
                        && shadow.includes('inset') && shadow.includes('-2px');
                })()
                """, in: web, context: "second header boundary, inset \(inset)")
        }
    }

    @MainActor func testDraggingLeftClampsWidthAndKeepsHeaderAndBodyAligned() throws {
        let host = InteractionTestWindow()
        defer { host.close() }
        let source = Self.table.replacingOccurrences(of: "Owner and follow-up", with: "Owner and follow-up from the prior reporting period")
        let web = try mount(source, in: host, width: 700)
        let before = try headerWidths(in: web, host: host)
        let edge = try headerEdge(2, in: web, host: host)
        // The native gesture ends inside the view, even after a 500 px drag.
        XCTAssertGreaterThan(edge.x, 500)
        try dragColumn(2, by: -500, in: web, host: host)
        let after = try headerWidths(in: web, host: host)
        XCTAssertEqual(after[0], before[0], accuracy: 2)
        XCTAssertEqual(after[1], before[1], accuracy: 2)
        XCTAssertEqual(after[2], 40)
        let columns = try XCTUnwrap(try host.js("""
            (() => {
                const table = document.querySelector('main table');
                const headers = table.tHead.rows[0].cells, body = table.tBodies[0].rows[0].cells;
                return Array.from(headers, (header, index) => {
                    const th = header.getBoundingClientRect(), td = body[index].getBoundingClientRect();
                    return [th.left, td.left, th.width, td.width];
                });
            })()
            """, web) as? [[Double]])
        for column in columns {
            XCTAssertEqual(column[0], column[1], accuracy: 1, "column left edge")
            XCTAssertEqual(column[2], column[3], accuracy: 1, "column width")
        }
    }

    @MainActor func testDraggingScrolledTableClampsWidthAtTwoThousand() throws {
        let host = InteractionTestWindow()
        defer { host.close() }
        let key = "3|0|First column\u{1f}Second column\u{1f}Third column"
        host.store.previewTableColumnWidths.apply(.init(key: key, widths: [1970, 110, 100]))
        let web = try mount(Self.table, in: host, width: 420)
        try host.waitForPage("!!document.querySelector('main table.md2-col-resized')", in: web,
                             context: "restored wide table")
        _ = try host.js("document.querySelector('main table').scrollLeft = 1800; true", web)
        let edge = try headerEdge(0, in: web, host: host)
        XCTAssertGreaterThan(edge.x, 0)
        XCTAssertLessThan(edge.x + 120, 420)
        try dragColumn(0, by: 120, in: web, host: host)
        XCTAssertEqual(try headerWidths(in: web, host: host), [2000, 110, 100])
        host.spin(until: { host.store.previewTableColumnWidths.entries[key] == [2000, 110, 100] })
        XCTAssertEqual(host.store.previewTableColumnWidths.entries[key], [2000, 110, 100])
    }

    @MainActor func testDraggingLinkedHeaderDoesNotSelectTextOrActivateLink() throws {
        let host = InteractionTestWindow()
        defer { host.close() }
        var opened: [String] = []
        let source = Self.table.replacingOccurrences(of: "Second column", with: "[x](https://example.com)")
            + "\n\n[After](https://example.com/after)"
        let web = try mount(source, in: host, width: 420, onOpenWithSystem: { opened.append($0.absoluteString) })
        // Extend the real Markdown link into the edge's padding so that the
        // gesture tests a link target, even though the label is just "x".
        _ = try host.js("""
            (() => {
                const link = document.querySelector('main th a');
                link.style.cssText = 'display:block;margin-right:-10px';
                document.addEventListener('selectionchange', () => {
                    if (getSelection().toString()) { window.__selectedDuringDrag = true; }
                });
                return true;
            })()
            """, web)
        let edge = try headerEdge(1, in: web, host: host)
        XCTAssertEqual(try host.js("document.elementFromPoint(\(edge.x), \(edge.y)).tagName", web) as? String, "A")
        // Verify the routing callback with a click away from the edge. All
        // subsequent callbacks would indicate unintended link activation.
        try clickCenter(of: "main th a", in: web, host: host)
        host.spin(until: { opened.count == 1 })
        XCTAssertEqual(opened, ["https://example.com/"])

        try dragColumn(1, by: 90, in: web, host: host)
        XCTAssertEqual(try host.js("getSelection().toString()", web) as? String, "")
        XCTAssertEqual(try host.js("window.__selectedDuringDrag === true", web) as? Bool, false)
        try clickCenter(of: "main p a", in: web, host: host)
        host.spin(until: { opened.last == "https://example.com/after" })
        XCTAssertEqual(opened, ["https://example.com/", "https://example.com/after"])
    }

    @MainActor func testDoubleClickRestoresAutomaticLayoutAndClearsSavedWidths() throws {
        let host = InteractionTestWindow()
        defer { host.close() }
        // Keep explicit center/right alignment while also exercising cells
        // whose original style attribute was absent.
        let source = Self.table.replacingOccurrences(of: "| --- | --- | --- |", with: "| :---: | ---: | --- |")
        let web = try mount(source, in: host)
        let before = try headerWidths(in: web, host: host)
        _ = try host.js("document.querySelectorAll('main table :is(th,td):last-child').forEach(cell => cell.removeAttribute('style')); true", web)
        let styles = "JSON.stringify(Array.from(document.querySelectorAll('main table :is(th, td, thead, tbody)'), el => el.hasAttribute('style') ? el.style.cssText : null))"
        let originalStyles = try XCTUnwrap(try host.js(styles, web) as? String)
        try dragColumn(1, by: 100, in: web, host: host)
        XCTAssertFalse(host.store.previewTableColumnWidths.entries.isEmpty)

        try host.click(at: headerEdge(1, in: web, host: host), count: 2, in: web)
        try host.waitForPage("""
            !!document.querySelector('main table') && !document.querySelector('main table.md2-col-resized') &&
                !document.querySelector('main table :is(thead, tbody)[style]')
            """, in: web, context: "double-click restores original table layout")
        host.spin(until: { host.store.previewTableColumnWidths.entries.isEmpty })
        XCTAssertTrue(host.store.previewTableColumnWidths.entries.isEmpty)
        XCTAssertEqual(try host.js(styles, web) as? String, originalStyles)
        XCTAssertEqual(try headerWidths(in: web, host: host), before)
    }

    @MainActor func testCaptionStaysBelowBodyAndResizePreservesTableNodes() throws {
        let host = InteractionTestWindow()
        defer { host.close() }
        let web = try mount(Self.table + "\n: Monthly report {#tbl:report}", in: host, width: 560)
        _ = try host.js("""
            window.__tableNodes = () => {
                const walker = document.createTreeWalker(document.querySelector('main table'), NodeFilter.SHOW_ALL);
                const nodes = [walker.currentNode];
                while (walker.nextNode()) { nodes.push(walker.currentNode); }
                return nodes;
            };
            window.__originalTableNodes = window.__tableNodes();
            window.__originalMainNodes = Array.from(document.querySelector('main').childNodes);
            true
            """, web)
        let layout = """
            (() => {
                const table = document.getElementById('tbl:report');
                if (!table?.caption || table.caption.textContent.trim() !== 'Table 1: Monthly report') { return false; }
                const caption = table.caption.getBoundingClientRect(), body = table.tBodies[0].getBoundingClientRect();
                const unchanged = (original, current) => original.length === current.length &&
                    original.every((node, index) => node === current[index]);
                return caption.height > 0 && caption.top >= body.bottom - 1 &&
                    unchanged(window.__originalTableNodes, window.__tableNodes()) &&
                    unchanged(window.__originalMainNodes, document.querySelector('main').childNodes);
            })()
            """
        XCTAssertEqual(try host.js(layout, web) as? Bool, true, "original caption sits below the body")

        try dragColumn(1, by: 110, in: web, host: host)
        XCTAssertEqual(try host.js(layout, web) as? Bool, true, "resizing preserves caption position and DOM nodes")

        try host.click(at: headerEdge(1, in: web, host: host), count: 2, in: web)
        try host.waitForPage("!document.querySelector('main table.md2-col-resized') && (\(layout))", in: web,
                             context: "restored caption geometry and original DOM nodes")
    }

    @MainActor func testCommandDoubleClickAtBoundaryCannotEnterEditMode() throws {
        let host = InteractionTestWindow()
        defer { host.close() }
        var edits = 0
        let web = try mount(Self.table + "\n\nAn editable paragraph.", in: host,
                            onEnterEdit: { edits += 1 })
        // A real Cmd+double-click on a header interior exercises the same
        // source-line bridge and proves the edit callback is installed.
        let center = try midpoint(of: "main thead th:nth-child(2)", in: web, host: host)
        try host.click(at: center, count: 2, modifiers: .command, in: web)
        host.spin(until: { edits == 1 })
        XCTAssertEqual(edits, 1)

        // A reset proves that the boundary itself received the double-click.
        try dragColumn(1, by: 100, in: web, host: host)
        try host.click(at: headerEdge(1, in: web, host: host), count: 2, modifiers: .command, in: web)
        try host.waitForPage("!document.querySelector('main table.md2-col-resized')", in: web,
                             context: "Cmd+double-click reaches the boundary")
        host.spin(until: { host.store.previewTableColumnWidths.entries.isEmpty })
        XCTAssertTrue(host.store.previewTableColumnWidths.entries.isEmpty)
        XCTAssertEqual(edits, 1)
    }

    @MainActor func testLiveUpdateReusesUnaffectedTableAndRestoresWidthsOnReplacement() throws {
        let host = InteractionTestWindow()
        defer { host.close() }
        let original = Self.table + "\n\nOriginal surrounding paragraph."
        let web = try mount(original, in: host, liveUpdate: true)
        try dragColumn(1, by: 105, in: web, host: host)
        let before = try headerWidths(in: web, host: host)
        _ = try host.js("window.__t = document.querySelector('main table'); true", web)
        let hosting = try XCTUnwrap(host.window.contentView?.subviews.first as? NSHostingView<MarkdownPreviewView>)

        let updated = original.replacingOccurrences(of: "Original surrounding", with: "Updated surrounding")
        hosting.rootView = preview(updated, host: host, liveUpdate: true)
        try host.waitForPage("document.querySelector('main p')?.textContent === 'Updated surrounding paragraph.'",
                             in: web, context: "paragraph update")
        XCTAssertEqual(try host.js("window.__t === document.querySelector('main table')", web) as? Bool, true)
        XCTAssertEqual(try headerWidths(in: web, host: host), before)

        let changed = updated.replacingOccurrences(of: "Notes and other details", with: "Updated cell")
        hosting.rootView = preview(changed, host: host, liveUpdate: true)
        try host.waitForPage("document.querySelector('main td:nth-child(2)')?.textContent === 'Updated cell'",
                             in: web, context: "table update")
        XCTAssertEqual(try host.js("!!window.__t && window.__t !== document.querySelector('main table')", web) as? Bool, true)
        XCTAssertEqual(try headerWidths(in: web, host: host), before)
    }

    @MainActor func testPageReloadRestoresSavedWidths() throws {
        let host = InteractionTestWindow()
        defer { host.close() }
        let web = try mount(Self.table, in: host)
        try dragColumn(1, by: 105, in: web, host: host)
        let before = try headerWidths(in: web, host: host)
        _ = try host.js("window.__beforeReload = true; true", web)
        let url = try XCTUnwrap(web.url)
        web.reload()
        try host.waitForPage("window.__beforeReload !== true && !!document.querySelector('main table.md2-col-resized')",
                             in: web, context: "new page restores native width state")
        XCTAssertNotEqual(web.url, url)
        XCTAssertEqual(try headerWidths(in: web, host: host), before)
    }

    @MainActor func testTableWithMoreBodyCellsThanHeadersHasNoResizeZone() throws {
        let host = InteractionTestWindow()
        defer { host.close() }
        let web = try mount("""
            | First | Second |
            | --- | --- |
            | A | B |
            | C | D | E |
            """, in: host)
        let before = try headerWidths(in: web, host: host)
        XCTAssertEqual(try host.js("document.querySelector('main tbody tr:last-child').cells.length", web) as? Int, 3)
        let edge = try headerEdge(0, in: web, host: host)
        _ = try host.js("""
            document.addEventListener('mousemove', event => {
                if (event.isTrusted && event.target.closest('th') && Math.abs(event.clientX - \(edge.x)) <= 1) {
                    window.__sawHover = true;
                }
            });
            true
            """, web)
        try hover(at: edge, in: web, host: host)
        try host.waitForPage("window.__sawHover === true", in: web, context: "trusted mouse move over irregular header")
        XCTAssertEqual(try host.js("!!document.querySelector('.md2-col-resize-hot')", web) as? Bool, false)

        try host.drag(from: edge, to: NSPoint(x: edge.x + 100, y: edge.y), in: web)
        XCTAssertEqual(try headerWidths(in: web, host: host), before)
        XCTAssertEqual(try host.js("!!document.querySelector('main table.md2-col-resized')", web) as? Bool, false)
        XCTAssertTrue(host.store.previewTableColumnWidths.entries.isEmpty)
    }

    @MainActor func testReadAndSideBySideShareTheDocumentWidths() throws {
        let host = InteractionTestWindow()
        defer { host.close() }
        host.settings.newDocumentMode = .read
        host.store.text = Self.table
        host.host(ContentView(document: host.store, settings: host.settings, onOpen: {}), width: 980)
        let web = try XCTUnwrap(host.descendants(WKWebView.self).first)
        try host.waitForPage("!!document.querySelector('main thead th')", in: web, context: "Read table")
        try dragColumn(1, by: 90, in: web, host: host)
        let widths = try headerWidths(in: web, host: host)
        let saved = host.store.previewTableColumnWidths.entries

        for mode in [EditorMode.split, .read] {
            host.store.requestMode(mode)
            let split = mode == .split
            let editorIsHosted = { host.descendants(NSTextView.self).contains { $0 === host.store.editorSession.textView } }
            var activePreview: WKWebView?
            host.spin(until: {
                guard editorIsHosted() == split else { return false }
                // SwiftUI may still list the retired view after the editor
                // pane has switched. Its DOM remains readable after teardown.
                activePreview = host.descendants(WKWebView.self).first { candidate in
                    guard candidate.window === host.window, !candidate.isHiddenOrHasHiddenAncestor,
                          let coordinator = candidate.navigationDelegate as? MarkdownPreviewView.Coordinator else { return false }
                    return coordinator.resourceContextIsActive && coordinator.liveUpdate == split
                        && coordinator.isLoaded && !candidate.isLoading
                }
                return activePreview != nil
            })
            let preview = try XCTUnwrap(activePreview,
                "active, loaded \(mode) preview after mode switch (editor hosted: \(editorIsHosted()))")
            try host.waitForPage("document.querySelector('main table.md2-col-resized th:nth-child(2)')?.textContent === 'Second column'", in: preview,
                                 context: "restored table in \(mode)")
            XCTAssertEqual(try headerWidths(in: preview, host: host), widths)
            XCTAssertEqual(host.store.previewTableColumnWidths.entries, saved)
        }
    }

    @MainActor private func mount(_ source: String, in host: InteractionTestWindow, width: CGFloat = 700,
                                 liveUpdate: Bool = false, onEnterEdit: @escaping () -> Void = {},
                                 onOpenWithSystem: @escaping (URL) -> Void = { _ in }) throws -> WKWebView {
        host.host(preview(source, host: host, liveUpdate: liveUpdate, onEnterEdit: onEnterEdit,
                          onOpenWithSystem: onOpenWithSystem), width: width)
        let web = try XCTUnwrap(host.descendants(WKWebView.self).first)
        try host.waitForPage("innerWidth === \(width) && !!document.querySelector('main thead th')",
                             in: web, context: "rendered table in \(width) px preview")
        return web
    }

    @MainActor private func preview(_ source: String, host: InteractionTestWindow, liveUpdate: Bool,
                                   onEnterEdit: @escaping () -> Void = {},
                                   onOpenWithSystem: @escaping (URL) -> Void = { _ in }) -> MarkdownPreviewView {
        let rendered = MarkdownRenderer().render(source, assetMode: .appScheme)
        return MarkdownPreviewView(
            html: rendered.html, bodyHTML: rendered.body, baseURL: nil, liveUpdate: liveUpdate,
            onEditParagraph: { _ in onEnterEdit() }, tableColumnWidths: host.store.previewTableColumnWidths,
            jumpHeadingID: .constant(nil), jumpFraction: .constant(nil), jumpAnchor: .constant(nil),
            onEnterEdit: onEnterEdit, onOpenWithSystem: onOpenWithSystem,
            findQuery: .constant(""), findNavigation: .constant(nil), focusToken: nil,
            typography: TypographySettings(fontSize: 16)
        )
    }

    @MainActor private func headerWidths(in web: WKWebView, host: InteractionTestWindow) throws -> [Double] {
        try XCTUnwrap(try host.js("Array.from(document.querySelectorAll('main thead th'), cell => cell.getBoundingClientRect().width)",
                                 web) as? [Double])
    }

    @MainActor private func headerEdge(_ index: Int, in web: WKWebView, host: InteractionTestWindow,
                                      inset: Double = 2) throws -> NSPoint {
        let coordinates = try XCTUnwrap(try host.js("""
            (() => {
                const rect = document.querySelectorAll('main thead th')[\(index)].getBoundingClientRect();
                return [rect.right - \(inset), rect.top + rect.height / 2];
            })()
            """, web) as? [Double])
        return NSPoint(x: coordinates[0], y: coordinates[1])
    }

    @MainActor private func midpoint(of selector: String, in web: WKWebView, host: InteractionTestWindow) throws -> NSPoint {
        let coordinates = try XCTUnwrap(try host.js("""
            (() => {
                const rect = document.querySelector('\(selector)').getBoundingClientRect();
                return [rect.left + rect.width / 2, rect.top + rect.height / 2];
            })()
            """, web) as? [Double])
        return NSPoint(x: coordinates[0], y: coordinates[1])
    }

    @MainActor private func clickCenter(of selector: String, in web: WKWebView, host: InteractionTestWindow) throws {
        try host.click(at: midpoint(of: selector, in: web, host: host), in: web)
    }

    @MainActor private func hover(at point: NSPoint, in web: WKWebView, host: InteractionTestWindow) throws {
        // WebKit forwards this as a trusted DOM mousemove even when the test
        // process cannot take desktop focus. Without a preceding mouseDown,
        // the preview has no active resize gesture.
        try host.dragMouse(to: point, in: web)
    }

    @MainActor private func dragColumn(_ index: Int, by delta: CGFloat, in web: WKWebView,
                                      host: InteractionTestWindow) throws {
        let start = try headerEdge(index, in: web, host: host)
        try host.drag(from: start, to: NSPoint(x: start.x + delta, y: start.y), in: web)
        try host.waitForPage("!!document.querySelector('main table.md2-col-resized') && !document.documentElement.classList.contains('md2-col-resizing')",
                             in: web, context: "finished drag")
        host.spin(until: { !host.store.previewTableColumnWidths.entries.isEmpty })
        XCTAssertFalse(host.store.previewTableColumnWidths.entries.isEmpty, "the coordinator must save the drag")
    }
}
