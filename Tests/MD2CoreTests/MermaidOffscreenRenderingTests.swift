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

    // MARK: - Harness

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
