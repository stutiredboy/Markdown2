import AppKit
import WebKit
import XCTest
import MD2Core
@testable import MD2App

/// GUI-gated verification that Mermaid renders inside a window-less / off-screen
/// `WKWebView` — the configuration the PDF exporter and printer use — and that the
/// diagram-settled signal the exporter polls actually flips. Before this change,
/// Mermaid stayed blank offscreen (KaTeX math rendered, diagrams did not); these
/// tests guard the fix and the failure-fallback path.
///
/// Requires a GUI session (WebKit), so opt-in to stay CI-safe:
/// `MD2_RUN_GUI_TESTS=1 swift test --filter MermaidOffscreenRenderingTests`.
final class MermaidOffscreenRenderingTests: XCTestCase {
    @MainActor
    func testMermaidRendersOffscreenAndSignalsSettled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed test."
        )

        let html = MarkdownRenderer().render("""
        ```mermaid
        graph TD; A-->B; B-->C;
        ```
        """).html

        let probe = """
        (function () {
          var el = document.querySelector('.diagram-mermaid');
          return {
            settled: window.__md2DiagramsSettled === true,
            svg: !!(el && el.querySelector('svg')),
            error: !!(el && el.classList.contains('diagram-error'))
          };
        })()
        """
        let result = try loadAndProbe(html: html, probe: probe)

        XCTAssertTrue(boolValue(result["settled"]), "the diagram-settled signal never flipped")
        XCTAssertTrue(boolValue(result["svg"]), "Mermaid did not render to an <svg> in the offscreen web view")
        XCTAssertFalse(boolValue(result["error"]), "a valid Mermaid diagram fell back to the error/source path")
    }

    @MainActor
    func testMalformedMermaidStillSettlesWithFallback() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed test."
        )

        // Deliberately invalid Mermaid source: the render must reject, the element
        // must fall back (revealed, not pending), and the settle signal must still
        // flip so the exporter never hangs on a bad diagram.
        let html = MarkdownRenderer().render("""
        ```mermaid
        this is not valid %%% mermaid @@@
        ```
        """).html

        let probe = """
        (function () {
          var el = document.querySelector('.diagram-mermaid');
          return {
            settled: window.__md2DiagramsSettled === true,
            revealed: !!(el && el.classList.contains('diagram-ready')),
            pending: !!(el && el.classList.contains('diagram-pending'))
          };
        })()
        """
        let result = try loadAndProbe(html: html, probe: probe)

        XCTAssertTrue(boolValue(result["settled"]), "settle signal must flip even when a diagram fails to render")
        XCTAssertTrue(boolValue(result["revealed"]), "a failed diagram must be revealed (source fallback)")
        XCTAssertFalse(boolValue(result["pending"]), "a failed diagram must not be left in the pending state")
    }

    @MainActor
    func testNarrowMermaidKeepsNaturalSizeUnderPrintOverride() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed test."
        )

        let html = MarkdownRenderer().render("""
        ```mermaid
        graph TD; A-->B; B-->C;
        ```
        """).html

        let probe = """
        (function () {
          var svg = document.querySelector('.diagram-mermaid svg');
          var r = svg ? svg.getBoundingClientRect() : null;
          return { width: r ? Math.round(r.width) : 0, height: r ? Math.round(r.height) : 0 };
        })()
        """
        let result = try loadAndProbe(
            html: html,
            printOverride: true,
            appearance: NSAppearance(named: .aqua),
            probe: probe
        )

        let width = CGFloat((result["width"] as? NSNumber)?.doubleValue ?? 0)
        let height = CGFloat((result["height"] as? NSNumber)?.doubleValue ?? 0)
        XCTAssertGreaterThan(width, 0, "narrow Mermaid did not render")
        // Natural size is ~41 px wide × ~218 px tall; the regression inflated it
        // to the full printable width (~523 px) and ~2810 px tall. Bound far below
        // the container so the `max-width:100%!important` inflation is caught.
        XCTAssertLessThan(width, 200, "narrow Mermaid was inflated to the printable width")
        XCTAssertLessThan(height, 600, "narrow Mermaid was inflated to multiple pages")
    }

    @MainActor
    func testWideMermaidFitsPrintableColumnUnderPrintOverride() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed test."
        )

        let html = MarkdownRenderer().render("""
        ```mermaid
        flowchart LR
          A[Alpha One] --> B[Bravo Two] --> C[Charlie Three] --> D[Delta Four] --> E[Echo Five] --> F[Foxtrot Six] --> G[Golf Seven] --> H[Hotel Eight]
        ```
        """).html

        let probe = """
        (function () {
          var svg = document.querySelector('.diagram-mermaid svg');
          var div = document.querySelector('.diagram-mermaid');
          var r = svg ? svg.getBoundingClientRect() : null;
          return {
            width: r ? Math.round(r.width) : 0,
            height: r ? Math.round(r.height) : 0,
            container: div ? Math.round(div.getBoundingClientRect().width) : 0
          };
        })()
        """
        let result = try loadAndProbe(
            html: html,
            printOverride: true,
            appearance: NSAppearance(named: .aqua),
            probe: probe
        )

        let width = CGFloat((result["width"] as? NSNumber)?.doubleValue ?? 0)
        let height = CGFloat((result["height"] as? NSNumber)?.doubleValue ?? 0)
        let container = CGFloat((result["container"] as? NSNumber)?.doubleValue ?? 600)
        XCTAssertGreaterThan(width, 0, "wide Mermaid did not render")
        XCTAssertGreaterThan(height, 0, "wide Mermaid has zero height")
        XCTAssertLessThanOrEqual(width, container + 1, "wide Mermaid was not scaled to fit the printable column")
    }

    @MainActor
    func testForcedLightAppearanceUsesDefaultMermaidTheme() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed test."
        )

        let html = MarkdownRenderer().render("""
        ```mermaid
        graph TD; A-->B;
        ```
        """).html

        let probe = """
        (function () {
          var svg = document.querySelector('.diagram-mermaid svg');
          var t = svg ? svg.querySelector('text, .nodeLabel, g text') : null;
          return {
            darkMatches: window.matchMedia('(prefers-color-scheme: dark)').matches,
            fill: t ? getComputedStyle(t).fill : null
          };
        })()
        """
        let result = try loadAndProbe(
            html: html,
            appearance: NSAppearance(named: .aqua),
            probe: probe
        )

        XCTAssertFalse(boolValue(result["darkMatches"]), "forced light appearance must resolve prefers-color-scheme: light")
        // Dark theme labels are #ccc; the light `default` theme is #333.
        XCTAssertEqual(result["fill"] as? String ?? "", "rgb(51, 51, 51)",
            "Mermaid must use its light 'default' theme under a forced light appearance")
    }

    @MainActor
    func testPDFExporterForcesLightAppearanceOnHostWindow() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed test."
        )
        _ = NSApplication.shared

        // Constructing PDFExporter exercises the real production init — including
        // the `hostWindow.appearance = NSAppearance(named: .aqua)` line. This guards
        // against a maintainer deleting that load-bearing line: the mutation test
        // confirmed no other test catches that deletion (the harness-based theme
        // test sets appearance on its OWN window, not the exporter's).
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("qa-appearance-\(UUID().uuidString).pdf")
        let exporter = PDFExporter(destinationURL: dest)

        guard let appearance = exporter.hostWindow.appearance else {
            XCTFail("PDFExporter.init did not set an appearance on hostWindow — it must force .aqua so the offscreen render is dark-on-white")
            return
        }
        XCTAssertEqual(
            appearance.name, NSAppearance.Name.aqua,
            "PDFExporter must force a light (aqua) appearance, not \(appearance.name.rawValue)"
        )
    }

    @MainActor
    func testNonMermaidMediaCappedUnderPrintOverride() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed test."
        )
        _ = NSApplication.shared

        // A non-Mermaid diagram (flowchart.js) renders an <svg> inside
        // `.diagram-flow` — which the print override's `svg:not(.diagram-mermaid
        // svg)` selector must still reach. flow's width is also bounded by the
        // base `.diagram svg { max-width:100% }` rule, so this primarily guards
        // that non-Mermaid diagrams still RENDER and stay bounded under the print
        // override — the regression surface a future selector refactor that
        // over-excludes non-Mermaid SVGs would break.
        let html = MarkdownRenderer().render("""
        ```flow
        st=>start: Begin
        op=>operation: A moderately long operation label
        e=>end: Finish
        st->op->e
        ```
        """).html

        let probe = """
        (function () {
          var svg = document.querySelector('.diagram-flow svg') || document.querySelector('svg:not(.diagram-mermaid svg)');
          var r = svg ? svg.getBoundingClientRect() : null;
          var main = document.querySelector('main') || document.body;
          return { width: r ? Math.round(r.width) : 0, container: Math.round(main.getBoundingClientRect().width) };
        })()
        """
        let result = try loadAndProbe(html: html, printOverride: true, probe: probe)

        let width = CGFloat((result["width"] as? NSNumber)?.doubleValue ?? 0)
        let container = CGFloat((result["container"] as? NSNumber)?.doubleValue ?? 600)
        XCTAssertGreaterThan(width, 0, "flowchart (non-Mermaid) diagram did not render to an <svg>")
        XCTAssertLessThanOrEqual(
            width, container + 1,
            "non-Mermaid SVG was not capped to the printable column (width=\(width), container=\(container))"
        )
    }

    // MARK: - Harness

    @MainActor
    func testLongCJKMermaidLabelWrapsToBoundedWidth() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed test."
        )

        // The reference diagram: two `graph TD` subgraphs, each carrying a long
        // plain-CJK note label. Before the wrap, Mermaid laid the notes out at
        // their full un-wrapped length and the SVG's natural width ballooned to
        // ~1378 px; wrapped, it should stay well below the printable column.
        let src = """
        graph TD
            subgraph AppLayer [应用层业务 App Layer]
                A[服务 A] --- B[服务 B] --- C[业务逻辑]
                note1[特点：迭代更快、业务隔离、单点故障影响面局部、容错率相对较高]
            end

            subgraph InfraLayer [基础设施与运维]
                D[物理服务器 / 虚机集群 / 容器集群 ]
                E[核心网关与路由 / 云网关 / 负载均衡]
                F[数据库 / 存储底座]
                note2[特点：日常无感、全局底座、爆炸半径极广、误操作容错率为零]
            end

            AppLayer ==>|强依赖于| InfraLayer

            style AppLayer fill:#1e293b,stroke:#38bdf8,stroke-width:2px,color:#fff
            style InfraLayer fill:#0f172a,stroke:#ef4444,stroke-width:2px,color:#fff
        """
        let html = MarkdownRenderer().render("```mermaid\n\(src)\n```").html

        let probe = """
        (function () {
          var svg = document.querySelector('.diagram-mermaid svg');
          var vb = svg ? (svg.getAttribute('viewBox') || '') : '';
          var parts = vb.split(' ');
          return { width: parts.length > 2 ? (parseFloat(parts[2]) || 0) : 0 };
        })()
        """
        let result = try loadAndProbe(html: html, probe: probe)
        let width = CGFloat((result["width"] as? NSNumber)?.doubleValue ?? 0)
        XCTAssertGreaterThan(width, 0, "reference Mermaid diagram did not render")
        // Before the wrap the reference diagram's natural width was ~1378 px; the
        // wrap bounds each long label to ~15 code points and brings it under
        // ~1100 px. It cannot reach the ~523 px printable column because Mermaid
        // still lays the two subgraphs side by side (layout is out of scope), but
        // the regression (un-wrapped long labels) is clearly caught here.
        XCTAssertLessThan(width, 1100, "long CJK note labels were not wrapped (natural width=\(width))")
    }

    @MainActor
    func testLongLatinMermaidLabelWraps() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed test."
        )

        let src = """
        flowchart LR
          A[This is an extremely long label that just keeps going and going and would definitely need wrapping to fit on one line]
        """
        let html = MarkdownRenderer().render("```mermaid\n\(src)\n```").html

        let probe = """
        (function () {
          var svg = document.querySelector('.diagram-mermaid svg');
          var vb = svg ? (svg.getAttribute('viewBox') || '') : '';
          var parts = vb.split(' ');
          return { width: parts.length > 2 ? (parseFloat(parts[2]) || 0) : 0 };
        })()
        """
        let result = try loadAndProbe(html: html, probe: probe)
        let width = CGFloat((result["width"] as? NSNumber)?.doubleValue ?? 0)
        XCTAssertGreaterThan(width, 0, "latin-label Mermaid diagram did not render")
        XCTAssertLessThan(width, 500, "long latin label was not wrapped (natural width=\(width))")
    }

    @MainActor
    func testWrapLeavesNonPlainLabelsUntouched() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed test."
        )

        // Every element the wrap must NOT touch: a short label, an HTML label
        // with an explicit <br/>, a long edge label, a long subgraph title, and a
        // style directive. If the wrap corrupted any of these, Mermaid would fall
        // back to source text (error) or drop the title/style.
        let src = """
        graph TD
            A[short]
            B[x<br/>y]
            A -->|a very long edge label that must stay intact| B
            subgraph sg [这是一个很长的子图标题，用来验证它不会被自动换行处理]
                C[服务]
            end
            style sg fill:#112233,stroke:#445566,color:#ffffff
        """
        let html = MarkdownRenderer().render("```mermaid\n\(src)\n```").html

        let probe = """
        (function () {
          var el = document.querySelector('.diagram-mermaid');
          var svg = el && el.querySelector('svg');
          var labels = [];
          if (svg) {
            var divs = svg.querySelectorAll('foreignObject div');
            for (var i = 0; i < divs.length; i++) { labels.push(divs[i].textContent || ''); }
          }
          return {
            svg: !!svg,
            error: !!(el && el.classList.contains('diagram-error')),
            labels: labels
          };
        })()
        """
        let result = try loadAndProbe(html: html, probe: probe)
        XCTAssertTrue(boolValue(result["svg"]), "diagram must render to an <svg>")
        XCTAssertFalse(boolValue(result["error"]), "wrap corrupted a non-plain label into the error path")
        let labels = (result["labels"] as? [String]) ?? []
        XCTAssertTrue(
            labels.contains { $0.contains("这是一个很长的子图标题") },
            "long subgraph title must stay intact (labels=\(labels))"
        )
        XCTAssertTrue(
            labels.contains { $0.contains("short") },
            "short label must stay intact (labels=\(labels))"
        )
    }

    /// Loads `html` into an off-screen, window-hosted `WKWebView` (mirroring the
    /// exporter so WebKit lays out and runs the engines), polls the settle signal,
    /// then evaluates `probe` and returns its result dictionary.
    @MainActor
    private func loadAndProbe(
        html: String,
        printOverride: Bool = false,
        appearance: NSAppearance? = nil,
        probe: String
    ) throws -> [String: Any] {
        _ = NSApplication.shared

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        if printOverride {
            // Inject the exact production print-density overrides so the probe
            // measures what the PDF exporter actually renders.
            let script = WKUserScript(
                source: PDFExporter.printStyleScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            configuration.userContentController.addUserScript(script)
        }

        let frame = NSRect(x: 0, y: 0, width: 600, height: 800)
        let webView = WKWebView(frame: frame, configuration: configuration)

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        if let appearance {
            window.appearance = appearance
        }
        window.contentView = webView
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        let delegate = NavigationDelegate()
        webView.navigationDelegate = delegate
        let loaded = expectation(description: "page load finished")
        delegate.onFinish = { loaded.fulfill() }
        webView.loadHTMLString(html, baseURL: nil)
        wait(for: [loaded], timeout: 15)

        // Poll the settle signal the same way the exporter does, bounded so a hang
        // surfaces as a failed assertion in the probe rather than a stuck test.
        let settled = expectation(description: "diagrams settled")
        func poll(_ attemptsLeft: Int) {
            webView.evaluateJavaScript("window.__md2DiagramsSettled === true") { value, _ in
                if (value as? Bool) ?? false {
                    settled.fulfill()
                } else if attemptsLeft > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll(attemptsLeft - 1) }
                } else {
                    settled.fulfill()
                }
            }
        }
        poll(240) // ~12s bound, matching the exporter's diagram-settle timeout
        wait(for: [settled], timeout: 20)

        let probed = expectation(description: "probe evaluated")
        var output: [String: Any] = [:]
        webView.evaluateJavaScript(probe) { value, _ in
            output = (value as? [String: Any]) ?? [:]
            probed.fulfill()
        }
        wait(for: [probed], timeout: 5)
        return output
    }

    private func boolValue(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        return (value as? Bool) ?? false
    }
}

private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    var onFinish: (() -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish?()
    }
}
