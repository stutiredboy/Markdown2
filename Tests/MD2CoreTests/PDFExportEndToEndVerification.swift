import AppKit
import CoreGraphics
import PDFKit
import XCTest
import MD2Core
@testable import MD2App

/// End-to-end verification for the save-as-pdf change. Drives the real
/// PDFExporter (offscreen web view + createPDF + paginator) over rendered Markdown
/// containing a heading, KaTeX math, a Mermaid diagram, a fenced code block, and a
/// relative image. Uses `waitForExpectations` so the main run loop is pumped
/// (unlike an async test).
///
/// Requires a GUI session (WebKit), so it is opt-in to stay CI-safe: run with
/// `MD2_RUN_GUI_TESTS=1 swift test --filter PDFExportEndToEndVerification`.
final class PDFExportEndToEndVerification: XCTestCase {
    @MainActor
    func testRealExportProducesValidMultiPagePDF() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed export test."
        )
        _ = NSApplication.shared // ensure an app object exists for WebKit

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("md2-e2e-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
        try! png.write(to: dir.appendingPathComponent("img.png"))

        var markdown = "# Heading One\n\n"
        markdown += "Inline math $E = mc^2$ and a display equation:\n\n$$\\int_0^1 x^2\\,dx$$\n\n"
        markdown += "```swift\nlet x = 1\nprint(x)\n```\n\n"
        markdown += "![a picture](img.png)\n\n"
        markdown += "```mermaid\ngraph TD; A-->B; B-->C;\n```\n\n"
        for i in 0..<40 { markdown += "Paragraph \(i): the quick brown fox jumps over the lazy dog.\n\n" }
        markdown += "## Section Two\n\n"
        for i in 40..<80 { markdown += "Paragraph \(i): the quick brown fox jumps over the lazy dog.\n\n" }
        markdown += "### Details\n\n"
        for i in 80..<100 { markdown += "Paragraph \(i): the quick brown fox jumps over the lazy dog.\n\n" }
        markdown += "# Heading Last\n\n"
        for i in 100..<140 { markdown += "Paragraph \(i): the quick brown fox jumps over the lazy dog.\n\n" }

        let rendered = MarkdownRenderer().render(markdown)
        let destination = dir.appendingPathComponent("out.pdf")

        let exporter = PDFExporter(destinationURL: destination)
        let done = expectation(description: "export completes")
        var outcome: Result<Void, Error>?
        exporter.export(html: rendered.html, outline: rendered.outline, baseURL: dir) { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 35)

        guard case .success = outcome else {
            XCTFail("export failed: \(String(describing: outcome))")
            return
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let size = ((try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int) ?? 0
        XCTAssertLessThan(size, 50_000_000, "PDF unexpectedly huge")

        let document = CGDataProvider(url: destination as CFURL).flatMap(CGPDFDocument.init)
        XCTAssertNotNil(document)
        XCTAssertGreaterThan(document?.numberOfPages ?? 0, 1)

        // The document headings must yield a nested PDF outline (bookmarks).
        let outlineDoc = PDFDocument(url: destination)
        let root = outlineDoc?.outlineRoot
        XCTAssertNotNil(root, "exported PDF has no outline")
        XCTAssertEqual(outlineLabels(root), ["Heading One", "Section Two", "Details", "Heading Last"])
        let first = root?.child(at: 0)
        XCTAssertEqual(first?.label, "Heading One")
        XCTAssertEqual(first?.child(at: 0)?.label, "Section Two")
        XCTAssertEqual(first?.child(at: 0)?.child(at: 0)?.label, "Details")
        XCTAssertEqual(root?.child(at: 1)?.label, "Heading Last")

        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".md2-preview-") }, "temp render file not cleaned up")

        print("E2E-RESULT pages=\(document?.numberOfPages ?? -1) bytes=\(size)")
    }

    @MainActor
    func testRealExportWithoutHeadingsProducesValidPDFWithoutOutline() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed export test."
        )
        _ = NSApplication.shared

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("md2-e2e-no-headings-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var markdown = "Plain opening paragraph with no Markdown heading.\n\n"
        for i in 0..<20 { markdown += "Body paragraph \(i) stays navigable only by pages.\n\n" }

        let rendered = MarkdownRenderer().render(markdown)
        XCTAssertTrue(rendered.outline.isEmpty)

        let destination = dir.appendingPathComponent("plain.pdf")
        let exporter = PDFExporter(destinationURL: destination)
        let done = expectation(description: "export without headings completes")
        var outcome: Result<Void, Error>?
        exporter.export(html: rendered.html, outline: rendered.outline, baseURL: dir) { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 35)

        guard case .success = outcome else {
            XCTFail("export failed: \(String(describing: outcome))")
            return
        }

        let document = PDFDocument(url: destination)
        XCTAssertNotNil(document)
        XCTAssertGreaterThan(document?.pageCount ?? 0, 0)
        XCTAssertTrue(outlineLabels(document?.outlineRoot).isEmpty)
    }

    @MainActor
    func testExportProvidedMarkdownPath() throws {
        guard let sourcePath = ProcessInfo.processInfo.environment["MD2_VERIFY_PDF_SOURCE"],
              let outputPath = ProcessInfo.processInfo.environment["MD2_VERIFY_PDF_OUTPUT"] else {
            throw XCTSkip("Set MD2_VERIFY_PDF_SOURCE and MD2_VERIFY_PDF_OUTPUT to export a local Markdown fixture.")
        }
        _ = NSApplication.shared

        let sourceURL = URL(fileURLWithPath: sourcePath)
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let markdown = try String(contentsOf: sourceURL, encoding: .utf8)
        let rendered = MarkdownRenderer().render(markdown)

        let exporter = PDFExporter(destinationURL: outputURL)
        let done = expectation(description: "export provided markdown")
        var outcome: Result<Void, Error>?
        exporter.export(html: rendered.html, outline: rendered.outline, baseURL: sourceURL.deletingLastPathComponent()) { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 35)

        guard case .success = outcome else {
            XCTFail("export failed: \(String(describing: outcome))")
            return
        }

        let document = CGDataProvider(url: outputURL as CFURL).flatMap(CGPDFDocument.init)
        XCTAssertNotNil(document)
        XCTAssertGreaterThan(document?.numberOfPages ?? 0, 1)
        print("VERIFY-RESULT path=\(outputURL.path) pages=\(document?.numberOfPages ?? -1)")
    }

    @MainActor
    func testExportHonorsConfiguredPageSizeAndOrientation() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed export test."
        )
        _ = NSApplication.shared

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("md2-e2e-geometry-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var markdown = "# Configured Geometry\n\n"
        for i in 0..<12 { markdown += "Paragraph \(i): the quick brown fox jumps over the lazy dog.\n\n" }
        let rendered = MarkdownRenderer().render(markdown)

        let destination = dir.appendingPathComponent("letter-landscape.pdf")
        let profile = ExportProfile(
            pageSize: .letter,
            orientation: .landscape,
            margins: .preset(.normal)
        )
        let exporter = PDFExporter(destinationURL: destination, profile: profile)
        let done = expectation(description: "configured-geometry export completes")
        var outcome: Result<Void, Error>?
        exporter.export(html: rendered.html, outline: rendered.outline, baseURL: dir) { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 35)

        guard case .success = outcome else {
            XCTFail("export failed: \(String(describing: outcome))")
            return
        }

        let document = try XCTUnwrap(PDFDocument(url: destination))
        let page = try XCTUnwrap(document.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)
        // Letter landscape is 11 × 8.5 in = 792 × 612 pt.
        XCTAssertEqual(bounds.width, 792, accuracy: 1, "page width should be landscape Letter")
        XCTAssertEqual(bounds.height, 612, accuracy: 1, "page height should be landscape Letter")
        XCTAssertGreaterThan(bounds.width, bounds.height, "landscape pages are wider than tall")
    }

    @MainActor
    func testExportedPDFPageIsLightAndNonEmpty() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed export test."
        )
        _ = NSApplication.shared

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qa-pdf-light-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A small Mermaid doc + body text so the diagram lands on page 1.
        var md = "# Light PDF QA\n\n```mermaid\ngraph TD; A-->B; B-->C;\n```\n\n"
        for i in 0..<40 { md += "Paragraph \(i): the quick brown fox jumps over the lazy dog.\n\n" }
        let rendered = MarkdownRenderer().render(md)
        let dest = dir.appendingPathComponent("light.pdf")

        let exporter = PDFExporter(destinationURL: dest)
        let done = expectation(description: "light-PDF export completes")
        var outcome: Result<Void, Error>?
        exporter.export(html: rendered.html, outline: rendered.outline, baseURL: nil) { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 35)
        guard case .success = outcome else {
            XCTFail("export failed: \(String(describing: outcome))")
            return
        }

        // Rasterize page 1 — the only test reaching the createPDF + compose OUTPUT
        // pixels (the DOM-probe tests verify the webview, not the delivered PDF).
        guard let bitmap = rasterizeFirstPage(of: dest, scale: 1.5) else {
            XCTFail("could not rasterize exported page 1")
            return
        }
        // A margin corner must be light: PDFExporter's forced-light appearance must
        // reach the delivered PDF, not just the DOM. Catches a dark-inversion regression.
        XCTAssertTrue(
            isLight(bitmap.colorAt(x: 2, y: 2)),
            "exported page 1 background is dark/inverted — PDFExporter's forced-light did not reach the PDF output"
        )
        // The page must contain dark content (text/diagram strokes) — createPDF
        // captured something, not a blank page.
        let darkPixels = countDarkPixels(in: bitmap)
        XCTAssertGreaterThan(darkPixels, 50, "exported page 1 is blank — createPDF captured no content (darkPixels=\(darkPixels))")
        print("QA-T5 light bg + \(darkPixels) dark content pixels")
    }

    // MARK: Untitled-document image embedding (fix-pdf-untitled-image-export)

    /// An untitled document (no `baseURL`) must still embed an absolute-path
    /// image in the exported PDF. Before the fix, `PDFExporter.export`
    /// short-circuited image rewriting when `baseURL` was nil, so the
    /// `md2-local-image://` scheme was never wired and the image was blank.
    /// The assertion counts the image's *distinctive color* (not generic dark
    /// pixels) so body text — black on white — cannot satisfy it: the closed
    /// form that does not false-pass.
    @MainActor
    func testUntitledExportEmbedsAbsolutePathImage() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed export test."
        )
        _ = NSApplication.shared

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("md2-untitled-abs-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let png = makeSolidColorPNG(width: 200, height: 200, color: NSColor(red: 1, green: 0, blue: 0, alpha: 1))
        let imgPath = dir.appendingPathComponent("red.png")
        try png.write(to: imgPath)

        var md = "# Untitled Image Export\n\n"
        md += "![red](\(imgPath.path))\n\n"
        for i in 0..<20 { md += "Paragraph \(i): filler text so the page has body.\n\n" }
        let rendered = MarkdownRenderer().render(md)

        let dest = dir.appendingPathComponent("untitled-abs.pdf")
        let exporter = PDFExporter(destinationURL: dest)
        let done = expectation(description: "untitled absolute-image export completes")
        var outcome: Result<Void, Error>?
        exporter.export(html: rendered.html, outline: rendered.outline, baseURL: nil) { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 35)
        guard case .success = outcome else {
            XCTFail("export failed: \(String(describing: outcome))")
            return
        }

        guard let bitmap = rasterizeFirstPage(of: dest, scale: 1.5) else {
            XCTFail("could not rasterize exported page 1")
            return
        }
        let red = countColorPixels(in: bitmap, r: 1, g: 0, b: 0)
        XCTAssertGreaterThan(
            red, 500,
            "absolute-path image did not render in an untitled document's export (red pixels=\(red))"
        )
        print("UNTITLED-ABS red pixels=\(red)")
    }

    /// A `file://` image reference in an untitled document must also embed. The
    /// rewriter's `file://` branch (`LocalImageAccess.swift`) is a distinct code
    /// path from the absolute-path branch, so it is asserted separately — the
    /// spec requires this scenario.
    @MainActor
    func testUntitledExportEmbedsFileURLImage() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed export test."
        )
        _ = NSApplication.shared

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("md2-untitled-file-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let png = makeSolidColorPNG(width: 200, height: 200, color: NSColor(red: 0, green: 0, blue: 1, alpha: 1))
        let imgPath = dir.appendingPathComponent("blue.png")
        try png.write(to: imgPath)

        var md = "# Untitled File URL Image\n\n"
        md += "![blue](\(URL(fileURLWithPath: imgPath.path).absoluteString))\n\n"
        for i in 0..<20 { md += "Paragraph \(i): filler text so the page has body.\n\n" }
        let rendered = MarkdownRenderer().render(md)

        let dest = dir.appendingPathComponent("untitled-file.pdf")
        let exporter = PDFExporter(destinationURL: dest)
        let done = expectation(description: "untitled file-URL image export completes")
        var outcome: Result<Void, Error>?
        exporter.export(html: rendered.html, outline: rendered.outline, baseURL: nil) { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 35)
        guard case .success = outcome else {
            XCTFail("export failed: \(String(describing: outcome))")
            return
        }

        guard let bitmap = rasterizeFirstPage(of: dest, scale: 1.5) else {
            XCTFail("could not rasterize exported page 1")
            return
        }
        let blue = countColorPixels(in: bitmap, r: 0, g: 0, b: 1)
        XCTAssertGreaterThan(
            blue, 500,
            "file:// image did not render in an untitled document's export (blue pixels=\(blue))"
        )
        print("UNTITLED-FILE blue pixels=\(blue)")
    }

    /// A file-backed document (with a `baseURL`) must still embed images after
    /// the export load-decision is realigned — guards the temp-file +
    /// `loadFileRequest` path against regression.
    @MainActor
    func testFileBackedExportStillEmbedsImage() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed export test."
        )
        _ = NSApplication.shared

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("md2-filebacked-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let png = makeSolidColorPNG(width: 200, height: 200, color: NSColor(red: 0, green: 1, blue: 0, alpha: 1))
        let imgPath = dir.appendingPathComponent("green.png")
        try png.write(to: imgPath)

        var md = "# File-Backed Image Export\n\n"
        md += "![green](\(imgPath.path))\n\n"
        for i in 0..<20 { md += "Paragraph \(i): filler text so the page has body.\n\n" }
        let rendered = MarkdownRenderer().render(md)

        let dest = dir.appendingPathComponent("filebacked.pdf")
        let exporter = PDFExporter(destinationURL: dest)
        let done = expectation(description: "file-backed image export completes")
        var outcome: Result<Void, Error>?
        exporter.export(html: rendered.html, outline: rendered.outline, baseURL: dir) { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 35)
        guard case .success = outcome else {
            XCTFail("export failed: \(String(describing: outcome))")
            return
        }

        guard let bitmap = rasterizeFirstPage(of: dest, scale: 1.5) else {
            XCTFail("could not rasterize exported page 1")
            return
        }
        let green = countColorPixels(in: bitmap, r: 0, g: 1, b: 0)
        XCTAssertGreaterThan(
            green, 500,
            "image did not render in a file-backed document's export (green pixels=\(green))"
        )
        print("FILEBACKED green pixels=\(green)")
    }

    @MainActor
    func testMermaidDiagramRendersInExportedPDF() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed export test."
        )
        _ = NSApplication.shared

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("md2-mermaid-pdf-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A dark-styled subgraph: a blank diagram (the regression this guards)
        // leaves only the heading's ~a few hundred dark pixels, while the rendered
        // subgraph adds a large dark fill + strokes.
        let markdown = """
        # Diagram

        ```mermaid
        graph TD
          subgraph AppLayer [应用层 App Layer]
            A[服务 A] --> B[服务 B] --> C[业务逻辑]
          end
          style AppLayer fill:#1e293b,stroke:#38bdf8,color:#ffffff
        ```
        """
        let rendered = MarkdownRenderer().render(markdown)
        let dest = dir.appendingPathComponent("diagram.pdf")

        let exporter = PDFExporter(destinationURL: dest)
        let done = expectation(description: "mermaid-PDF export completes")
        var outcome: Result<Void, Error>?
        exporter.export(html: rendered.html, outline: rendered.outline, baseURL: dir) { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 35)
        guard case .success = outcome else {
            XCTFail("export failed: \(String(describing: outcome))")
            return
        }

        guard let bitmap = rasterizeFirstPage(of: dest, scale: 2.0) else {
            XCTFail("could not rasterize exported page 1")
            return
        }
        let dark = countDarkPixels(in: bitmap)
        XCTAssertGreaterThan(
            dark, 200,
            "mermaid diagram did not render in the exported PDF (darkPixels=\(dark))"
        )
        print("MERMAID-PDF darkPixels=\(dark)")
    }

    /// Rasterize page 1 of the PDF at `url` into a bitmap (createPDF output, not DOM).
    private func rasterizeFirstPage(of url: URL, scale: CGFloat) -> NSBitmapImageRep? {
        guard let pdfDoc = CGDataProvider(url: url as CFURL).flatMap(CGPDFDocument.init),
              let page = pdfDoc.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard w > 0, h > 0,
              let ctx = CGContext(
                  data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.drawPDFPage(page)
        guard let cgImage = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
    }

    private func isLight(_ color: NSColor?) -> Bool {
        guard let c = color?.usingColorSpace(.deviceRGB) else { return false }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: nil)
        return (r + g + b) / 3 >= 0.7
    }

    /// Count dark pixels on a coarse grid (text/diagram strokes); fast enough for a test.
    private func countDarkPixels(in rep: NSBitmapImageRep) -> Int {
        var dark = 0
        let stepX = max(1, rep.pixelsWide / 60)
        let stepY = max(1, rep.pixelsHigh / 80)
        var y = 0
        while y < rep.pixelsHigh {
            var x = 0
            while x < rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
                    c.getRed(&r, green: &g, blue: &b, alpha: nil)
                    if (r + g + b) / 3 < 0.5 { dark += 1 }
                }
                x += stepX
            }
            y += stepY
        }
        return dark
    }

    /// Builds a solid-color PNG of the given size for image-render assertions.
    /// Use a distinctive (non-gray) color so body text — black on white —
    /// cannot satisfy a color-match assertion.
    private func makeSolidColorPNG(width: Int, height: Int, color: NSColor) -> Data {
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("could not create bitmap context for test image")
        }
        ctx.setFillColor((color.usingColorSpace(.deviceRGB) ?? color).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = ctx.makeImage() else {
            fatalError("could not create image for test fixture")
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            fatalError("could not encode solid-color PNG for test image")
        }
        return png
    }

    /// Counts pixels matching the target RGB within `tolerance` on a coarse
    /// grid. Color-specific, not dark-pixel-generic: counting a distinctive
    /// color means body text cannot inflate the count, so a blank-image
    /// regression fails the assertion instead of passing on text.
    private func countColorPixels(
        in rep: NSBitmapImageRep,
        r: CGFloat, g: CGFloat, b: CGFloat,
        tolerance: CGFloat = 0.2
    ) -> Int {
        var match = 0
        let stepX = max(1, rep.pixelsWide / 120)
        let stepY = max(1, rep.pixelsHigh / 160)
        var y = 0
        while y < rep.pixelsHigh {
            var x = 0
            while x < rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0
                    c.getRed(&cr, green: &cg, blue: &cb, alpha: nil)
                    if abs(cr - r) <= tolerance && abs(cg - g) <= tolerance && abs(cb - b) <= tolerance {
                        match += 1
                    }
                }
                x += stepX
            }
            y += stepY
        }
        return match
    }

    private func outlineLabels(_ root: PDFOutline?) -> [String] {
        guard let root else { return [] }
        var labels: [String] = []

        func walk(_ node: PDFOutline) {
            for index in 0..<node.numberOfChildren {
                guard let child = node.child(at: index) else { continue }
                if let label = child.label {
                    labels.append(label)
                }
                walk(child)
            }
        }

        walk(root)
        return labels
    }

}
