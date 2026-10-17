import AppKit
import MD2Core
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

final class WebDocumentLoaderGUITests: XCTestCase {
    @MainActor
    func testRealPreviewReloadsAndLiveUpdatesWithoutTouchingDocumentDirectory() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1", "Requires WebKit GUI session")
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("md2-memory-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
        try png.write(to: directory.appendingPathComponent("图 & image.png"))
        let markdown = """
        # First

        $x^2$ and $\\ce{H2O}$

        ![image](图%20%26%20image.png)

        [chapter](next.md#part) [anchor](#first)

        ```mermaid
        graph TD; A-->B;
        ```

        ```flow
        st=>start: Start
        e=>end: End
        st->e
        ```

        ```sequence
        A->B: Hello
        ```
        """
        let source = directory.appendingPathComponent("notes.md")
        try markdown.write(to: source, atomically: true, encoding: .utf8)
        // Even legacy leftovers are user-directory entries: opening a document
        // must no longer sweep them away or change directory metadata.
        let legacy = directory.appendingPathComponent(".md2-preview-old.html")
        try "legacy".write(to: legacy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: legacy.path)
        let before = try snapshot(directory)
        let modified = try directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        func preview(_ text: String, live: Bool = false) -> MarkdownPreviewView {
            let rendered = MarkdownRenderer().render(text, assetMode: .appScheme)
            return MarkdownPreviewView(
                html: rendered.html, bodyHTML: rendered.body, baseURL: directory, liveUpdate: live,
                jumpHeadingID: .constant(nil), jumpFraction: .constant(nil), jumpAnchor: .constant(nil),
                findQuery: .constant(""), findNavigation: .constant(nil), focusToken: UUID()
            )
        }
        let hosting = NSHostingView(rootView: preview(try String(contentsOf: source, encoding: .utf8)))
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 700, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        XCTAssertTrue(spin { self.webView(in: hosting) != nil })
        let webView = try XCTUnwrap(webView(in: hosting))
        let coordinator = try XCTUnwrap(webView.navigationDelegate as? MarkdownPreviewView.Coordinator)
        XCTAssertTrue(spin { coordinator.isLoaded })
        XCTAssertTrue(try waitForScript("window.__md2DiagramsSettled === true", in: webView))
        XCTAssertEqual(webView.url?.scheme, "md2-doc")
        XCTAssertEqual(try evaluate("document.querySelectorAll('.diagram svg').length", in: webView) as? Int, 3)
        XCTAssertEqual(try evaluate("document.querySelectorAll('.katex').length", in: webView) as? Int, 2)
        XCTAssertEqual(try evaluate("document.querySelectorAll('.diagram-error,.math-error').length", in: webView) as? Int, 0)
        XCTAssertEqual(try evaluate("document.querySelector('img').naturalWidth", in: webView) as? Int, 1)
        XCTAssertEqual(try evaluate("document.querySelector('a').href", in: webView) as? String,
                       directory.appendingPathComponent("next.md").absoluteString + "#part")
        let firstURL = try XCTUnwrap(webView.url)
        _ = try evaluate("document.querySelector('a[href=\"#first\"]').click(); true", in: webView)
        XCTAssertTrue(spin { webView.url?.fragment == "first" })

        // A full reload with the same heading must display the new body.
        hosting.rootView = preview(markdown.replacingOccurrences(of: "# First", with: "# Second"))
        XCTAssertTrue(spin { coordinator.isLoaded && webView.url?.path != firstURL.path })
        XCTAssertTrue(try waitForScript("document.querySelector('h1').textContent === 'Second' && window.__md2DiagramsSettled === true", in: webView))
        let secondURL = webView.url

        // Content-only replacement retains the page URL, engines, image access,
        // and filesystem link targets.
        hosting.rootView = preview("# Third\n\n$x^3$\n\n![image](图%20%26%20image.png)\n\n[chapter](next.md#part)", live: true)
        XCTAssertTrue(try waitForScript("document.querySelector('h1').textContent === 'Third' && document.querySelector('img').naturalWidth === 1", in: webView))
        XCTAssertEqual(webView.url, secondURL)
        XCTAssertEqual(try evaluate("document.querySelectorAll('.katex').length", in: webView) as? Int, 1)
        XCTAssertEqual(try evaluate("document.querySelector('a').href", in: webView) as? String,
                       directory.appendingPathComponent("next.md").absoluteString + "#part")
        XCTAssertEqual(try snapshot(directory), before)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified,
                       "a transient create/delete also changes directory metadata")
    }

    @MainActor private func webView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { self.webView(in: $0) }.first
    }

    private func snapshot(_ directory: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }

    @MainActor private func spin(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return predicate()
    }

    @MainActor private func waitForScript(_ script: String, in webView: WKWebView) throws -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if try evaluate(script, in: webView) as? Bool == true { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    @MainActor private func evaluate(_ script: String, in webView: WKWebView) throws -> Any? {
        let done = expectation(description: "evaluate")
        var value: Any?
        var failure: Error?
        webView.evaluateJavaScript(script) { result, error in
            value = result
            failure = error
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        if let failure { throw failure }
        return value
    }
}
