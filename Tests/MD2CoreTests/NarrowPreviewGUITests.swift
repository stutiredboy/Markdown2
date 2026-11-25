import AppKit
import MD2Core
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

final class NarrowPreviewGUITests: XCTestCase {
    @MainActor
    func testLongInlineHashWrapsAndCopiesExactlyWhileWideBlocksScrollLocally() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Requires a native preview and pasteboard.")
        let hash = String(repeating: "0123456789abcdef", count: 4)
        let document = MarkdownRenderer().render("""
            Verify the checksum `\(hash)` before opening the document.

            | First column | Second column | Third column |
            | --- | --- | --- |
            | \(hash) | \(hash) | \(hash) |

            ```
            \(hash)\(hash)
            ```
            """, assetMode: .appScheme)
        let host = InteractionTestWindow()
        defer { host.close() }
        let preview = MarkdownPreviewView(
            html: document.html, bodyHTML: document.body, baseURL: nil,
            jumpHeadingID: .constant(nil), jumpFraction: .constant(nil), jumpAnchor: .constant(nil),
            findQuery: .constant(""), findNavigation: .constant(nil), focusToken: nil
        )
        host.host(preview, width: 420)
        let web = try XCTUnwrap(host.descendants(WKWebView.self).first)
        try host.waitForPage("innerWidth === 420 && !!document.querySelector('main p code')",
                             in: web, context: "420 CSS px preview")
        XCTAssertTrue(host.window.makeFirstResponder(web))
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
        XCTAssertEqual(board.string(forType: .string), hash)
        for selector in ["table", "pre"] {
            let scrollsLocally = try host.js("""
                (() => {
                    const block = document.querySelector('\(selector)');
                    block.scrollLeft = block.scrollWidth;
                    return ['auto', 'scroll'].includes(getComputedStyle(block).overflowX) &&
                        block.scrollLeft > 0 && block.scrollWidth > block.clientWidth &&
                        block.getBoundingClientRect().right <= innerWidth && scrollX === 0;
                })()
                """, web) as? Bool
            XCTAssertEqual(scrollsLocally, true, selector)
        }
        print("420 CSS px preview: 64-character hash spans \(lines) lines, page width \(try XCTUnwrap(geometry["page"])) px.")
    }
}
