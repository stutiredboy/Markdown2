import AppKit
import PDFKit
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

/// Open the corpus through the document UI and export the same document through
/// both production backends. Only the save panel destinations are substituted.
final class RealDocumentCompatibilityGUITests: XCTestCase, RenderedPageTesting {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Requires AppKit and WebKit for real-document compatibility")
    }

    @MainActor func testProjectReadme() throws {
        try checkDocument(
            "project-readme",
            headings: ["Waypost", "Install a portable copy", "Configure an endpoint", "Roll out the service"],
            pageChecks: [
                #"document.querySelector('main a[href="https://waypost.example.test/guide/windows_(portable).md"]')?.textContent === 'portable Windows guide'"#,
                "document.querySelector('pre > code.language-sh')?.textContent.includes('# Keep a separate spool for dry runs')",
                "document.querySelector('pre > code.language-sh .tok-keyword')?.textContent === 'set'",
                "document.querySelector('ol')?.start === 10 && document.querySelectorAll('ol > li').length === 2",
                "document.querySelector('ol > li > ul')?.textContent.includes('Verify the health check')"
            ],
            pdfText: [
                "portable Windows guide", "Keep a separate spool for dry runs",
                "10. Restart the worker.", "Verify the health check", "11. Re-enable traffic."
            ]
        )
    }

    @MainActor func testTechnicalNote() throws {
        try checkDocument(
            "technical-note",
            headings: ["Recovering an interrupted spool rotation", "Recovery procedure", "Checks before releasing the hold", "Results | next steps"],
            pageChecks: [
                "document.querySelector('pre > code.language-markdown')?.textContent.includes('### Sample incident entry')",
                "document.querySelectorAll('table tbody tr').length === 3",
                "document.querySelector('table tbody')?.textContent.includes('Only one active spool file')",
                "document.querySelector('table + h2')?.textContent === 'Results | next steps'"
            ],
            pdfText: ["acknowledged batch: 42", "Only one active spool file", "The recovered worker processed the remaining 180 records"]
        )
    }

    @MainActor func testChineseLongForm() throws {
        try checkDocument(
            "chinese-long-form",
            headings: ["社区修理工作坊手记", "开门以前", "交车时问三件事", "零件领用表", "收摊以后"],
            pageChecks: [
                ##"document.querySelector('main a[href="#零件领用表"]')?.textContent === '跳到零件领用表'"##,
                "document.querySelector('blockquote')?.textContent.includes('等候牌上只写登记号')",
                "document.querySelectorAll('table tbody tr').length === 3",
                "document.querySelector('main').textContent.includes('下周的第一张登记单')"
            ],
            pdfText: ["刹车线", "补胎片", "下周的第一张登记单"],
            navigateTo: "零件领用表"
        )
    }

    @MainActor func testMathHeavyNote() throws {
        try checkDocument(
            "math-heavy",
            headings: ["Measuring the length of a noisy trace", "Fit over the measured interval", "Integrate the fitted slope", "Comparison run"],
            pageChecks: [
                "!!document.querySelector('.math-inline .katex-html')",
                "document.querySelectorAll('.math-display .katex-html').length === 3",
                #"document.querySelector('[id="eq:trace-length"] .eq-number')?.textContent === '(1)'"#,
                ##"!!document.querySelector('a[href="#eq:trace-length"]')"##,
                "document.querySelector('main').textContent.includes('Keep the residual plot with the estimate.')"
            ],
            pdfText: ["∫", "(1)", "Fitted arclength", "Keep the residual plot with the estimate."]
        )
    }

    @MainActor func testPDFPrintStylesPreserveKaTeXRadicalGeometry() throws {
        try withPage(#"$$\sqrt{1+x}$$"#, on: .offscreen) { webView in
            let selector = ".katex .sqrt .hide-tail svg"
            XCTAssertTrue(spin(10) { (try? self.evaluate("!!document.querySelector('\(selector) path')", in: webView)) as? Bool == true })
            let sizes = try XCTUnwrap(try evaluate("""
                (() => {
                    const svg = document.querySelector('\(selector)');
                    const bounds = svg.getBoundingClientRect();
                    return { width: bounds.width, height: bounds.height,
                             clipHeight: svg.parentElement.getBoundingClientRect().height };
                })()
                """, in: webView) as? [String: Double])
            // KaTeX clips a very wide path at the radicand's edge. The SVG
            // needs the height of its wrapper to preserve the visible root sign.
            let clipHeight = try XCTUnwrap(sizes["clipHeight"])
            XCTAssertGreaterThan(clipHeight, 0)
            XCTAssertGreaterThan(try XCTUnwrap(sizes["width"]), 0)
            XCTAssertEqual(try XCTUnwrap(sizes["height"]), clipHeight, accuracy: 0.5)
        }
    }

    @MainActor private func checkDocument(
        _ name: String,
        headings: [String],
        pageChecks: [String],
        pdfText: [String],
        navigateTo headingToReveal: String? = nil
    ) throws {
        _ = NSApplication.shared
        let resource = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Corpus/real-documents"))
        let bytes = try Data(contentsOf: resource)
        let suite = "RealDocumentCompatibility-\(UUID())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent(resource.lastPathComponent)
        let html = directory.appendingPathComponent("export.html")
        let pdf = directory.appendingPathComponent("export.pdf")
        try bytes.write(to: source)

        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.defaultMode = .split
        settings.newDocumentMode = .split
        settings.showsOutlineByDefault = true
        let store = DocumentStore(pdfDestinationPicker: { _ in pdf }, htmlDestinationPicker: { _ in html })
        store.open(source)
        defer { _ = store.closeDocument(discardRecovery: false) }

        let host = NSHostingView(rootView: ContentView(document: store, settings: settings, onOpen: {}))
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1_260, height: 525),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }

        XCTAssertTrue(spin(15) { store.editorSession.textView != nil && self.webView(in: host) != nil })
        let editor = try XCTUnwrap(store.editorSession.textView)
        let preview = try XCTUnwrap(webView(in: host))
        XCTAssertEqual(Data(editor.string.utf8), bytes, "\(name): native source was changed on open")
        try checkPage(preview, name: "\(name) preview", headings: headings, checks: pageChecks)

        XCTAssertTrue(spin(10) { self.nativeOutline(in: host)?.numberOfRows == headings.count })
        let outline = try XCTUnwrap(nativeOutline(in: host))
        XCTAssertEqual(outline.numberOfRows, headings.count)
        XCTAssertEqual(store.rendered.outline.map(\.title), headings)
        if let headingToReveal {
            let row = try XCTUnwrap(store.rendered.outline.firstIndex(where: { $0.title == headingToReveal }))
            let heading = store.rendered.outline[row]
            let range = (editor.string as NSString).range(of: "## \(headingToReveal)")
            XCTAssertNotEqual(range.location, NSNotFound)
            XCTAssertFalse(isVisible(range, in: editor), "target must begin outside the editor viewport")
            XCTAssertFalse(try previewTargetIsVisible(heading.id, in: preview), "target must begin outside the preview viewport")
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            XCTAssertTrue(spin(10) {
                self.isVisible(range, in: editor) && (try? self.previewTargetIsVisible(heading.id, in: preview)) == true
            }, "native outline selection did not reveal \(heading.title) in both panes")
            XCTAssertEqual(outline.selectedRow, row)
        }

        let exported = expectation(description: "\(name) HTML export")
        Task { await store.exportHTML(); exported.fulfill() }
        wait(for: [exported], timeout: 15)
        XCTAssertNil(store.alert)
        try withExportedPage(html) { webView in
            try checkPage(webView, name: "\(name) HTML", headings: headings, checks: pageChecks)
        }

        let started = expectation(description: "\(name) PDF export started")
        Task { await store.exportPDF(); started.fulfill() }
        wait(for: [started], timeout: 15)
        XCTAssertTrue(spin(35) { FileManager.default.fileExists(atPath: pdf.path) || store.alert != nil })
        XCTAssertNil(store.alert)
        let document = try XCTUnwrap(PDFDocument(url: pdf))
        XCTAssertEqual(bookmarks(try XCTUnwrap(document.outlineRoot)), headings)
        let text = comparablePDFText(try XCTUnwrap(document.string))
        for marker in headings + pdfText {
            XCTAssertTrue(text.contains(comparablePDFText(marker)), "\(name) PDF lost \(marker)")
        }

        XCTAssertFalse(store.isDirty)
        XCTAssertEqual(Data(store.text.utf8), bytes)
        XCTAssertEqual(Data(editor.string.utf8), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes, "\(name): exporting modified the source file")
        XCTAssertTrue(store.save())
        XCTAssertEqual(try Data(contentsOf: source), bytes, "\(name): saving modified the source bytes")
    }

    @MainActor private func checkPage(_ webView: WKWebView, name: String, headings: [String], checks: [String]) throws {
        let headingScript = "Array.from(document.querySelectorAll('main h1, main h2, main h3, main h4, main h5, main h6'), el => el.textContent)"
        XCTAssertTrue(spin(15) {
            !webView.isLoading && (try? self.evaluate("\(headingScript)[0]", in: webView)) as? String == headings.first
        }, "\(name): the rendered document did not load")
        XCTAssertEqual(try evaluate(headingScript, in: webView) as? [String], headings, name)
        for check in checks {
            XCTAssertEqual(try evaluate(check, in: webView) as? Bool, true, "\(name): \(check)")
        }
    }

    @MainActor private func withExportedPage(_ url: URL, check: (WKWebView) throws -> Void) throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderFrontRegardless()
        defer { webView.stopLoading(); window.orderOut(nil); window.contentView = nil }
        webView.loadFileURL(url, allowingReadAccessTo: url)
        try check(webView)
    }

    @MainActor private func nativeOutline(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { self.nativeOutline(in: $0) }.first
    }

    @MainActor private func isVisible(_ range: NSRange, in editor: NSTextView) -> Bool {
        guard range.location != NSNotFound, let manager = editor.layoutManager,
              let container = editor.textContainer else { return false }
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let bounds = manager.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
        return editor.visibleRect.intersects(bounds)
    }

    @MainActor private func previewTargetIsVisible(_ id: String, in webView: WKWebView) throws -> Bool {
        let argument = try String(decoding: JSONEncoder().encode(id), as: UTF8.self)
        return try evaluate("""
            (() => {
              const bounds = document.getElementById(\(argument))?.getBoundingClientRect();
              return !!bounds && bounds.bottom > 0 && bounds.top < innerHeight;
            })()
            """, in: webView) as? Bool == true
    }

    private func bookmarks(_ root: PDFOutline) -> [String] {
        (0..<root.numberOfChildren).compactMap { root.child(at: $0) }.flatMap { bookmark in
            [bookmark.label ?? ""] + bookmarks(bookmark)
        }
    }

    private func comparablePDFText(_ text: String) -> String {
        // The platform PDF writer can map Han glyphs to radicals sharing the
        // same shape. This check measures which content printed. Source bytes
        // and PDF bookmark labels above are still compared directly.
        text.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "\u{2ECB}", with: "车")
            .replacingOccurrences(of: "\u{2ED4}", with: "门")
            .filter { !$0.isWhitespace }
    }
}
