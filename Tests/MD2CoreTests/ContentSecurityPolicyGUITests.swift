import AppKit
import MD2Core
import Network
import WebKit
import XCTest
@testable import MD2App

/// Every rendered page carries a Content-Security-Policy, so document content
/// cannot run script on any engine, even once its markup is in the page. A `flow`
/// block broke this before the policy: its `javascript:` link ran on click, in the
/// preview, in the page PDF export renders, and in an exported HTML file, and no
/// engine setting reaches it.
///
/// The failures here are silent. A policy that names a script wrongly leaves a
/// page without math or diagrams, and one that is too loose changes nothing you
/// can see. So these tests run the same pages with and without the policy, to show
/// each surface would notice, and they read what the policy refused.
///
/// Requires a GUI session (WebKit), so opt-in to stay CI-safe:
/// `MD2_RUN_GUI_TESTS=1 swift test --filter ContentSecurityPolicyGUITests`.
final class ContentSecurityPolicyGUITests: XCTestCase, RenderedPageTesting {
    private static let scriptLink = """
    ```flow
    st=>start: Start here:>javascript:window.pwned=1
    e=>end: End
    st->e
    ```
    """

    private static let scriptLinkInNewWindow = """
    ```flow
    st=>start: Start here:>javascript:window.pwned=1[blank]
    e=>end: End
    st->e
    ```
    """

    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed test."
        )
    }

    // MARK: - Script links

    /// The test below asserts that nothing ran. This shows each surface would
    /// have noticed if it had.
    @MainActor func testEachSurfaceRunsAScriptLinkWithoutThePolicy() throws {
        for surface in RenderedPageSurface.allCases {
            try withPage(Self.scriptLink, on: surface, edit: RenderedPageEdit.removingPolicy) { webView in
                try click(linkIn: webView)
                XCTAssertTrue(spin(5) { self.hasRun(in: webView) }, "\(surface): a real click on the link ran nothing")
            }
            try withPage(Self.scriptLink, on: surface, edit: RenderedPageEdit.removingPolicy) { webView in
                try dispatchClick(onLinkIn: webView)
                XCTAssertTrue(spin(5) { self.hasRun(in: webView) }, "\(surface): a scripted click on the link ran nothing")
            }
        }
    }

    @MainActor func testFlowScriptLinkDoesNotRunWhenClicked() throws {
        for (name, source) in [("same window", Self.scriptLink), ("new window", Self.scriptLinkInNewWindow)] {
            for surface in RenderedPageSurface.allCases {
                try withPage(source, on: surface) { webView in
                    // The link is still in the page: this is the policy at work,
                    // not an engine that stopped drawing it.
                    XCTAssertEqual(
                        try evaluate("document.querySelector('.diagram-flow a').getAttributeNS('http://www.w3.org/1999/xlink', 'href')", in: webView) as? String,
                        "javascript:window.pwned=1"
                    )
                    try click(linkIn: webView)
                    try dispatchClick(onLinkIn: webView)
                    XCTAssertFalse(spin(0.5) { self.hasRun(in: webView) }, "\(name) on \(surface): the link ran script")
                }
            }
        }
    }

    /// A window a link opens is a page of its own: the opener's policy has to
    /// reach it. Without the policy the script runs in that window.
    @MainActor func testScriptLinkOpensNoWindowThatRunsIt() throws {
        for (edit, expectsScript) in [(RenderedPageEdit.removingPolicy, true), ({ $0 }, false)] as [((String) -> String, Bool)] {
            try withPage(Self.scriptLinkInNewWindow, on: .exportedFile, edit: edit) { webView in
                let opener = ChildWindowOpener()
                webView.uiDelegate = opener
                try dispatchClick(onLinkIn: webView)
                let ran = spin(expectsScript ? 5 : 0.5) { opener.children.contains { self.hasRun(in: $0) } }
                XCTAssertEqual(ran, expectsScript)
            }
        }
    }

    // MARK: - Markup past the sanitizers

    /// Each runs from the page, not as a call from native, and reports by index.
    /// `@` is its index. A page in another origin can only post a message.
    private static let injections: [(name: String, source: String)] = [
        ("event handler", #"document.body.insertAdjacentHTML('beforeend', '<img src=x onerror=hit(@)>')"#),
        ("script element", #"var s = document.createElement('script'); s.textContent = 'hit(@)'; document.body.appendChild(s)"#),
        ("data script", #"var s = document.createElement('script'); s.src = 'data:text/javascript,hit(@)'; document.body.appendChild(s)"#),
        ("iframe srcdoc", #"document.body.insertAdjacentHTML('beforeend', '<iframe srcdoc="<script>parent.hit(@)<\/script>"></iframe>')"#),
        ("iframe data", #"document.body.insertAdjacentHTML('beforeend', '<iframe src="data:text/html,<script>parent.postMessage(@,\'*\')<\/script>"></iframe>')"#),
        ("iframe script URL", #"document.body.insertAdjacentHTML('beforeend', '<iframe src="javascript:parent.hit(@)"></iframe>')"#),
        ("object", #"document.body.insertAdjacentHTML('beforeend', '<object data="data:text/html,<script>parent.postMessage(@,\'*\')<\/script>"></object>')"#),
        ("embed", #"document.body.insertAdjacentHTML('beforeend', '<embed src="data:text/html,<script>parent.postMessage(@,\'*\')<\/script>">')"#),
        ("anchor script URL", #"var a = document.createElement('a'); a.href = 'javascript:hit(@)'; document.body.appendChild(a); a.click()"#),
        ("location script URL", #"location.href = 'javascript:hit(@)'"#),
        ("form script URL", #"document.body.insertAdjacentHTML('beforeend', '<form id="f" action="javascript:hit(@)"></form>'); document.getElementById('f').submit()"#),
        ("string timer", #"setTimeout('hit(@)', 0)"#)
    ]

    /// The names of the `injections` that ran on `webView`, in table order.
    @MainActor private func runInjections(in webView: WKWebView) throws -> [String] {
        let plants = Self.injections.enumerated().map { index, injection in
            "function () { \(injection.source.replacingOccurrences(of: "@", with: String(index))) }"
        }
        _ = try evaluate("""
            window.ran = [];
            window.hit = function (index) { window.ran.push(index); };
            window.addEventListener('message', function (event) { window.hit(event.data); });
            [\(plants.joined(separator: ",\n"))].forEach(function (plant, index) { setTimeout(plant, index * 60); });
            true;
            """, in: webView)
        let settled = Double(Self.injections.count) * 0.06 + 1
        _ = spin(settled) {
            (try? self.evaluate("window.ran.length", in: webView)) as? Int == Self.injections.count
        }
        let ran = try evaluate("window.ran", in: webView) as? [Int] ?? []
        return Set(ran).sorted().map { Self.injections[$0].name }
    }

    @MainActor func testEachSurfaceRunsInjectedMarkupWithoutThePolicy() throws {
        for surface in RenderedPageSurface.allCases {
            try withPage("Text.", on: surface, edit: RenderedPageEdit.removingPolicy) { webView in
                XCTAssertEqual(try runInjections(in: webView), Self.injections.map(\.name),
                               "\(surface): an injection that cannot run proves nothing below")
            }
        }
    }

    /// Stands for a future sanitizer bug: this markup is already in the page, past
    /// `HTMLSafety` and every engine, and the policy is all that is left.
    @MainActor func testMarkupPastTheSanitizersCannotRunScript() throws {
        for surface in RenderedPageSurface.allCases {
            try withPage("Text.", on: surface) { webView in
                XCTAssertEqual(try runInjections(in: webView), [], "\(surface): injected markup ran script")
            }
        }
    }

    @MainActor func testPageCannotMoveItsBaseURL() throws {
        for surface in RenderedPageSurface.allCases {
            try withPage("Text.", on: surface) { webView in
                let before = try evaluate("document.baseURI", in: webView) as? String
                XCTAssertEqual(try evaluate("""
                    document.head.insertAdjacentHTML('afterbegin', '<base href="https://example.invalid/">');
                    document.baseURI
                    """, in: webView) as? String, before, "\(surface)")
            }
        }
    }

    /// What the policy does not name stays closed. Script that got in could not
    /// `fetch`, and nothing Markdown produces needs media, so a label's cannot load.
    @MainActor func testResourcesThePolicyDoesNotNameAreRefused() throws {
        let markdown = "```mermaid\ngraph TD\n A[\"<video src='https://example.invalid/a_video.mp4'></video>\"]\n```"
        for surface in RenderedPageSurface.allCases {
            try withPage(markdown, on: surface, edit: RenderedPageEdit.recordingViolations) { webView in
                _ = try evaluate("fetch('https://example.invalid/data').catch(function () {}); true", in: webView)
                for directive in ["media-src", "connect-src"] {
                    XCTAssertTrue(spin(5) {
                        (try? self.evaluate("window.__md2Violations.some(v => v.startsWith('\(directive) '))", in: webView)) as? Bool == true
                    }, "\(surface): nothing was refused under \(directive)")
                }
            }
        }
    }

    // MARK: - What must keep working

    /// Every engine, and in Mermaid every diagram type. Each would throw or come
    /// back blank here if it needed `eval`, and a refusal it caught would still
    /// show up as a violation.
    private static let everyEngine = #"""
    # Engines

    Inline $x^2$ and chemistry $\ce{H2O}$.

    $$
    \begin{aligned} a &= b \\ c &= d \end{aligned}
    $$

    ```flow
    st=>start: Start:>https://example.com
    op=>operation: Work
    c=>condition: OK?
    e=>end: End
    st->op->c
    c(yes)->e
    c(no)->op
    ```

    ```sequence
    Title: T
    A->B: Hello
    Note right of B: Thinking
    B-->A: Hi
    ```

    ```mermaid
    graph TD
     A[Start] --> B{Check}
     B -->|"$$x^2$$"| C["<b>bold</b>"]
     click A href "https://example.com"
    ```

    ```mermaid
    sequenceDiagram
     A->>B: $$x^2$$
     Note over A: note
    ```

    ```mermaid
    classDiagram
     class A { +int x }
     A <|-- B
    ```

    ```mermaid
    stateDiagram-v2
     [*] --> S
     S --> [*]
    ```

    ```mermaid
    erDiagram
     A ||--o{ B : has
    ```

    ```mermaid
    gantt
     dateFormat YYYY-MM-DD
     section S
     T :a1, 2024-01-01, 1d
    ```

    ```mermaid
    pie title P
     "a" : 1
     "b" : 2
    ```

    ```mermaid
    journey
     title J
     section S
      T: 5: Me
    ```

    ```mermaid
    gitGraph
     commit id: "one"
     branch dev
     commit id: "two"
    ```

    ```mermaid
    mindmap
     root
      a
      b
    ```

    ```mermaid
    timeline
     title T
     2024 : a
    ```

    ```mermaid
    quadrantChart
     title Q
     x-axis L --> R
     y-axis D --> U
     P: [0.3, 0.6]
    ```

    ```mermaid
    sankey-beta
    a,b,1
    b,c,1
    ```

    ```mermaid
    xychart-beta
     x-axis [a, b]
     y-axis "n" 0 --> 10
     bar [1, 2]
    ```

    ```mermaid
    requirementDiagram
     requirement r {
     id: 1
     text: t
     risk: high
     verifymethod: test
     }
    ```

    ```mermaid
    C4Context
     title C
     Person(a, "A")
    ```

    ```mermaid
    block-beta
     a b
    ```
    """#

    @MainActor func testEveryEngineRunsWithoutEval() throws {
        for surface in RenderedPageSurface.allCases {
            try withPage(Self.everyEngine, on: surface, edit: RenderedPageEdit.recordingViolations) { webView in
                XCTAssertEqual(try evaluate("document.querySelectorAll('.diagram').length", in: webView) as? Int, 19, "\(surface)")
                XCTAssertEqual(try evaluate("document.querySelectorAll('.diagram svg').length", in: webView) as? Int, 19, "\(surface)")
                XCTAssertEqual(try evaluate("document.querySelectorAll('.diagram-error').length", in: webView) as? Int, 0, "\(surface)")
                XCTAssertEqual(try evaluate("document.querySelectorAll('.katex').length", in: webView) as? Int, 5, "\(surface)")
                XCTAssertEqual(try evaluate("document.querySelectorAll('.katex-error, .math-error').length", in: webView) as? Int, 0, "\(surface)")
                try assertNoViolations(in: webView, "\(surface)")
                // Only meaningful while `eval` is really off in this page.
                XCTAssertEqual(try evaluate("(function () { try { eval('1'); return 'ran'; } catch (e) { return e.name; } })()", in: webView) as? String,
                               "EvalError", "\(surface)")
                XCTAssertEqual(try evaluate("(function () { try { new Function('return 1')(); return 'ran'; } catch (e) { return e.name; } })()", in: webView) as? String,
                               "EvalError", "\(surface)")
            }
        }
    }

    /// `WKUserScript`s and `evaluateJavaScript` calls are not page script, but what
    /// they do in the page is: a `<style>` one adds answers to the policy.
    @MainActor func testUserScriptsAndNativeCallsWorkInThePreview() throws {
        let document = "---\ntitle: T\n---\n\n# Heading\n\nA needle here.\n\n$x^2$\n"
        try withPage(document, on: .preview, edit: RenderedPageEdit.recordingViolations) { webView in
            let coordinator = try XCTUnwrap(webView.navigationDelegate as? MarkdownPreviewView.Coordinator)
            XCTAssertTrue(spin(5) { coordinator.isLoaded })
            XCTAssertEqual(try evaluate("!!document.getElementById('md2-typography').sheet", in: webView) as? Bool, true,
                           "applyTypography's style has no sheet, so the policy refused it")
            XCTAssertEqual(try evaluate("""
                window.__md2SetFrontMatterVisible(false);
                getComputedStyle(document.querySelector('.front-matter')).display
                """, in: webView) as? String, "none", "the front-matter rule from a user script did not apply")
            XCTAssertEqual(try evaluate("""
                window.__md2SetLineNumbersVisible(true);
                document.querySelectorAll('.md2-line-gutter span').length > 0
                """, in: webView) as? Bool, true)
            XCTAssertNotNil(try evaluate("window.__md2CaptureAnchor()", in: webView) as? [String: Any])
            XCTAssertEqual(try evaluate("window.__md2Find('needle').total", in: webView) as? Int, 1)
            XCTAssertEqual(try evaluate("document.querySelectorAll('mark.md2-find').length", in: webView) as? Int, 1)
            try assertNoViolations(in: webView, "preview")
        }
    }

    @MainActor func testPrintOverridesApplyToThePDFPage() throws {
        try withPage("# Title\n\nText.", on: .offscreen, edit: RenderedPageEdit.recordingViolations) { webView in
            XCTAssertEqual(try evaluate("!!document.getElementById('md2-print-overrides').sheet", in: webView) as? Bool, true,
                           "printStyleScript's style has no sheet, so the policy refused it")
            XCTAssertEqual(try evaluate("getComputedStyle(document.documentElement).fontSize", in: webView) as? String, "12px")
            try assertNoViolations(in: webView, "offscreen")
        }
    }

    /// The native session grant covers image-class resources, including diagrams.
    /// Portable HTML never inherits this permission.
    @MainActor func testRemoteImagesLoadOnAuthorizedNativeSurfaces() throws {
        let server = try ImageServer(image: Self.png)
        defer { server.stop() }
        XCTAssertTrue(spin(5) { server.port != nil }, "the image server did not start")
        let base = "http://127.0.0.1:\(server.port ?? 0)"
        let markdown = "![remote](\(base)/markdown.png)\n\n```mermaid\ngraph TD\n A[\"<img src='\(base)/label.png'>\"]\n```\n"
        for surface in [RenderedPageSurface.preview, .offscreen] {
            try withPage(markdown, on: surface, edit: RenderedPageEdit.recordingViolations,
                         remoteResourcePolicy: .allowRemoteImages) { webView in
                XCTAssertTrue(spin(5) {
                    (try? self.evaluate("[...document.images].filter(i => i.naturalWidth === 1).length", in: webView)) as? Int == 2
                }, "\(surface): a remote image did not load")
                try assertNoViolations(in: webView, "\(surface)")
            }
        }
    }

    @MainActor func testExportedFileKeepsItsImages() throws {
        try withPage("![embedded](dot.png)", on: .exportedFile, edit: RenderedPageEdit.recordingViolations,
                     files: ["dot.png": Self.png], embedsFiles: true) { webView in
            XCTAssertEqual(try evaluate("document.images[0].src.startsWith('data:')", in: webView) as? Bool, true)
            XCTAssertTrue(spin(5) { (try? self.evaluate("document.images[0].naturalWidth", in: webView)) as? Int == 1 },
                          "an embedded image did not load")
            try assertNoViolations(in: webView, "embedded")
        }
        // An unresolved local image must not become an external dependency when
        // the saved file is opened beside an unrelated same-named image.
        try withPage("![beside](dot.png)", on: .exportedFile, edit: RenderedPageEdit.recordingViolations,
                     files: ["dot.png": Self.png]) { webView in
            XCTAssertFalse(spin(0.5) { (try? self.evaluate("[...document.images].some(i => i.naturalWidth > 0)", in: webView)) as? Bool == true },
                           "an unresolved file reference loaded outside the portable artifact")
        }
    }

    /// The policy refuses a missing local image while the page is still parsing,
    /// so a listener that arrives with the document's end never hears of it.
    @MainActor func testMissingImageShowsItsPlaceholderOnTheFirstLoad() throws {
        for source in ["missing.png", "/no/such/folder/missing.png"] {
            try withPage("![x](\(source))", on: .preview) { webView in
                XCTAssertTrue(spin(5) {
                    (try? self.evaluate("document.querySelectorAll('.md2-broken-image').length", in: webView)) as? Int == 1
                }, "\(source): no placeholder")
                XCTAssertEqual(try evaluate("document.querySelector('.md2-broken-image-path').textContent", in: webView) as? String, source)
                XCTAssertEqual(try evaluate("document.images.length", in: webView) as? Int, 0, "\(source): the broken image stayed")
            }
        }
    }

    // MARK: - Helpers

    @MainActor private func hasRun(in webView: WKWebView) -> Bool {
        (try? evaluate("window.pwned === 1", in: webView)) as? Bool == true
    }

    @MainActor private func click(linkIn webView: WKWebView) throws {
        try click("document.querySelector('.diagram-flow a').firstElementChild", in: webView)
    }

    @MainActor private func dispatchClick(onLinkIn webView: WKWebView) throws {
        _ = try evaluate("""
            document.querySelector('.diagram-flow a').firstElementChild
                .dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
            true;
            """, in: webView)
    }

    /// A violation event arrives after the refusal, so this waits a moment.
    @MainActor private func assertNoViolations(in webView: WKWebView, _ context: String) throws {
        _ = spin(0.2) { false }
        XCTAssertEqual(try evaluate("window.__md2Violations", in: webView) as? [String], [],
                       "\(context): the policy refused part of the page")
    }
}

/// Opens each requested window as a real web view, as a browser would.
@MainActor private final class ChildWindowOpener: NSObject, WKUIDelegate {
    private(set) var children: [WKWebView] = []

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let child = WKWebView(frame: .zero, configuration: configuration)
        children.append(child)
        return child
    }
}

/// Answers every request with one image, so a remote load can be proved offline.
private final class ImageServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var boundPort: UInt16?

    var port: UInt16? { lock.withLock { boundPort } }

    init(image: Data) throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let self else { return }
            self.lock.withLock { self.boundPort = self.listener.port?.rawValue }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                var response = Data("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(image.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(image)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global())
    }

    func stop() { listener.cancel() }
}
