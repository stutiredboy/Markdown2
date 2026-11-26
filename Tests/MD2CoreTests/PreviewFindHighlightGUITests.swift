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

    @MainActor
    func testAuthorHighlightsParticipateInNativeFind() throws {
        let suite = "PreviewFindHighlightGUITests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.newDocumentMode = .read
        settings.language = .english
        settings.enablesHighlight = true
        let store = DocumentStore(syntaxConfigProvider: { (settings.inlineFeatures, settings.alertLanguage) })
        let harness = InteractionTestWindow(store: store)
        defer { harness.close() }
        harness.settings.language = .english
        harness.window.appearance = NSAppearance(named: .aqua)
        store.text = "左==验收==右\n\n普通验收"
        harness.host(ContentView(document: store, settings: settings, onOpen: {}), width: 720)
        let web = try XCTUnwrap(harness.descendants(WKWebView.self).first)
        try harness.waitForPage("document.querySelector('main p > mark')?.textContent === '验收'", in: web,
                                context: "author highlighting is enabled in the Read window")
        _ = try harness.js("""
            window.originalAuthorMark = document.querySelector('main p > mark');
            window.originalAuthorColor = getComputedStyle(originalAuthorMark).backgroundColor;
            true
            """, web)
        let bar = try showNativeFind(in: web, harness: harness)
        try harness.enterQuery("验收")
        let authorMatch = "element === window.originalAuthorMark"
        let plainMatch = "element.matches('main p') && element.textContent === '普通验收'"
        try waitForVisibleMatch(0, of: 2, query: "验收", owner: authorMatch, in: web, bar: bar, harness: harness)
        XCTAssertEqual(try harness.js("""
            \(PreviewFindRanges.all).every(range => {
                const r = range.getBoundingClientRect();
                return r.width > 0 && r.height > 0 && r.top >= 0 && r.bottom <= innerHeight;
            })
            """, web) as? Bool, true, "the two results are visible together")
        try capturePreview("find-author-first", in: web)
        try navigate(bar: bar, harness: harness)
        try waitForVisibleMatch(1, of: 2, query: "验收", owner: plainMatch, in: web, bar: bar, harness: harness)
        try capturePreview("find-author-second", in: web)
        try navigate(bar: bar, harness: harness)
        try waitForVisibleMatch(0, of: 2, query: "验收", owner: authorMatch, in: web, bar: bar, harness: harness)
        try navigate(previous: true, bar: bar, harness: harness)
        try waitForVisibleMatch(1, of: 2, query: "验收", owner: plainMatch, in: web, bar: bar, harness: harness)
        try navigate(previous: true, bar: bar, harness: harness)
        try waitForVisibleMatch(0, of: 2, query: "验收", owner: authorMatch, in: web, bar: bar, harness: harness)

        try harness.enterQuery("左验收右")
        try harness.waitForPage("""
            \(PreviewFindRanges.currentCount) === 3 &&
            \(PreviewFindRanges.all).map(range => range.toString()).join('') === '左验收右'
            """, in: web, context: "the inline formatting keeps the full sentence intact")
        verifyStatus("1 of 1", bar: bar, harness: harness)
        try harness.enterQuery("左右")
        try harness.waitForPage("\(PreviewFindRanges.count) === 0 && \(PreviewFindRanges.currentCount) === 0", in: web,
                                context: "the marked text separates the surrounding characters")
        verifyStatus("No results", bar: bar, harness: harness)
        try harness.press(.closeFind)
        try harness.waitForPage("""
            document.querySelectorAll('main mark').length === 1 &&
            document.querySelector('main mark') === originalAuthorMark &&
            getComputedStyle(originalAuthorMark).backgroundColor === originalAuthorColor &&
            originalAuthorMark.getBoundingClientRect().width > 0 &&
            originalAuthorMark.parentElement.textContent === '左验收右' &&
            \(PreviewFindRanges.count) === 0 && \(PreviewFindRanges.currentCount) === 0
            """, in: web, context: "the original author highlight is visible after closing Find")
        try capturePreview("find-author-after-close", in: web)
    }

    @MainActor
    func testNativeFindRevealsCollapsedDisclosuresInDocumentOrder() throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        harness.settings.newDocumentMode = .read
        harness.settings.language = .english
        harness.window.appearance = NSAppearance(named: .aqua)
        let gap = String(repeating: "An intervening paragraph.\n\n", count: 18)
        harness.store.text = "<details><summary>Summary</summary>collapsedkeyword</details>\n\n" + gap
            + "<details><summary>Nested keyword heading</summary><div><details><summary>Inner heading</summary>"
            + "<div>Inner <mark>keyword</mark> body.</div></details></div></details>\n\n" + gap + "Ordinary keyword."
        harness.host(ContentView(document: harness.store, settings: harness.settings, onOpen: {}), width: 720)
        let web = try XCTUnwrap(harness.descendants(WKWebView.self).first)
        let state = "Array.from(document.querySelectorAll('details')).map(d => d.open ? '1' : '0').join('')"
        try harness.waitForPage("\(state) === '000'", in: web, context: "all three disclosures start closed")
        let bar = try showNativeFind(in: web, harness: harness)
        try harness.enterQuery("Summarycollapsedkeyword")
        verifyStatus("No results", bar: bar, harness: harness)
        XCTAssertEqual(try harness.js(state, web) as? String, "000")

        let first = "element === document.querySelector('details')"
        let summary = "element.matches('summary') && element.textContent === 'Nested keyword heading'"
        let nested = "element.matches('details details mark')"
        let prose = "element.matches('main p') && element.textContent === 'Ordinary keyword.'"
        try harness.enterQuery("collapsedkeyword")
        try waitForVisibleMatch(0, of: 1, query: "collapsedkeyword", owner: first,
                                in: web, bar: bar, harness: harness)
        XCTAssertEqual(try harness.js(state, web) as? String, "100")
        try capturePreview("find-disclosure-open", in: web)

        try harness.enterQuery("keyword")
        try waitForVisibleMatch(0, of: 4, query: "keyword", owner: first, in: web, bar: bar, harness: harness)
        try navigate(bar: bar, harness: harness)
        try waitForVisibleMatch(1, of: 4, query: "keyword", owner: summary, in: web, bar: bar, harness: harness)
        XCTAssertEqual(try harness.js(state, web) as? String, "100", "a summary is already visible")
        try capturePreview("find-disclosure-summary", in: web)
        try navigate(bar: bar, harness: harness)
        try waitForVisibleMatch(2, of: 4, query: "keyword", owner: nested, in: web, bar: bar, harness: harness)
        XCTAssertEqual(try harness.js(state, web) as? String, "111", "the current body hit opens its two ancestors")
        try capturePreview("find-disclosure-nested", in: web)
        try navigate(bar: bar, harness: harness)
        try waitForVisibleMatch(3, of: 4, query: "keyword", owner: prose, in: web, bar: bar, harness: harness)
        try navigate(bar: bar, harness: harness)
        try waitForVisibleMatch(0, of: 4, query: "keyword", owner: first, in: web, bar: bar, harness: harness)
        for (index, owner) in [prose, nested, summary, first].enumerated() {
            try navigate(previous: true, bar: bar, harness: harness)
            try waitForVisibleMatch(3 - index, of: 4, query: "keyword", owner: owner, in: web, bar: bar, harness: harness)
        }
        try harness.enterQuery("collapsedkeyword")
        try waitForVisibleMatch(0, of: 1, query: "collapsedkeyword", owner: first,
                                in: web, bar: bar, harness: harness)
    }

    @MainActor
    private func showNativeFind(in web: WKWebView, harness: InteractionTestWindow) throws
        -> NativeFindBarController<PreviewFindBar> {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: harness.window.windowNumber, context: nil,
            characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        XCTAssertTrue(web.performKeyEquivalent(with: event))
        harness.spin(until: { harness.queryField != nil })
        var responder: NSResponder? = try XCTUnwrap(harness.queryField)
        while let current = responder, !(current is NativeFindPaneOwner) { responder = current.nextResponder }
        return try XCTUnwrap(responder as? NativeFindBarController<PreviewFindBar>)
    }

    @MainActor
    private func verifyStatus(_ status: String, bar: NativeFindBarController<PreviewFindBar>,
                              harness: InteractionTestWindow, file: StaticString = #filePath, line: UInt = #line) {
        harness.spin(until: { bar.rootView.statusText == status })
        XCTAssertEqual(bar.rootView.statusText, status, file: file, line: line)
    }

    @MainActor
    private func navigate(previous: Bool = false, bar: NativeFindBarController<PreviewFindBar>,
                          harness: InteractionTestWindow) throws {
        let field = try XCTUnwrap(harness.queryField)
        let y = field.convert(field.bounds, to: nil).midY
        let row = harness.descendants(NSButton.self, in: bar.view).filter {
            let bounds = $0.convert($0.bounds, to: nil)
            return bounds.minY <= y && bounds.maxY >= y
        }.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        XCTAssertEqual(row.count, 3, "Find shows Previous, Next, and Close")
        let button = try XCTUnwrap(row.dropFirst(previous ? 0 : 1).first)
        XCTAssertTrue(button.isEnabled)
        button.performClick(nil)
    }

    @MainActor
    private func waitForVisibleMatch(_ index: Int, of total: Int, query: String, owner: String,
                                     in web: WKWebView, bar: NativeFindBarController<PreviewFindBar>,
                                     harness: InteractionTestWindow, file: StaticString = #filePath,
                                     line: UInt = #line) throws {
        try harness.waitForPage("""
            (() => {
                if (\(PreviewFindRanges.count) !== \(total) || \(PreviewFindRanges.currentIndex) !== \(index)) return false;
                if (\(PreviewFindRanges.all).some(range => range.toString() !== '\(query)')) return false;
                const range = CSS.highlights.get('md2-find-current')?.values().next().value;
                if (!range) return false;
                const element = range.startContainer.parentElement;
                if (!(\(owner))) return false;
                const rect = range.getBoundingClientRect();
                if (!rect.width || !rect.height || rect.top < 0 || rect.bottom > innerHeight ||
                    rect.left < 0 || rect.right > innerWidth) return false;
                const x = (rect.left + rect.right) / 2, y = (rect.top + rect.bottom) / 2;
                const outline = document.querySelector('.md2-find-outline > i')?.getBoundingClientRect();
                return element.contains(document.elementFromPoint(x, y)) && outline &&
                    outline.left <= x && outline.right >= x && outline.top <= y && outline.bottom >= y;
            })()
            """, in: web, context: "visible '\(query)' result \(index + 1) of \(total) (\(owner))", file: file, line: line)
        verifyStatus("\(index + 1) of \(total)", bar: bar, harness: harness, file: file, line: line)
        let top = try XCTUnwrap(try harness.js("""
            CSS.highlights.get('md2-find-current').values().next().value.getBoundingClientRect().top
            """, web) as? Double, file: file, line: line)
        print("Preview Find '\(query)' \(index + 1) of \(total), visible at y=\(top) CSS px")
    }

    @MainActor
    private func capturePreview(_ name: String, in web: WKWebView) throws {
        guard let directory = ProcessInfo.processInfo.environment["MD2_INTERACTION_EVIDENCE_DIR"] else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let done = expectation(description: "capture \(name)")
        var screenshot: NSImage?
        web.takeSnapshot(with: configuration) { image, _ in screenshot = image; done.fulfill() }
        wait(for: [done], timeout: 8)
        let frame = try XCTUnwrap(screenshot?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
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
