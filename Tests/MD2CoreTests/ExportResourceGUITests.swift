import AppKit
import Foundation
import MD2Core
import PDFKit
import WebKit
import XCTest
@testable import MD2App

final class ExportResourceGUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1", "Requires exclusive WebKit GUI lease")
    }

    @MainActor
    func testActualPDFDefaultAndGrantHaveRequestAndArtifactControls() throws {
        _ = NSApplication.shared
        let server = try ExportNetworkTestServer(image: magentaPNG())
        defer { server.stop() }
        let dir = try directory()
        defer { ExportTestEvidence.preserveThenRemove(dir) }
        for policy in [RemoteResourcePolicy.blocked, .allowRemoteImages] {
            let token = UUID().uuidString
            let source = "# Export marker\n\n<img src=\"\(server.baseURL)/\(token).png\" width=\"100\" height=\"100\" alt=\"remote marker\">"
            let destination = dir.appendingPathComponent("\(token).pdf")
            let result = runPDF(source, policy: policy, destination: destination, blockedLabel: "远程图片已阻止")
            guard case .success = result else { XCTFail("PDF: \(result)"); continue }
            let imagePresent = try containsMagenta(destination)
            XCTAssertEqual(imagePresent, policy == .allowRemoteImages, "real PDF pixels did not match the captured policy")
            XCTAssertEqual(server.requests.contains { $0.path.contains(token) }, policy == .allowRemoteImages)
            XCTAssertNotNil(PDFDocument(url: destination)?.string?.range(of: "Export marker"))
            if policy == .blocked { XCTAssertTrue(PDFDocument(url: destination)?.string?.contains("远程图片已阻止") == true) }
        }
    }

    @MainActor
    func testActualPrinterUsesTheSamePDFPreparationWithoutPhysicalPrinting() throws {
        _ = NSApplication.shared
        let server = try ExportNetworkTestServer(image: magentaPNG())
        defer { server.stop() }
        for policy in [RemoteResourcePolicy.blocked, .allowRemoteImages] {
            let token = UUID().uuidString
            let source = "# Print marker\n\n<img src=\"\(server.baseURL)/\(token).png\" width=\"100\" height=\"100\">"
            let rendered = MarkdownRenderer().render(source, assetMode: .appScheme, remoteResourcePolicy: policy)
            var presented = 0
            let printer = DocumentPrinter(printPresenter: { url, _ in
                ExportTestEvidence.preservePrint(url)
                presented += 1
                XCTAssertEqual(try? self.containsMagenta(url), policy == .allowRemoteImages)
                if policy == .blocked { XCTAssertTrue(PDFDocument(url: url)?.string?.contains("远程图片已阻止") == true) }
                return .success(())
            })
            let done = expectation(description: "actual print preparation")
            printer.print(html: rendered.html, outline: rendered.outline, baseURL: nil,
                remoteResourcePolicy: policy, profile: .default, documentTitle: "Print marker", remoteImageBlockedLabel: "远程图片已阻止") { result in
                if case .failure(let error) = result { XCTFail("print: \(error)") }
                done.fulfill()
            }
            wait(for: [done], timeout: 35)
            XCTAssertEqual(presented, 1)
            XCTAssertEqual(server.requests.contains { $0.path.contains(token) }, policy == .allowRemoteImages)
        }
    }

    @MainActor
    func testActualPDFSettlesSVGAndCSSImageClassResources() throws {
        _ = NSApplication.shared
        let server = try ExportNetworkTestServer(image: magentaPNG())
        defer { server.stop() }
        let dir = try directory()
        defer { ExportTestEvidence.preserveThenRemove(dir) }
        let css = UUID().uuidString, svg = UUID().uuidString
        let rendered = MarkdownRenderer().render("# CSS and SVG", assetMode: .appScheme, remoteResourcePolicy: .allowRemoteImages)
        // Intentional post-sanitizer fixture: exercises the actual exporter for
        // both image classes, without mistaking a removed authored style for deny.
        let fragment = "<div style=\"width:100px;height:100px;background-image:url('\(server.baseURL)/\(css).png')\"></div>" +
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\"><defs><mask id=\"local-mask\"><rect width=\"100\" height=\"100\" fill=\"white\"/></mask></defs><image href=\"\(server.baseURL)/\(svg).png\" width=\"100\" height=\"100\"/></svg>" +
            "<div style=\"width:10px;height:10px;mask-image:url(#local-mask)\"></div>"
        let html = rendered.html.replacingOccurrences(of: "<main>", with: "<main>" + fragment)
        let destination = dir.appendingPathComponent("styles.pdf")
        let exporter = PDFExporter(destinationURL: destination)
        let done = expectation(description: "CSS and SVG PDF")
        exporter.export(html: html, outline: [], baseURL: nil, remoteResourcePolicy: .allowRemoteImages) { result in
            if case .failure(let error) = result { XCTFail("image class readiness failed: \(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 35)
        XCTAssertTrue(try containsMagenta(destination))
        for token in [css, svg] {
            let count = server.requests.filter { $0.path.contains(token) }.count
            XCTAssertGreaterThan(count, 0)
            XCTAssertLessThanOrEqual(count, 3, "readiness must reuse its finite per-source probe")
        }
    }

    @MainActor
    func testAuthorizedImageFailureCannotOverwriteExistingPDF() throws {
        _ = NSApplication.shared
        let server = try ExportNetworkTestServer()
        defer { server.stop() }
        let dir = try directory()
        defer { ExportTestEvidence.preserveThenRemove(dir) }
        let destination = dir.appendingPathComponent("existing.pdf")
        let sentinel = Data("before-failed-image".utf8)
        try sentinel.write(to: destination)
        let result = runPDF("![broken](\(server.baseURL)/broken-\(UUID()).png)", policy: .allowRemoteImages, destination: destination)
        guard case .failure = result else { return XCTFail("failed image silently exported") }
        XCTAssertFalse(server.requests.isEmpty)
        XCTAssertEqual(try Data(contentsOf: destination), sentinel)
    }

    @MainActor
    func testUnsupportedCSSImageExpressionFailsInsteadOfClaimingReadiness() throws {
        _ = NSApplication.shared
        let server = try ExportNetworkTestServer(image: magentaPNG())
        defer { server.stop() }
        let dir = try directory()
        defer { ExportTestEvidence.preserveThenRemove(dir) }
        let token = UUID().uuidString
        let fragment = "<div id=\"css-expression\" style=\"width:100px;height:100px;background-image:image-set('\(server.baseURL)/\(token).png' 1x)\"></div>"
        let controlHTML = MarkdownRenderer().render("# CSS expression", remoteResourcePolicy: .allowRemoteImages).html
            .replacingOccurrences(of: "<main>", with: "<main>" + fragment)
        let control = dir.appendingPathComponent("css-control.html")
        try controlHTML.write(to: control, atomically: true, encoding: .utf8)
        try withFile(control) { webView in
            let serialization = try self.evaluate("getComputedStyle(document.getElementById('css-expression')).backgroundImage", in: webView) as? String
            XCTAssertTrue(serialization?.contains("image-set") == true, "positive control expression must be supported by this WebKit")
            try serialization?.write(to: dir.appendingPathComponent("computed-css.txt"), atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(server.requests.contains { $0.path.contains(token) })
        let html = MarkdownRenderer().render("# CSS expression", assetMode: .appScheme, remoteResourcePolicy: .allowRemoteImages).html
            .replacingOccurrences(of: "<main>", with: "<main>" + fragment)
        let destination = dir.appendingPathComponent("unsupported.pdf")
        let exporter = PDFExporter(destinationURL: destination)
        let done = expectation(description: "unsupported image expression")
        exporter.export(html: html, outline: [], baseURL: nil, remoteResourcePolicy: .allowRemoteImages) { result in
            if case .success = result { XCTFail("unknown image-bearing CSS silently claimed readiness") }
            done.fulfill()
        }
        wait(for: [done], timeout: 35)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    func testCanceledDelayedImageCannotPublishOrOverwriteAnExistingPDF() throws {
        _ = NSApplication.shared
        let server = try ExportNetworkTestServer()
        defer { server.stop() }
        let dir = try directory()
        defer { ExportTestEvidence.preserveThenRemove(dir) }
        let destination = dir.appendingPathComponent("existing.pdf")
        let sentinel = Data("original-pdf-sentinel".utf8)
        try sentinel.write(to: destination)
        let rendered = MarkdownRenderer().render("![slow](\(server.baseURL)/slow-\(UUID()).png)",
            assetMode: .appScheme, remoteResourcePolicy: .allowRemoteImages)
        let exporter = PDFExporter(destinationURL: destination)
        var completions = 0
        exporter.export(html: rendered.html, outline: [], baseURL: nil,
            remoteResourcePolicy: .allowRemoteImages) { result in
            completions += 1
            if case .success = result { XCTFail("canceled export succeeded") }
        }
        XCTAssertTrue(spin(5) { !server.requests.isEmpty }, "authorized delayed image positive control never began")
        XCTAssertEqual(try Data(contentsOf: destination), sentinel)
        exporter.cancel()
        exporter.cancel()
        server.releaseDelayed()
        _ = spin(0.4) { false }
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(try Data(contentsOf: destination), sentinel)
        XCTAssertEqual(server.requests.count, 1)
    }

    @MainActor
    func testUnresolvedImageHitsOriginalWholeExportDeadlineWithoutPublication() throws {
        _ = NSApplication.shared
        let server = try ExportNetworkTestServer()
        defer { server.stop() }
        let dir = try directory()
        defer { ExportTestEvidence.preserveThenRemove(dir) }
        let destination = dir.appendingPathComponent("out.pdf")
        let started = Date()
        let result = runPDF("![slow](\(server.baseURL)/slow-\(UUID()).png)", policy: .allowRemoteImages, destination: destination)
        guard case .failure = result else { return XCTFail("unresolved image silently exported") }
        XCTAssertFalse(server.requests.isEmpty)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 29)
        XCTAssertLessThan(Date().timeIntervalSince(started), 33)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    func testActualHTMLExportReopensOfflineAndMissingLocalImageCannotRevive() throws {
        _ = NSApplication.shared
        let server = try ExportNetworkTestServer()
        defer { server.stop() }
        let dir = try directory()
        defer { ExportTestEvidence.preserveThenRemove(dir) }
        let source = dir.appendingPathComponent("source.md"), destination = dir.appendingPathComponent("out.html")
        try ExportNetworkTestServer.png.write(to: dir.appendingPathComponent("local.png"))
        let markdown = """
        # Offline export

        ![local](local.png) ![remote](\(server.baseURL)/\(UUID()).png) ![missing](later.png)

        $x^2$

        ```mermaid
        graph TD; A-->B;
        ```

        ```flow
        st=>start: S
        e=>end: E
        st->e
        ```

        ```sequence
        A->B: message
        ```
        """
        try markdown.write(to: source, atomically: true, encoding: .utf8)
        let store = DocumentStore(htmlDestinationPicker: { _ in destination })
        store.open(source)
        defer { _ = store.closeDocument(discardRecovery: false) }
        let exported = expectation(description: "actual HTML export")
        Task { await store.exportHTML(); exported.fulfill() }
        wait(for: [exported], timeout: 10)
        XCTAssertTrue(server.requests.isEmpty)
        // The reader now has this path and a broad directory grant. It must
        // remain an inert explanation, not resume the original relative src.
        try ExportNetworkTestServer.png.write(to: dir.appendingPathComponent("later.png"))
        try withFile(destination) { webView in
            XCTAssertTrue(self.spin(10) { (try? self.evaluate("window.__md2DiagramsSettled === true", in: webView)) as? Bool == true })
            XCTAssertEqual(try self.evaluate("document.querySelectorAll('.diagram svg').length", in: webView) as? Int, 3)
            XCTAssertEqual(try self.evaluate("document.querySelectorAll('.katex').length", in: webView) as? Int, 1)
            XCTAssertEqual(try self.evaluate("document.images.length", in: webView) as? Int, 1)
            XCTAssertEqual(try self.evaluate("document.images[0].naturalWidth", in: webView) as? Int, 1)
            XCTAssertEqual(try self.evaluate("document.images[0].src.startsWith('data:')", in: webView) as? Bool, true)
            XCTAssertEqual(try self.evaluate("document.querySelectorAll('.md2-export-image-placeholder').length", in: webView) as? Int, 2)
        }
        XCTAssertTrue(server.requests.isEmpty)
    }

    @MainActor
    func testReopenedHTMLValidatesExistingDataAndNestedSVGResources() throws {
        _ = NSApplication.shared
        let server = try ExportNetworkTestServer()
        defer { server.stop() }
        let dir = try directory()
        defer { ExportTestEvidence.preserveThenRemove(dir) }
        let token = UUID().uuidString
        let safeSVG = #"<svg xmlns="http://www.w3.org/2000/svg" width="2" height="2"><defs><linearGradient id="g"><stop offset="0" stop-color="red"/></linearGradient></defs><rect width="2" height="2" fill="url(#g)"/></svg>"#
        let unsafeSVG = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"2\" height=\"2\"><image href=\"\(server.baseURL)/\(token).png\" width=\"2\" height=\"2\"/></svg>"
        try safeSVG.write(to: dir.appendingPathComponent("safe.svg"), atomically: true, encoding: .utf8)
        try unsafeSVG.write(to: dir.appendingPathComponent("unsafe.svg"), atomically: true, encoding: .utf8)
        let rendered = MarkdownRenderer().render("![safe](safe.svg) ![unsafe](unsafe.svg)")
        let dataImages = "<img src=\"data:image/svg+xml;base64,\(Data(unsafeSVG.utf8).base64EncodedString())\">" +
            "<img src=\"data:image/png;base64,\(ExportNetworkTestServer.png.base64EncodedString())\">"
        let output = SelfContainedHTMLBuilder.build(html: rendered.html.replacingOccurrences(of: "<main>", with: "<main>" + dataImages), baseURL: dir)
        XCTAssertEqual(Set(output.unembeddedLocalImages), ["Embedded image", "unsafe.svg"])
        let artifact = dir.appendingPathComponent("validated.html")
        try output.html.write(to: artifact, atomically: true, encoding: .utf8)
        try withFile(artifact) { webView in
            XCTAssertEqual(try self.evaluate("document.images.length", in: webView) as? Int, 2)
            XCTAssertEqual(try self.evaluate("Array.from(document.images).every(i => i.complete && i.naturalWidth > 0 && i.src.startsWith('data:'))", in: webView) as? Bool, true)
            XCTAssertEqual(try self.evaluate("document.querySelectorAll('.md2-export-image-placeholder').length", in: webView) as? Int, 2)
        }
        XCTAssertTrue(server.requests.isEmpty)
        // An inline SVG image in an otherwise identical unconstrained file is
        // a resource-capable positive control. A data-SVG image has additional
        // browser restrictions; this is not claimed as a data-SVG exploit.
        let policy = try XCTUnwrap(rendered.html.range(of: #"<meta http-equiv="Content-Security-Policy"[^>]*>"#, options: .regularExpression))
        let control = dir.appendingPathComponent("control.html")
        var controlHTML = rendered.html
        controlHTML.removeSubrange(policy)
        let mainStart = try XCTUnwrap(controlHTML.range(of: "<main>"))
        let mainEnd = try XCTUnwrap(controlHTML.range(of: "</main>"))
        controlHTML.replaceSubrange(mainStart.upperBound..<mainEnd.lowerBound, with: unsafeSVG)
        try controlHTML.write(to: control, atomically: true, encoding: .utf8)
        try withFile(control) { _ in }
        XCTAssertGreaterThan(server.requests.filter { $0.path.contains(token) }.count, 0)
    }

    @MainActor private func runPDF(_ markdown: String, policy: RemoteResourcePolicy, destination: URL,
                                 blockedLabel: String = "Remote image blocked") -> Result<Void, Error> {
        let rendered = MarkdownRenderer().render(markdown, assetMode: .appScheme, remoteResourcePolicy: policy)
        let exporter = PDFExporter(destinationURL: destination)
        let done = expectation(description: "actual PDF completion")
        var outcome: Result<Void, Error> = .failure(PDFExporter.ExportError.timedOut)
        exporter.export(html: rendered.html, outline: rendered.outline, baseURL: nil,
            remoteResourcePolicy: policy, documentTitle: "Export", remoteImageBlockedLabel: blockedLabel) { outcome = $0; done.fulfill() }
        wait(for: [done], timeout: 35)
        return outcome
    }

    @MainActor private func containsMagenta(_ url: URL) throws -> Bool {
        let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(page.thumbnail(of: CGSize(width: 600, height: 850), for: .mediaBox).tiffRepresentation)))
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent > 0.8, color.greenComponent < 0.2, color.blueComponent > 0.3, color.blueComponent < 0.7 { count += 1 }
            }
        }
        return count > 50
    }

    @MainActor private func magentaPNG() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<8 { for x in 0..<8 { bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0.5, alpha: 1), atX: x, y: y) } }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("md2-export-resources-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor private func spin(_ seconds: TimeInterval, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { if predicate() { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        return predicate()
    }

    @MainActor private func evaluate(_ script: String, in webView: WKWebView) throws -> Any? {
        let done = expectation(description: "script")
        var value: Any?, failure: Error?
        webView.evaluateJavaScript(script) { value = $0; failure = $1; done.fulfill() }
        wait(for: [done], timeout: 5)
        if let failure { throw failure }
        return value
    }

    @MainActor private func withFile(_ url: URL, body: (WKWebView) throws -> Void) throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        let delegate = ExportFileNavigation()
        webView.navigationDelegate = delegate
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderFrontRegardless()
        defer { webView.stopLoading(); window.orderOut(nil); window.contentView = nil }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        XCTAssertTrue(spin(10) { delegate.finished })
        try body(webView)
    }
}

@MainActor private final class ExportFileNavigation: NSObject, WKNavigationDelegate {
    var finished = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
}
