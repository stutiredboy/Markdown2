import AppKit
import MD2Core
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

/// Diagram source is author data, the same as raw HTML, so nothing in it may run.
/// Mermaid 10.9.1 at `securityLevel: "loose"` broke this without a click: a
/// `$$…$$` sequence label and a state `classDef` both ran an event handler as soon
/// as the page was displayed, in the preview, in the page PDF export renders, and
/// in an exported HTML file. Each payload here runs on all three, on a page with
/// its Content-Security-Policy removed: this suite is about Mermaid's own boundary,
/// and `ContentSecurityPolicyGUITests` covers the layer under it.
///
/// Requires a GUI session (WebKit), so opt-in to stay CI-safe:
/// `MD2_RUN_GUI_TESTS=1 swift test --filter MermaidLabelSecurityGUITests`.
final class MermaidLabelSecurityGUITests: XCTestCase, RenderedPageTesting {
    private static let handler = "<img src=x onerror=window.pwned=1>"

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed test."
        )
    }

    /// The other tests here assert that nothing ran. This shows each surface
    /// would have noticed if it had.
    @MainActor func testEachSurfaceDetectsARunningHandler() throws {
        for surface in RenderedPageSurface.allCases {
            try withPage("```mermaid\ngraph TD; A-->B;\n```", on: surface) { webView in
                _ = try evaluate("document.body.insertAdjacentHTML('beforeend', '\(Self.handler)'); true", in: webView)
                XCTAssertTrue(spin(5) { (try? self.evaluate("window.pwned === 1", in: webView)) as? Bool == true },
                              "\(surface): an event handler in the page went unnoticed")
            }
        }
    }

    @MainActor func testLabelMarkupCannotRunScript() throws {
        let x = Self.handler
        let payloads = [
            "flow node": "graph TD\n A[\"\(x)\"]",
            "flow edge": "graph TD\n A-->|\"\(x)\"|B",
            "flow subgraph": "graph TD\n subgraph s [\"\(x)\"]\n A\n end",
            "flow math": "graph TD\n A[\"$$x$$ \(x)\"]",
            "sequence math message": "sequenceDiagram\n A->>B: $$x$$ \(x)",
            "sequence math actor": "sequenceDiagram\n participant A as $$x$$ \(x)\n A->>A: hi",
            "sequence math note": "sequenceDiagram\n A->>B: hi\n Note over A: $$x$$ \(x)",
            "sequence actor links": "sequenceDiagram\n participant A\n links A: {\"Docs\": \"https://example.com\"}\n A->>A: hi",
            "state classDef": "stateDiagram-v2\n classDef x fill:red</style></svg>\(x)\n [*] --> A:::x",
            "class note": "classDiagram\n class A\n note \"\(x)\"",
            "gantt task": "gantt\n section S\n \(x) :a1, 2024-01-01, 1d"
        ]
        for (name, source) in payloads.sorted(by: { $0.key < $1.key }) {
            for surface in RenderedPageSurface.allCases {
                try withPage("```mermaid\n\(source)\n```", on: surface) { webView in
                    try assertNothingRan(in: webView, "\(name) on \(surface)")
                }
            }
        }
    }

    @MainActor func testClickDirectivesCannotRunScript() throws {
        let payloads = [
            "flow href": "graph TD\n A\n click A href \"javascript:window.pwned=1\"",
            "flow bare": "graph TD\n A\n click A \"javascript:window.pwned=1\"",
            "flow callback": "graph TD\n A\n click A call eval(\"window.pwned=1\")",
            "class click": "classDiagram\n class A\n click A href \"javascript:window.pwned=1\"",
            "class link": "classDiagram\n class A\n link A \"javascript:window.pwned=1\"",
            "gantt callback": "gantt\n section S\n T :a1, 2024-01-01, 1d\n click a1 call eval(\"window.pwned=1\")",
            "directive lowers level": "%%{init: {\"securityLevel\": \"loose\"}}%%\ngraph TD\n A\n click A href \"javascript:window.pwned=1\"",
            "directive clears secure keys": "%%{init: {\"secure\": [], \"securityLevel\": \"loose\"}}%%\ngraph TD\n A\n click A href \"javascript:window.pwned=1\"",
            "front matter lowers level": "---\nconfig:\n  securityLevel: loose\n---\ngraph TD\n A\n click A href \"javascript:window.pwned=1\""
        ]
        for (name, source) in payloads.sorted(by: { $0.key < $1.key }) {
            for surface in RenderedPageSurface.allCases {
                try withPage("```mermaid\n\(source)\n```", on: surface) { webView in
                    let scriptLinks = try evaluate(
                        "[...document.querySelectorAll('.diagram-mermaid a')].filter(a => /^\\s*javascript:/i.test(a.getAttribute('href') || a.getAttribute('xlink:href') || '')).length",
                        in: webView
                    ) as? Int
                    XCTAssertEqual(scriptLinks, 0, "\(name) on \(surface): a javascript: link reached the page")
                    _ = try evaluate(
                        "document.querySelectorAll('.diagram-mermaid a, .diagram-mermaid .node, .diagram-mermaid .classGroup, .diagram-mermaid .task').forEach(e => e.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, view: window}))); true",
                        in: webView
                    )
                    try assertNothingRan(in: webView, "\(name) on \(surface)")
                }
            }
        }
    }

    /// What `strict` must not cost: every case here rendered at `loose`.
    @MainActor func testLegitimateDiagramsStillRender() throws {
        try withPage("```mermaid\ngraph TD\n A[\"one<br/>two\"]\n```", on: .offscreen) { webView in
            try assertRendered(webView)
            XCTAssertEqual(try evaluate("document.querySelectorAll('.diagram-mermaid foreignObject br').length", in: webView) as? Int, 1)
        }
        let formatted = "graph TD\n A[\"<b>bold</b> <code>code</code> <span style='color:red'>red</span>\"]"
        try withPage("```mermaid\n\(formatted)\n```", on: .offscreen) { webView in
            try assertRendered(webView)
            XCTAssertEqual(try evaluate("document.querySelectorAll('.diagram-mermaid b, .diagram-mermaid code').length", in: webView) as? Int, 2)
            XCTAssertEqual(try evaluate("document.querySelector('.diagram-mermaid span[style*=\"color\"]') !== null", in: webView) as? Bool, true)
        }
        let math = "sequenceDiagram\n participant A as $$x^2$$\n A->>B: $$\\frac{a}{b}$$\n Note over A: $$\\sqrt{2}$$"
        try withPage("```mermaid\n\(math)\n```", on: .offscreen) { webView in
            try assertRendered(webView)
            XCTAssertGreaterThanOrEqual(try evaluate("document.querySelectorAll('.diagram-mermaid math').length", in: webView) as? Int ?? 0, 3)
        }
        try withPage("```mermaid\ngraph TD\n A\n click A href \"https://example.com\"\n```", on: .offscreen) { webView in
            try assertRendered(webView)
            XCTAssertEqual(
                try evaluate("(a => a && (a.getAttribute('href') || a.getAttribute('xlink:href')))(document.querySelector('.diagram-mermaid a'))", in: webView) as? String,
                "https://example.com"
            )
        }
    }

    /// Mermaid retains an image label; the shared resource policy is responsible
    /// for refusing its request. Request counting is in RemoteResourcePolicyGUITests.
    @MainActor func testImageInLabelRemainsSubjectToTheResourcePolicy() throws {
        let source = "graph TD\n A[\"<img src='https://example.invalid/label.png'>\"]"
        try withPage("```mermaid\n\(source)\n```", on: .offscreen) { webView in
            try assertRendered(webView)
            XCTAssertEqual(
                try evaluate("document.querySelector('.diagram-mermaid img').getAttribute('src')", in: webView) as? String,
                "https://example.invalid/label.png"
            )
        }
    }

    // MARK: - Assertions

    @MainActor private func assertRendered(_ webView: WKWebView, _ context: String = "") throws {
        XCTAssertEqual(try evaluate("document.querySelectorAll('.diagram-mermaid svg').length > 0", in: webView) as? Bool, true,
                       "\(context): the diagram did not render, so the page proves nothing")
        XCTAssertEqual(try evaluate("document.querySelectorAll('.diagram-error').length", in: webView) as? Int, 0,
                       "\(context): the diagram fell back to its source, so the page proves nothing")
    }

    @MainActor private func assertNothingRan(in webView: WKWebView, _ context: String) throws {
        try assertRendered(webView, context)
        // A broken image reports its error after the diagram settles.
        XCTAssertFalse(spin(0.5) { (try? self.evaluate("window.pwned === 1", in: webView)) as? Bool == true },
                       "\(context): diagram source ran script")
        let handlers = try evaluate(
            "[...document.querySelectorAll('*')].flatMap(e => [...e.attributes].filter(a => a.name.startsWith('on')).map(a => e.tagName + ' ' + a.name)).join(',')",
            in: webView
        ) as? String
        XCTAssertEqual(handlers, "", "\(context): an event handler reached the page")
    }

    /// The page without its policy: what stands between this source and script
    /// here is the engine alone, and a policy would hide it if that gave way.
    @MainActor private func withPage(
        _ markdown: String, on surface: RenderedPageSurface, _ body: (WKWebView) throws -> Void
    ) throws {
        try withPage(markdown, on: surface, edit: RenderedPageEdit.removingPolicy, body)
    }
}
