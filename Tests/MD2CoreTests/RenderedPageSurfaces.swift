import AppKit
import MD2Core
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

/// The places a rendered page runs. Document content has to be inert on each.
enum RenderedPageSurface: CaseIterable {
    /// The real `MarkdownPreviewView`, with its bridges and user scripts.
    case preview
    /// The window-hosted web view and print overrides PDF export uses.
    case offscreen
    /// A `file:` page holding the inlined engines, built the way HTML export
    /// builds it.
    case exportedFile
}

/// Rewrites of a finished page, applied just before it is shown.
enum RenderedPageEdit {
    private static let policyTag = #"<meta http-equiv="Content-Security-Policy"[^>]*>"#

    /// The page without its policy, to test what the layers under it do alone
    /// and to show a test would notice script that does run.
    static func removingPolicy(_ html: String) -> String {
        html.replacingOccurrences(of: policyTag, with: "", options: .regularExpression)
    }

    /// Keeps every policy violation in `window.__md2Violations`. A policy only
    /// covers what the parser reaches after it, so this runs from just ahead of
    /// the tag, on any surface, without a way into each surface's configuration.
    static func recordingViolations(_ html: String) -> String {
        let recorder = """
        <script>
        window.__md2Violations = [];
        document.addEventListener('securitypolicyviolation', function (event) {
            window.__md2Violations.push([event.effectiveDirective, event.blockedURI, event.sample].join(' '));
        });
        </script>
        """
        return html.replacingOccurrences(
            of: policyTag, with: "\(recorder)\n$0", options: .regularExpression
        )
    }
}

/// A suite that runs on real rendered pages. Requires a GUI session (WebKit).
@MainActor protocol RenderedPageTesting: XCTestCase {}

extension RenderedPageTesting {
    /// Shows `markdown` on `surface` and hands `body` the settled page. `edit`
    /// rewrites the finished page. `files` sit beside an exported file, and
    /// `embedsFiles` makes that the saved document's folder, so export embeds them.
    /// `onOpenWithSystem` receives what the preview hands to the system; nothing
    /// a test clicks reaches the real handlers.
    func withPage(
        _ markdown: String,
        on surface: RenderedPageSurface,
        edit: (String) -> String = { $0 },
        files: [String: Data] = [:],
        embedsFiles: Bool = false,
        onOpenWithSystem: @escaping (URL) -> Void = { _ in },
        _ body: (WKWebView) throws -> Void
    ) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }

        // Declared here so each outlives the page it serves: the web view holds
        // its navigation delegate weakly.
        let loader = WebDocumentLoader()
        let delegate = RenderedPageNavigationDelegate()
        let webView: WKWebView
        switch surface {
        case .preview:
            let rendered = MarkdownRenderer().render(markdown, assetMode: .appScheme)
            let hosting = NSHostingView(rootView: MarkdownPreviewView(
                html: edit(rendered.html), bodyHTML: rendered.body, baseURL: nil,
                jumpHeadingID: .constant(nil), jumpFraction: .constant(nil), jumpAnchor: .constant(nil),
                onOpenWithSystem: onOpenWithSystem,
                findQuery: .constant(""), findNavigation: .constant(nil), focusToken: UUID()
            ))
            window.contentView = hosting
            XCTAssertTrue(spin(15) { self.webView(in: hosting) != nil }, "the preview built no web view")
            webView = try XCTUnwrap(self.webView(in: hosting))
        case .offscreen:
            let configuration = WKWebViewConfiguration()
            loader.install(on: configuration)
            configuration.userContentController.addUserScript(WKUserScript(
                source: PDFExporter.printStyleScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true
            ))
            webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
            webView.navigationDelegate = delegate
            window.contentView = webView
            loader.load(edit(MarkdownRenderer().render(markdown, assetMode: .appScheme).html), baseURL: nil, in: webView)
        case .exportedFile:
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("md2-page-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            for (name, data) in files {
                try data.write(to: directory.appendingPathComponent(name))
            }
            let file = directory.appendingPathComponent("export.html")
            let rendered = MarkdownRenderer().render(markdown, assetMode: .inline)
            try edit(SelfContainedHTMLBuilder.build(html: rendered.html, baseURL: embedsFiles ? directory : nil).html)
                .write(to: file, atomically: true, encoding: .utf8)
            webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: WKWebViewConfiguration())
            webView.navigationDelegate = delegate
            window.contentView = webView
            webView.loadFileURL(file, allowingReadAccessTo: directory)
            XCTAssertTrue(spin(15) { delegate.finished }, "the exported file did not load")
        }
        XCTAssertTrue(spin(15) { self.isSettled(webView) }, "\(surface): the page never settled")
        try body(webView)
    }

    func spin(_ seconds: TimeInterval, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return predicate()
    }

    func evaluate(_ script: String, in webView: WKWebView) throws -> Any? {
        var value: Any?
        var failure: Error?
        var done = false
        webView.evaluateJavaScript(script) { result, error in
            value = result
            failure = error
            done = true
        }
        XCTAssertTrue(spin(5) { done }, "a script did not return")
        if let failure { throw failure }
        return value
    }

    /// A real, trusted mouse click, as a reader makes, on the middle of the
    /// element a script expression names. It goes to the web view directly, so it
    /// does not touch the machine's input.
    func click(_ element: String, in webView: WKWebView) throws {
        let rect = try XCTUnwrap(try evaluate("""
            (function () {
                var box = (\(element)).getBoundingClientRect();
                return [box.left + box.width / 2, box.top + box.height / 2];
            })()
            """, in: webView) as? [Double])
        let window = try XCTUnwrap(webView.window)
        let location = webView.convert(NSPoint(x: rect[0], y: rect[1]), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }
        webView.mouseDown(with: try event(.leftMouseDown))
        webView.mouseUp(with: try event(.leftMouseUp))
    }

    func webView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { self.webView(in: $0) }.first
    }

    /// Asks the page what it holds, because a diagram bootstrap that has not run
    /// looks the same as one the page never had: an engine can still be loading
    /// after the math bootstrap, which is in every page. A page whose policy
    /// refused that bootstrap never settles.
    private func isSettled(_ webView: WKWebView) -> Bool {
        let settled = """
            window.__md2RenderMath !== undefined
                && (document.querySelector('.diagram') === null || window.__md2DiagramsSettled === true)
            """
        return (try? evaluate(settled, in: webView)) as? Bool == true
    }
}

@MainActor private final class RenderedPageNavigationDelegate: NSObject, WKNavigationDelegate {
    private(set) var finished = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
}
