import AppKit
import MD2Core
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

final class MermaidActualSizeGUITests: XCTestCase, RenderedPageTesting {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 for the live Mermaid viewport.")
    }

    private static let diagram = """
    ```mermaid
    flowchart LR
      A[Alpha One] --> B[Bravo Two] --> C[Charlie Three] --> D[Delta Four] --> E[Echo Five] --> F[Foxtrot Six] --> G[Golf Seven] --> H[Hotel Eight]
    ```
    """
    private let openButton = "document.querySelector('.md2-diagram-action')"
    private let canvas = "document.querySelector('.md2-diagram-canvas')"

    @MainActor
    func testEightNodesAtActualSizeAndEscapeRestoresReader() throws {
        let h = InteractionTestWindow()
        defer { h.close() }
        let filler = String(repeating: "This paragraph wraps across several lines before the diagram in the narrow reading column.\n\n", count: 40)
        var findDismissals = 0
        let page = MarkdownRenderer().render(filler + Self.diagram + "\n\n" + filler, assetMode: .appScheme)
        let preview = MarkdownPreviewView(html: page.html, bodyHTML: page.body, baseURL: nil,
            jumpHeadingID: .constant(nil), jumpFraction: .constant(nil), jumpAnchor: .constant(nil),
            onEscape: { findDismissals += 1; return true },
            findQuery: .constant(""), findNavigation: .constant(nil), focusToken: nil,
            typography: TypographySettings(fontSize: 32))
        h.host(preview, width: 420, height: 440)
        let web = try XCTUnwrap(h.descendants(WKWebView.self).first)
        try h.waitForPage("innerWidth === 420 && \(openButton)?.hidden === false", in: web,
                          context: "wide diagram in a 420 CSS px preview")
        let coordinator = try XCTUnwrap(web.navigationDelegate as? MarkdownPreviewView.Coordinator)
        coordinator.runFindWhenReady("Alpha One", in: web)
        try h.waitForPage("\(PreviewFindRanges.firstText) === 'Alpha One'", in: web, context: "the first label is highlighted")
        let initial = try XCTUnwrap(try h.js("""
            (() => {
                const svg = document.querySelector('.diagram-mermaid > svg');
                document.querySelector('.md2-diagram-action').scrollIntoView({block:'center'});
                window.originalDiagram = svg;
                return [scrollY, svg.getBoundingClientRect().width, svg.viewBox.baseVal.width];
            })()
            """, web) as? [Double])
        XCTAssertGreaterThan(initial[0], 500)
        XCTAssertLessThan(initial[1], 420)
        XCTAssertGreaterThan(initial[2], 900)
        try click(openButton, in: web)
        try h.waitForPage("\(canvas)?.contains(window.originalDiagram) === true && document.activeElement === \(canvas)",
                          in: web, context: "the original SVG opened in the keyboard scroll area")

        let width = try XCTUnwrap(try h.js("window.originalDiagram.getBoundingClientRect().width", web) as? Double)
        XCTAssertEqual(width, initial[2], accuracy: 1)
        web.keyDown(with: try key("\u{f703}", code: 124, in: web))
        try h.waitForPage("\(canvas).scrollLeft > 0", in: web, context: "right arrow pans the diagram")
        let visible = try XCTUnwrap(try h.js("""
            (() => {
                const canvas = document.querySelector('.md2-diagram-canvas');
                const left = canvas.getBoundingClientRect().left;
                return [...window.originalDiagram.querySelectorAll('g.node')].map(node => {
                    let r = node.getBoundingClientRect();
                    canvas.scrollLeft += r.left - left - (canvas.clientWidth - r.width) / 2;
                    r = node.getBoundingClientRect();
                    const hit = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
                    const label = node.querySelector('.nodeLabel');
                    if (!node.contains(hit) || r.left < left - 1 || r.right > left + canvas.clientWidth + 1 ||
                        parseFloat(getComputedStyle(label).fontSize) * node.getScreenCTM().a < 15) return '';
                    return label.textContent.trim();
                });
            })()
            """, web) as? [String])
        XCTAssertEqual(visible, ["Alpha One", "Bravo Two", "Charlie Three", "Delta Four",
                                 "Echo Five", "Foxtrot Six", "Golf Seven", "Hotel Eight"])
        XCTAssertTrue(web.performKeyEquivalent(with: try key("\u{1b}", code: 53, in: web)))
        try h.waitForPage("""
            !document.querySelector('.md2-diagram-viewer') &&
            document.querySelector('.diagram-mermaid > svg') === window.originalDiagram &&
            document.activeElement === \(openButton)
            """, in: web, context: "Escape restored diagram and keyboard focus")
        XCTAssertEqual(findDismissals, 0)
        XCTAssertEqual(try h.js(PreviewFindRanges.firstText, web) as? String, "Alpha One",
                       "moving the SVG back must preserve the active Find range on its label")
        XCTAssertEqual(try XCTUnwrap(try h.js("window.scrollY", web) as? Double), initial[0], accuracy: 0.5)
        XCTAssertTrue(web.performKeyEquivalent(with: try key("\u{1b}", code: 53, in: web)))
        XCTAssertEqual(findDismissals, 1, "the next Escape is available to the preview Find bar")
        print("Mermaid at 420 CSS px with 32 px body: inline \(initial[1]), actual \(width), restored scrollY \(initial[0]), all eight nodes visible at natural scale")

        let blockTop = "document.querySelector('.diagram-mermaid').getBoundingClientRect().top"
        let viewportTop = try XCTUnwrap(try h.js(blockTop, web) as? Double)
        let documentTop = initial[0] + viewportTop
        try click(openButton, in: web)
        try h.waitForPage("\(canvas)?.contains(window.originalDiagram) === true", in: web, context: "diagram reopened")
        h.window.setContentSize(NSSize(width: 680, height: 440))
        try h.waitForPage("""
            innerWidth === 680 && (scrollY + \(blockTop)) < \(documentTop) - innerHeight
            """, in: web, context: "widening the viewer reflows the preceding prose by more than a viewport")
        XCTAssertTrue(web.performKeyEquivalent(with: try key("\u{1b}", code: 53, in: web)))
        try h.waitForPage("!document.querySelector('.md2-diagram-viewer') && document.activeElement === \(openButton)",
                          in: web, context: "Escape returned to the widened reading column")
        XCTAssertEqual(try XCTUnwrap(try h.js(blockTop, web) as? Double), viewportTop, accuracy: 1)
        XCTAssertLessThan(try XCTUnwrap(try h.js("scrollY", web) as? Double), initial[0] - 440)
    }

    @MainActor
    func testResizeAndLiveReplacementOfAnOpenDiagram() throws {
        let h = InteractionTestWindow()
        defer { h.close() }
        let link = URL(string: "https://example.invalid/diagram-node")!
        var opened: [URL] = []
        let source = """
        ```mermaid
        flowchart LR
          A[Alpha One] --> B[Bravo Two] --> C[Charlie Three] --> D[Delta Four]
          click A href "\(link.absoluteString)"
        ```
        """
        func preview(_ text: String, language: AppLanguage = .english) -> MarkdownPreviewView {
            let page = MarkdownRenderer().render(text, assetMode: .appScheme)
            return MarkdownPreviewView(html: page.html, bodyHTML: page.body, baseURL: nil, liveUpdate: true,
                jumpHeadingID: .constant(nil), jumpFraction: .constant(nil), jumpAnchor: .constant(nil),
                onOpenWithSystem: { opened.append($0) },
                findQuery: .constant(""), findNavigation: .constant(nil), focusToken: nil,
                mermaidViewerLanguage: language)
        }
        h.host(preview(source), width: 720, height: 400)
        let web = try XCTUnwrap(h.descendants(WKWebView.self).first)
        let host = try XCTUnwrap(h.descendants(NSHostingView<MarkdownPreviewView>.self).first)
        try h.waitForPage("\(openButton)?.hidden === true", in: web, context: "natural-size diagram already fits")
        h.window.setContentSize(NSSize(width: 420, height: 400))
        try h.waitForPage("innerWidth === 420 && \(openButton)?.hidden === false", in: web,
                          context: "resizing makes the existing diagram expandable")
        try click(openButton, in: web)
        try h.waitForPage("\(canvas)?.querySelector('svg') != null", in: web, context: "diagram opened")
        try click("document.querySelector('.md2-diagram-canvas svg a').firstElementChild", in: web)
        h.spin(until: { opened == [link] })
        XCTAssertEqual(opened, [link], "panning must leave links in the actual-size diagram operable")
        _ = try h.js("window.previousDiagram = \(canvas).querySelector('svg'); true", web)
        host.rootView = preview(source + "\n\nUnrelated edit.", language: .zhHans)
        try h.waitForPage("document.querySelector('main p')?.textContent === 'Unrelated edit.' && \(canvas)?.contains(window.previousDiagram)",
                          in: web, context: "editing another block preserves the viewer")
        try h.waitForPage("""
            \(openButton).getAttribute('aria-label') === '按原尺寸查看图表' &&
            document.querySelector('.md2-diagram-viewer button').getAttribute('aria-label') === '关闭'
            """, in: web, context: "changing the app language updates the open viewer")
        host.rootView = preview(source.replacingOccurrences(of: "Delta Four", with: "Replacement"))
        try h.waitForPage("""
            !document.querySelector('.md2-diagram-viewer') && !window.previousDiagram.isConnected &&
            document.querySelector('.diagram-mermaid > svg')?.textContent.includes('Replacement') &&
            \(openButton)?.hidden === false
            """, in: web, context: "replacing the open diagram dismisses its obsolete SVG")
        try click(openButton, in: web)
        try h.waitForPage("\(canvas)?.querySelector('svg')?.textContent.includes('Replacement')", in: web,
                          context: "the replacement expands")
        // A renderer may repopulate a retained wrapper in place. Its old SVG
        // must disappear even though the originating block is still connected.
        _ = try h.js("""
            const block = document.querySelector('.diagram-mermaid');
            block.textContent = 'flowchart LR; A[Alpha One] --> B[Bravo Two] --> C[Charlie Three] --> D[In-place replacement]';
            window.__md2RenderDiagrams([block]); true
            """, web)
        try h.waitForPage("""
            !document.querySelector('.md2-diagram-viewer') &&
            document.querySelector('.diagram-mermaid > svg')?.textContent.includes('In-place replacement') &&
            \(openButton)?.hidden === false
            """, in: web, context: "rerendering a retained block retires its old viewer and attaches the new action")
        try click(openButton, in: web)
        try h.waitForPage("\(canvas)?.querySelector('svg')?.textContent.includes('In-place replacement')", in: web,
                          context: "the retained block opens its newly rendered SVG")
        try click("document.querySelector('.md2-diagram-viewer button')", in: web)
        try h.waitForPage("!document.querySelector('.md2-diagram-viewer') && document.querySelector('.diagram-mermaid > svg') != null",
                          in: web, context: "the Close button completes before resizing its own target")
        h.window.setContentSize(NSSize(width: 820, height: 400))
        try h.waitForPage("innerWidth === 820 && !document.querySelector('.md2-diagram-viewer') && \(openButton)?.hidden === true",
                          in: web, context: "widening the preview removes the unnecessary action")
    }

    @MainActor private func key(_ characters: String, code: UInt16, in web: WKWebView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: web.window!.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
}
