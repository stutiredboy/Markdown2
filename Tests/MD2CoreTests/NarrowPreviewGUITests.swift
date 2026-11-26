import AppKit
import MD2Core
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

final class NarrowPreviewGUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Requires a native preview and pasteboard.")
    }

    @MainActor func testBareHashAndAutomaticLinkWrapAndCopyWithoutPageOverflow() throws {
        let hash = String(repeating: "0123456789abcdef", count: 4)
        let url = "https://example.test/" + hash
        let documents: [(label: String, text: String, selector: String, href: String?)] = [
            ("bare hash", hash, "main p", nil),
            ("automatic link", url, "main p a", url)
        ]
        for document in documents {
            let host = InteractionTestWindow()
            defer { host.close() }
            let web = try mountPreview(document.text, target: document.selector, in: host)
            let geometry = try XCTUnwrap(try host.js("""
                (() => {
                    const root = document.documentElement, body = document.body;
                    const scrolling = document.scrollingElement;
                    const target = document.querySelector('\(document.selector)');
                    const range = document.createRange();
                    range.selectNodeContents(target);
                    const fragments = [...range.getClientRects()].filter(rect => rect.width > 0 && rect.height > 0);
                    const lines = new Set(fragments.map(rect => rect.top)).size;
                    const fits = fragments.every(rect => rect.left >= 0 && rect.right <= innerWidth);
                    scrolling.scrollLeft = scrolling.scrollWidth;
                    const horizontalScroll = scrolling.scrollLeft;
                    scrolling.scrollLeft = 0;
                    getSelection().removeAllRanges();
                    getSelection().addRange(range);
                    return {viewport: innerWidth, root: root.scrollWidth, body: body.scrollWidth,
                            main: document.querySelector('main').scrollWidth, lines, fits: Number(fits), horizontalScroll};
                })()
                """, web) as? [String: Int])
            let viewport = try XCTUnwrap(geometry["viewport"])
            let width = try XCTUnwrap(geometry["root"])
            let body = try XCTUnwrap(geometry["body"])
            let main = try XCTUnwrap(geometry["main"])
            let lines = try XCTUnwrap(geometry["lines"])
            let scroll = try XCTUnwrap(geometry["horizontalScroll"])
            let copied = try copySelection(from: web, in: host)
            let href = try host.js("document.querySelector('main a')?.getAttribute('href') ?? ''", web) as? String
            print("420 CSS px, 16 px body, \(document.label): viewport=\(viewport), root=\(width), body=\(body), main=\(main), "
                  + "lines=\(lines), horizontal scroll=\(scroll), exact native copy=\(copied == document.text), exact href=\(href == (document.href ?? ""))")
            XCTAssertEqual(viewport, 420, document.label)
            XCTAssertEqual(width, viewport, document.label)
            XCTAssertEqual(body, viewport, document.label)
            XCTAssertEqual(main, viewport, document.label)
            XCTAssertEqual(geometry["fits"], 1, document.label)
            XCTAssertGreaterThan(lines, 1, document.label)
            XCTAssertEqual(scroll, 0, document.label)
            XCTAssertEqual(copied, document.text, document.label)
            XCTAssertEqual(href, document.href ?? "", document.label)
        }
    }

    @MainActor func testLongInlineHashWrapsAndCopiesExactlyWhileWideBlocksScrollLocally() throws {
        let hash = String(repeating: "0123456789abcdef", count: 4)
        let source = """
            Verify the checksum `\(hash)` before opening the document.

            | First column | Second column | Third column |
            | --- | --- | --- |
            | \(hash) | \(hash) | \(hash) |

            ```
            \(hash)\(hash)
            ```
            """
        let host = InteractionTestWindow()
        defer { host.close() }
        let web = try mountPreview(source, target: "main p code", in: host)
        let geometry = try XCTUnwrap(try host.js("""
            (() => {
                const paragraph = document.querySelector('main p');
                const range = document.createRange();
                range.selectNodeContents(paragraph);
                const proseFits = [...range.getClientRects()].every(r => r.left >= 0 && r.right <= innerWidth);
                range.selectNodeContents(paragraph.querySelector('code'));
                getSelection().removeAllRanges();
                getSelection().addRange(range);
                return {page: document.documentElement.scrollWidth, lines: range.getClientRects().length,
                        proseFits: Number(proseFits)};
            })()
            """, web) as? [String: Int])
        XCTAssertEqual(geometry["page"], 420)
        XCTAssertEqual(geometry["proseFits"], 1)
        let lines = try XCTUnwrap(geometry["lines"])
        XCTAssertGreaterThan(lines, 1)
        XCTAssertEqual(try copySelection(from: web, in: host), hash)
        for selector in ["table", "pre"] {
            let block = try XCTUnwrap(try host.js("""
                (() => {
                    const block = document.querySelector('\(selector)');
                    const { clientWidth, scrollWidth } = block;
                    block.scrollLeft = scrollWidth;
                    return {clientWidth, scrollWidth, scrollLeft: block.scrollLeft, pageScroll: scrollX,
                            scrollable: Number(['auto', 'scroll'].includes(getComputedStyle(block).overflowX)),
                            fits: Number(block.getBoundingClientRect().right <= innerWidth)};
                })()
                """, web) as? [String: Int])
            let clientWidth = try XCTUnwrap(block["clientWidth"])
            let scrollWidth = try XCTUnwrap(block["scrollWidth"])
            let scrollLeft = try XCTUnwrap(block["scrollLeft"])
            let pageScroll = try XCTUnwrap(block["pageScroll"])
            print("420 CSS px preview, \(selector): client width=\(clientWidth), content width=\(scrollWidth), block scroll=\(scrollLeft), page scroll=\(pageScroll)")
            XCTAssertEqual(block["scrollable"], 1, selector)
            XCTAssertEqual(block["fits"], 1, selector)
            XCTAssertGreaterThan(scrollWidth, clientWidth, selector)
            XCTAssertGreaterThan(scrollLeft, 0, selector)
            XCTAssertEqual(pageScroll, 0, selector)
        }
        print("420 CSS px preview: 64-character inline-code hash spans \(lines) lines, page width \(try XCTUnwrap(geometry["page"])) px.")
    }

    @MainActor private func mountPreview(_ source: String, target: String, in host: InteractionTestWindow) throws -> WKWebView {
        let document = MarkdownRenderer().render(source, assetMode: .appScheme)
        let preview = MarkdownPreviewView(
            html: document.html, bodyHTML: document.body, baseURL: nil,
            jumpHeadingID: .constant(nil), jumpFraction: .constant(nil), jumpAnchor: .constant(nil),
            findQuery: .constant(""), findNavigation: .constant(nil), focusToken: nil,
            typography: TypographySettings(fontSize: 16)
        )
        host.host(preview, width: 420)
        let web = try XCTUnwrap(host.descendants(WKWebView.self).first)
        try host.waitForPage("innerWidth === 420 && getComputedStyle(document.body).fontSize === '16px' && !!document.querySelector('\(target)')",
                             in: web, context: "420 CSS px preview and 16 px body")
        XCTAssertTrue(host.window.makeFirstResponder(web))
        return web
    }

    @MainActor private func copySelection(from web: WKWebView, in host: InteractionTestWindow) throws -> String {
        let board = NSPasteboard.general
        let saved = board.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        defer {
            board.clearContents()
            board.writeObjects(saved.map { entries in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            })
        }
        board.clearContents()
        XCTAssertTrue(NSApp.sendAction(#selector(NSText.copy(_:)), to: web, from: nil))
        host.spin(until: { board.string(forType: .string) != nil })
        return try XCTUnwrap(board.string(forType: .string))
    }
}
