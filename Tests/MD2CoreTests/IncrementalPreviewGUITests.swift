import AppKit
import MD2Core
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

/// GUI-gated verification that a live (Side by Side) preview update keeps the
/// blocks that did not change, driven through a real `MarkdownPreviewView`.
///
/// The guarded failures are silent: a whole-page swap still shows the right
/// text, it just makes every diagram fall back to its placeholder and fade in
/// again, reloads every image, and — through the same path — kept rendering
/// formulas with the math macros the page was loaded with. So the assertions
/// are about node identity: an element captured before an edit must still be
/// the one in the page after it.
/// `MD2_RUN_GUI_TESTS=1 swift test --filter IncrementalPreviewGUITests`.
final class IncrementalPreviewGUITests: XCTestCase {
    private let diagramDocument = """
    # Title

    Intro paragraph.

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

    $$E = mc^2$$

    Closing paragraph.
    """

    // MARK: - Unchanged blocks stay

    /// The first edit after a load has to key the nodes the load rendered,
    /// from the body the page was loaded with; later edits use the stored keys.
    @MainActor
    func testEditingAParagraphKeepsDiagramsAndFormulasFromTheFirstEdit() throws {
        try skipUnlessGUITestsEnabled()
        let preview = try LivePreview(test: self, text: diagramDocument)
        defer { preview.close() }
        XCTAssertTrue(try preview.waitFor("window.__md2DiagramsSettled === true && document.querySelectorAll('.diagram svg').length === 3"))
        XCTAssertEqual(try preview.evaluate("window.__md2MathDefines") as? Bool, false,
                       "plain formulas must not count as macro definitions, or every update re-renders all math")
        _ = try preview.evaluate("window.__kept = Array.from(document.querySelectorAll('.diagram svg, .katex-display, h1')); window.__kept.length")

        preview.show(diagramDocument.replacingOccurrences(of: "Intro paragraph.", with: "Intro paragraph, edited."))
        XCTAssertTrue(try preview.waitFor("document.body.textContent.indexOf('Intro paragraph, edited.') >= 0"))
        XCTAssertEqual(try preview.evaluate("window.__kept.length") as? Int, 5)
        XCTAssertEqual(try preview.evaluate("window.__kept.every(function (n) { return n.isConnected; })") as? Bool, true,
                       "the first edit after a load must keep the diagrams, formula and heading it did not touch")
        XCTAssertEqual(try preview.evaluate("document.querySelectorAll('.diagram-pending').length") as? Int, 0)

        preview.show(diagramDocument
            .replacingOccurrences(of: "Intro paragraph.", with: "Intro paragraph, edited.")
            .replacingOccurrences(of: "Closing paragraph.", with: "Closing paragraph, edited."))
        XCTAssertTrue(try preview.waitFor("document.body.textContent.indexOf('Closing paragraph, edited.') >= 0"))
        XCTAssertEqual(try preview.evaluate("window.__kept.every(function (n) { return n.isConnected; })") as? Bool, true)
        XCTAssertEqual(try preview.evaluate("document.querySelectorAll('.diagram svg').length") as? Int, 3)
    }

    /// Inserting lines changes only the source-line metadata of the blocks
    /// below. They stay, and take their new lines: the gutter, mode-switch
    /// anchors and task toggles all read those attributes.
    @MainActor
    func testInsertedLinesMoveKeptBlocksToTheirNewLines() throws {
        try skipUnlessGUITestsEnabled()
        let text = """
        # Title

        - [ ] Task one
        - [ ] Task two

        ```mermaid
        graph TD; A-->B;
        ```
        """
        let preview = try LivePreview(test: self, text: text, showsLineNumbers: true)
        defer { preview.close() }
        XCTAssertTrue(try preview.waitFor("window.__md2DiagramsSettled === true && !!document.querySelector('.diagram svg')"))
        _ = try preview.evaluate("window.__list = document.querySelector('main > ul'); window.__svg = document.querySelector('.diagram svg'); true")

        preview.show("Intro.\n\n" + text)
        XCTAssertTrue(try preview.waitFor("document.querySelector('main > p') !== null"))
        XCTAssertEqual(try preview.evaluate("window.__list.isConnected && window.__svg.isConnected") as? Bool, true)
        XCTAssertEqual(try preview.evaluate("window.__list.getAttribute('data-md2-source-line')") as? String, "5")
        XCTAssertEqual(try preview.evaluate("""
            Array.from(document.querySelectorAll('input[data-md2-task-line]'))
                .map(function (box) { return box.getAttribute('data-md2-task-line'); }).join(',')
            """) as? String, "5,6")
        XCTAssertEqual(try preview.evaluate("window.__svg.closest('[data-md2-source-line]').getAttribute('data-md2-source-line')") as? String, "8")
        XCTAssertEqual(try preview.evaluate("""
            Array.from(document.querySelectorAll('.md2-line-gutter span'))
                .map(function (span) { return span.getAttribute('data-md2-gutter'); }).join(',')
            """) as? String, "1,3,5,8")
    }

    @MainActor
    func testUnchangedImageKeepsItsElementAndURL() throws {
        try skipUnlessGUITestsEnabled()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("md2-incremental-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
        try png.write(to: directory.appendingPathComponent("dot.png"))
        let text = "![dot](dot.png)\n\nParagraph."

        let preview = try LivePreview(test: self, text: text, baseURL: directory)
        defer { preview.close() }
        XCTAssertTrue(try preview.waitFor("!!document.querySelector('img') && document.querySelector('img').naturalWidth === 1"))
        _ = try preview.evaluate("window.__img = document.querySelector('img'); window.__src = window.__img.getAttribute('src'); true")

        preview.show("![dot](dot.png)\n\nParagraph, edited.")
        XCTAssertTrue(try preview.waitFor("document.body.textContent.indexOf('Paragraph, edited.') >= 0"))
        XCTAssertEqual(try preview.evaluate("window.__img.isConnected && document.querySelector('img') === window.__img") as? Bool, true)
        XCTAssertEqual(try preview.evaluate("document.querySelector('img').getAttribute('src') === window.__src") as? Bool, true)
        XCTAssertEqual(try preview.evaluate("window.__img.naturalWidth") as? Int, 1)
    }

    /// Serializing an element without its line attributes must not touch text
    /// that spells one: that text is content, and a change to it is a change.
    @MainActor
    func testTextSpellingALineAttributeStillUpdates() throws {
        try skipUnlessGUITestsEnabled()
        let text = "```\n<p data-md2-source-line=\"5\">x</p>\n```"
        let preview = try LivePreview(test: self, text: text)
        defer { preview.close() }
        XCTAssertTrue(try preview.waitFor("document.querySelector('pre code').textContent.indexOf('\"5\"') >= 0"))

        preview.show(text.replacingOccurrences(of: "\"5\"", with: "\"6\""))
        XCTAssertTrue(try preview.waitFor("document.querySelector('pre code').textContent.indexOf('\"6\"') >= 0"))
    }

    // MARK: - Math

    /// F04 in the 2026-10-15 review: a live update kept rendering formulas with
    /// the `math-macros:` the page was loaded with.
    @MainActor
    func testFrontMatterMacroEditsReachKeptFormulas() throws {
        try skipUnlessGUITestsEnabled()
        func document(_ macros: String) -> String {
            "---\nmath-macros: {\(macros)}\n---\n\nThe value $\\audit$ here.\n\nOther paragraph."
        }
        let preview = try LivePreview(test: self, text: document(#""\\audit": "\\alpha""#))
        defer { preview.close() }
        XCTAssertTrue(try preview.waitFor("!!document.querySelector('.katex') && document.querySelector('.katex-html').textContent.indexOf('α') >= 0"))
        _ = try preview.evaluate("window.__formula = document.querySelector('.katex').closest('p'); true")

        preview.show(document(#""\\audit": "\\beta""#))
        XCTAssertTrue(try preview.waitFor("document.querySelector('.katex-html').textContent.indexOf('β') >= 0"),
                      "a changed macro must reach the formula")
        XCTAssertEqual(try preview.evaluate("window.__formula.isConnected") as? Bool, true,
                       "the formula's block did not change, so it stays and renders again in place")

        preview.show(document(""))
        XCTAssertTrue(try preview.waitFor(try showsUndefined("\\audit")),
                      "a removed macro must leave the formula undefined, as a full load would")
    }

    /// `\newcommand` writes into the macros object KaTeX shares across
    /// formulas, so a definition in a new block changes formulas that stayed.
    @MainActor
    func testDefinitionsInNewBlocksReachExistingFormulas() throws {
        try skipUnlessGUITestsEnabled()
        let text = "$$x \\in \\Field$$\n\nParagraph."
        let preview = try LivePreview(test: self, text: text)
        defer { preview.close() }
        XCTAssertTrue(try preview.waitFor(try showsUndefined("\\Field")))
        _ = try preview.evaluate("window.__formula = document.querySelector('.math-display'); true")

        preview.show("$$\\newcommand{\\Field}{\\mathbb{F}}$$\n\n" + text)
        XCTAssertTrue(try preview.waitFor("!(\(try showsUndefined("\\Field"))) && !!document.querySelector('.mathbb')"),
                      "the new definition must reach the formula below it")
        XCTAssertEqual(try preview.evaluate("window.__formula.isConnected") as? Bool, true)
        XCTAssertEqual(try preview.evaluate("window.__md2MathDefines") as? Bool, true)

        preview.show(text)
        XCTAssertTrue(try preview.waitFor(try showsUndefined("\\Field")),
                      "removing the definition must leave the formula undefined again")
    }

    /// With `throwOnError: false`, KaTeX draws an undefined command as its own
    /// name in the error color, not as a `.katex-error` element.
    private func showsUndefined(_ command: String) throws -> String {
        """
        Array.from(document.querySelectorAll('.katex-html')).some(function (node) {
            return node.textContent.indexOf(\(try jsLiteral(command))) >= 0;
        })
        """
    }

    // MARK: - Fallbacks

    @MainActor
    func testUnmatchedPageOrAppearanceChangeReplacesEverything() throws {
        try skipUnlessGUITestsEnabled()
        let preview = try LivePreview(test: self, text: diagramDocument)
        defer { preview.close() }
        XCTAssertTrue(try preview.waitFor("window.__md2DiagramsSettled === true"))
        let body = try jsLiteral(MarkdownRenderer().render(diagramDocument, assetMode: .appScheme).body)

        // A loaded body that does not pair up with the page leaves it unkeyed.
        let unmatched = try preview.evaluate("window.__md2ApplyContent(\(body), { loaded: '<p>Another page</p>' })") as? [String: Any]
        XCTAssertEqual(unmatched?["replacedAll"] as? Bool, true)

        let same = try preview.evaluate("window.__md2ApplyContent(\(body), {})") as? [String: Any]
        XCTAssertEqual(same?["replacedAll"] as? Bool, false)
        XCTAssertEqual(same?["inserted"] as? Int, 0, "an unchanged body inserts nothing")

        // Kept diagrams were drawn for the appearance of their render.
        _ = try preview.evaluate("window.__md2DiagramDark = !window.__md2DiagramDark; true")
        let switched = try preview.evaluate("window.__md2ApplyContent(\(body), {})") as? [String: Any]
        XCTAssertEqual(switched?["replacedAll"] as? Bool, true)
        XCTAssertTrue(try preview.waitFor("window.__md2DiagramsSettled === true && document.querySelectorAll('.diagram svg').length === 3"))
    }

    // MARK: - Harness

    private func skipUnlessGUITestsEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed test."
        )
    }

    private func jsLiteral(_ string: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}

/// A Side by Side preview (`liveUpdate`) hosted in an off-screen window. Each
/// `show` renders new text the way the app does and hands it to the same view,
/// so updates take the coordinator's live path.
@MainActor
private final class LivePreview {
    private let test: XCTestCase
    private let baseURL: URL?
    private let showsLineNumbers: Bool
    private let focusToken = UUID()
    private let hosting: NSHostingView<MarkdownPreviewView>
    private let window: NSWindow
    let webView: WKWebView

    init(test: XCTestCase, text: String, baseURL: URL? = nil, showsLineNumbers: Bool = false) throws {
        _ = NSApplication.shared
        self.test = test
        self.baseURL = baseURL
        self.showsLineNumbers = showsLineNumbers
        let hosting = NSHostingView(rootView: Self.preview(text, baseURL: baseURL, showsLineNumbers: showsLineNumbers, focusToken: focusToken))
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 700, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        self.hosting = hosting
        self.window = window
        _ = Self.spin { Self.webView(in: hosting) != nil }
        webView = try XCTUnwrap(Self.webView(in: hosting), "the preview never created its web view")
        let coordinator = try XCTUnwrap(webView.navigationDelegate as? MarkdownPreviewView.Coordinator)
        XCTAssertTrue(Self.spin { coordinator.isLoaded }, "the preview never finished its first load")
    }

    func show(_ text: String) {
        hosting.rootView = Self.preview(text, baseURL: baseURL, showsLineNumbers: showsLineNumbers, focusToken: focusToken)
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }

    /// Renders like `DocumentRenderWorker`, which reads `math-macros:` from the
    /// front matter.
    private static func preview(_ text: String, baseURL: URL?, showsLineNumbers: Bool, focusToken: UUID) -> MarkdownPreviewView {
        let macros = FrontMatterReader.parseMathMacros(FrontMatterReader.fields(in: text)["math-macros"])
        let rendered = MarkdownRenderer().render(text, config: RenderConfig(mathMacros: macros), assetMode: .appScheme)
        return MarkdownPreviewView(
            html: rendered.html, bodyHTML: rendered.body, mathMacros: rendered.mathMacros, baseURL: baseURL,
            liveUpdate: true, showsLineNumbers: showsLineNumbers,
            jumpHeadingID: .constant(nil), jumpFraction: .constant(nil), jumpAnchor: .constant(nil),
            findQuery: .constant(""), findNavigation: .constant(nil), focusToken: focusToken
        )
    }

    private static func webView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { webView(in: $0) }.first
    }

    func waitFor(_ condition: String) throws -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if try evaluate("(function () { try { return !!(\(condition)); } catch (e) { return false; } })()") as? Bool == true {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    func evaluate(_ script: String) throws -> Any? {
        let done = test.expectation(description: "evaluate")
        var value: Any?
        var failure: Error?
        webView.evaluateJavaScript(script) { result, error in
            value = result
            failure = error
            done.fulfill()
        }
        test.wait(for: [done], timeout: 5)
        if let failure { throw failure }
        return value
    }

    private static func spin(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return predicate()
    }
}
