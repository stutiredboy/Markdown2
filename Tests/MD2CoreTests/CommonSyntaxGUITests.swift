import AppKit
import MD2Core
import PDFKit
import WebKit
import XCTest
@testable import MD2App

final class CommonSyntaxGUITests: XCTestCase {
    private let markdown = """
    # README syntax

    > [!NOTE]
    > ==Highlighted text==, H~2~O and x^2^.
    > [Reference link][docs] and https://example.com/a_(b).

    > [!TIP]
    > A useful tip.

    > [!IMPORTANT]
    > Important information.

    > [!WARNING]
    > A warning with **bold text**.

    > [!CAUTION]
    > Proceed with care.

    [docs]: https://example.com/docs "Documentation"
    """

    @MainActor func testLightDarkPreviewAndActualPDF() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1", "Requires WebKit GUI session")
        _ = NSApplication.shared
        let config = RenderConfig(inlineFeatures: .init(highlight: true, superscript: true, subscriptEnabled: true), alertLanguage: .simplifiedChinese)
        let rendered = MarkdownRenderer().render(markdown, config: config, assetMode: .appScheme)
        let loader = WebDocumentLoader()
        let configuration = WKWebViewConfiguration()
        loader.install(on: configuration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 880), configuration: configuration)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        let loaded = expectation(description: "syntax loaded")
        let delegate = SyntaxNavigationDelegate { loaded.fulfill() }
        webView.navigationDelegate = delegate
        loader.load(rendered.html, baseURL: nil, in: webView)
        wait(for: [loaded], timeout: 15)
        XCTAssertEqual(try evaluate("document.querySelectorAll('.markdown-alert').length", in: webView) as? Int, 5)
        XCTAssertEqual(try evaluate("document.querySelector('.markdown-alert-title').textContent", in: webView) as? String, "注意")
        XCTAssertEqual(try evaluate("document.querySelectorAll('main a').length", in: webView) as? Int, 2)
        XCTAssertEqual(try evaluate("document.querySelector('mark').textContent", in: webView) as? String, "Highlighted text")
        XCTAssertEqual(try evaluate("document.querySelector('sup').textContent", in: webView) as? String, "2")
        XCTAssertEqual(try evaluate("document.querySelector('sub').textContent", in: webView) as? String, "2")
        var borderColors: [String] = []
        for scheme in ["light", "dark"] {
            // Pin the document's actual CSS color scheme so light-dark() is
            // exercised regardless of the desktop session's appearance.
            _ = try evaluate("document.documentElement.style.colorScheme = '\(scheme)'; true", in: webView)
            let border = try XCTUnwrap(evaluate("getComputedStyle(document.querySelector('.markdown-alert-note')).borderLeftColor", in: webView) as? String)
            borderColors.append(border)
            XCTAssertEqual(try evaluate("getComputedStyle(document.querySelector('.markdown-alert-title')).color", in: webView) as? String, border)
            XCTAssertEqual(try evaluate("getComputedStyle(document.querySelector('.markdown-alert')).borderLeftWidth", in: webView) as? String, "4px")
            XCTAssertEqual(try evaluate("document.documentElement.scrollWidth <= innerWidth", in: webView) as? Bool, true)
            try snapshot(webView, name: "md2-common-syntax-\(scheme).png")
        }
        XCTAssertEqual(borderColors, ["rgb(9, 105, 218)", "rgb(88, 166, 255)"])

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("md2-common-syntax.pdf")
        let exporter = PDFExporter(destinationURL: destination)
        let exported = expectation(description: "syntax PDF")
        var failure: Error?
        exporter.export(html: rendered.html, outline: rendered.outline, baseURL: nil) { result in
            if case .failure(let error) = result { failure = error }
            exported.fulfill()
        }
        wait(for: [exported], timeout: 35)
        if let failure { throw failure }
        let pdf = try XCTUnwrap(PDFDocument(url: destination))
        let text = try XCTUnwrap(pdf.string)
        XCTAssertTrue(text.contains("注意"))
        XCTAssertTrue(text.contains("Highlighted text"))
        XCTAssertTrue(text.contains("Reference link"))
        XCTAssertFalse(text.contains("[!NOTE]"))
        XCTAssertFalse(text.contains("[docs]:"))
        let page = try XCTUnwrap(pdf.page(at: 0))
        let preview = page.thumbnail(of: NSSize(width: 840, height: 1188), for: .mediaBox)
        try writePNG(preview, name: "md2-common-syntax-pdf.png")
    }

    @MainActor private func snapshot(_ webView: WKWebView, name: String) throws {
        let done = expectation(description: "snapshot")
        var captured: NSImage?
        webView.takeSnapshot(with: nil) { image, _ in captured = image; done.fulfill() }
        wait(for: [done], timeout: 5)
        try writePNG(XCTUnwrap(captured), name: name)
    }

    private func writePNG(_ image: NSImage, name: String) throws {
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(name))
    }

    @MainActor private func evaluate(_ script: String, in webView: WKWebView) throws -> Any? {
        let done = expectation(description: "script")
        var value: Any?
        var failure: Error?
        webView.evaluateJavaScript(script) { result, error in value = result; failure = error; done.fulfill() }
        wait(for: [done], timeout: 5)
        if let failure { throw failure }
        return value
    }
}

@MainActor private final class SyntaxNavigationDelegate: NSObject, WKNavigationDelegate {
    let finish: () -> Void
    init(_ finish: @escaping () -> Void) { self.finish = finish }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
}
