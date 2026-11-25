import AppKit
import MD2Core
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

final class PreviewFindHighlightGUITests: XCTestCase {
    @MainActor
    func testDenseChineseMatchesPreserveEveryLineAndContrastInBothAppearances() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 for WebKit layout and appearance checks.")
        let text = String(repeating: "启动任务，核对任务状态。", count: 50)
        let rendered = MarkdownRenderer().render(text, assetMode: .appScheme)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let harness = InteractionTestWindow()
            defer { harness.close() }
            harness.window.appearance = NSAppearance(named: appearance)
            let preview = MarkdownPreviewView(
                html: rendered.html, bodyHTML: rendered.body, baseURL: nil,
                jumpHeadingID: .constant(nil), jumpFraction: .constant(nil), jumpAnchor: .constant(nil),
                findQuery: .constant(""), findNavigation: .constant(nil), focusToken: nil
            )
            harness.host(preview, width: 420)
            let web = try XCTUnwrap(harness.descendants(WKWebView.self).first)
            let coordinator = try XCTUnwrap(web.navigationDelegate as? MarkdownPreviewView.Coordinator)
            try harness.waitForPage("!!document.querySelector('main p') && window.innerWidth === 420", in: web,
                                    context: "laid out at the TODO's 420 CSS px")
            XCTAssertEqual(try harness.js("matchMedia('(prefers-color-scheme: dark)').matches", web) as? Bool,
                           appearance == .darkAqua)
            let original = try lineStarts(in: web, harness: harness)
            XCTAssertGreaterThan(original.count, 2)

            coordinator.runFindWhenReady("任务", in: web)
            try harness.waitForPage("document.querySelectorAll('mark.md2-find').length === 100", in: web,
                                    context: "all 100 occurrences are highlighted")
            XCTAssertEqual(try lineStarts(in: web, harness: harness), original)
            let contrast = try XCTUnwrap(try harness.js(Self.contrastProbe, web) as? [String: Double])
            let ordinary = try XCTUnwrap(contrast["ordinary"])
            let current = try XCTUnwrap(contrast["current"])
            XCTAssertGreaterThanOrEqual(ordinary, 4.5)
            XCTAssertGreaterThanOrEqual(current, 4.5)
            XCTAssertGreaterThan(try XCTUnwrap(contrast["outlineWidth"]), 0)

            coordinator.runFindWhenReady("", in: web)
            try harness.waitForPage("!document.querySelector('mark.md2-find')", in: web, context: "highlights cleared")
            XCTAssertEqual(try lineStarts(in: web, harness: harness), original)
            XCTAssertEqual(try harness.js("document.querySelector('main p').textContent", web) as? String, text)
            print("Preview Find \(appearance.rawValue), 420 CSS px, 100 matches, \(original.count) lines; ordinary \(ordinary), current \(current)")
        }
    }

    // Measure the visual line of each character across all text nodes, including
    // the fragments Find wraps in <mark>. Equal heights alone could hide reflow.
    @MainActor
    private func lineStarts(in web: WKWebView, harness: InteractionTestWindow) throws -> [Int] {
        try XCTUnwrap(try harness.js("""
            (() => {
                const walker = document.createTreeWalker(document.querySelector('main p'), NodeFilter.SHOW_TEXT);
                const starts = [], range = document.createRange();
                let offset = 0, previousTop, node;
                while ((node = walker.nextNode())) {
                    for (let i = 0; i < node.length; i++, offset++) {
                        range.setStart(node, i);
                        range.setEnd(node, i + 1);
                        const top = range.getBoundingClientRect().top;
                        if (top !== previousTop) starts.push(offset);
                        previousTop = top;
                    }
                }
                return starts;
            })()
            """, web) as? [Int])
    }

    private static let contrastProbe = """
        (() => {
            function luminance(color) {
                const components = color.match(/[0-9.]+/g).map(Number).map(v => v / 255)
                    .map(v => v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4));
                return 0.2126 * components[0] + 0.7152 * components[1] + 0.0722 * components[2];
            }
            function contrast(style) {
                const fg = luminance(style.color), bg = luminance(style.backgroundColor);
                return (Math.max(fg, bg) + 0.05) / (Math.min(fg, bg) + 0.05);
            }
            const ordinary = getComputedStyle(document.querySelector('mark.md2-find:not(.md2-find-current)'));
            const current = getComputedStyle(document.querySelector('mark.md2-find-current'));
            return {ordinary: contrast(ordinary), current: contrast(current), outlineWidth: parseFloat(current.outlineWidth)};
        })()
        """
}
