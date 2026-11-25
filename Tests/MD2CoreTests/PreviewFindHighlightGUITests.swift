import AppKit
import MD2Core
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

final class PreviewFindHighlightGUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 for WebKit layout and appearance checks.")
    }

    @MainActor
    func testDenseChineseMatchesPreserveEveryLineAndContrastInBothAppearances() throws {
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

            _ = try harness.js("window.originalFindText = document.querySelector('main p').firstChild; true", web)
            coordinator.runFindWhenReady("任务", in: web)
            try harness.waitForPage("""
                CSS.highlights.get('md2-find')?.size === 100 &&
                [...CSS.highlights.get('md2-find')].every(r => r.startContainer === window.originalFindText && r.toString() === '任务') &&
                !!document.querySelector('.md2-find-outline > i')
                """, in: web,
                                    context: "all 100 occurrences are highlighted")
            XCTAssertEqual(try lineStarts(in: web, harness: harness), original)
            let contrast = try XCTUnwrap(try harness.js(Self.contrastProbe, web) as? [String: Double])
            let ordinary = try XCTUnwrap(contrast["ordinary"])
            let current = try XCTUnwrap(contrast["current"])
            XCTAssertGreaterThanOrEqual(ordinary, 4.5)
            XCTAssertGreaterThanOrEqual(current, 4.5)
            XCTAssertGreaterThan(try XCTUnwrap(contrast["outlineWidth"]), 0)

            _ = try harness.js("window.__md2FindNext(true); true", web)
            try harness.waitForPage("""
                [...CSS.highlights.get('md2-find-current')][0] === [...CSS.highlights.get('md2-find')][1]
                """, in: web, context: "Next moves the current range to the second occurrence")
            XCTAssertEqual(try lineStarts(in: web, harness: harness), original)

            coordinator.runFindWhenReady("", in: web)
            try harness.waitForPage("""
                !CSS.highlights.has('md2-find') && !CSS.highlights.has('md2-find-current') &&
                !document.querySelector('.md2-find-outline > i') &&
                document.querySelector('main p').firstChild === window.originalFindText
                """, in: web, context: "clearing Find removes the paint and preserves the original text node")
            XCTAssertEqual(try lineStarts(in: web, harness: harness), original)
            XCTAssertEqual(try harness.js("document.querySelector('main p').textContent", web) as? String, text)
            print("Preview Find \(appearance.rawValue), 420 CSS px, 100 matches, \(original.count) lines; ordinary \(ordinary), current \(current)")
        }
    }

    @MainActor
    func testCurrentMatchRevealsInsideAnOverflowingCodeBlock() throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        let line = String(repeating: "prefix ", count: 100) + "needle" + String(repeating: " suffix", count: 30)
        let rendered = MarkdownRenderer().render("```\n" + line + "\n```", assetMode: .appScheme)
        let preview = MarkdownPreviewView(
            html: rendered.html, bodyHTML: rendered.body, baseURL: nil,
            jumpHeadingID: .constant(nil), jumpFraction: .constant(nil), jumpAnchor: .constant(nil),
            findQuery: .constant(""), findNavigation: .constant(nil), focusToken: nil
        )
        harness.host(preview, width: 420)
        let web = try XCTUnwrap(harness.descendants(WKWebView.self).first)
        let coordinator = try XCTUnwrap(web.navigationDelegate as? MarkdownPreviewView.Coordinator)
        try harness.waitForPage("""
            document.querySelector('pre')?.scrollWidth > innerWidth * 3 && document.querySelector('pre').scrollLeft === 0
            """, in: web, context: "needle is outside the code viewport before Find")
        coordinator.runFindWhenReady("needle", in: web)
        try harness.waitForPage("""
            (() => {
                const range = CSS.highlights.get('md2-find-current')?.values().next().value;
                if (!range || range.toString() !== 'needle') return false;
                const pre = document.querySelector('pre'), clip = pre.getBoundingClientRect();
                const r = range.getBoundingClientRect();
                return pre.scrollLeft > 0 && r.left >= clip.left - 1 && r.right <= clip.right + 1 &&
                    r.top >= 0 && r.bottom <= innerHeight && scrollX === 0;
            })()
            """, in: web, context: "the code block scrolls horizontally to reveal its current match")
    }

    // Equal paragraph heights can hide a character moving to a different line.
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
            const paragraph = document.querySelector('main p');
            const ordinary = getComputedStyle(paragraph, '::highlight(md2-find)');
            const current = getComputedStyle(paragraph, '::highlight(md2-find-current)');
            const outline = getComputedStyle(document.querySelector('.md2-find-outline > i'));
            return {ordinary: contrast(ordinary), current: contrast(current),
                    outlineWidth: Math.max(parseFloat(outline.borderTopWidth), parseFloat(outline.outlineWidth))};
        })()
        """
}
