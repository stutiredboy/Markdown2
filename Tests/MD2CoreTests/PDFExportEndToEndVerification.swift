import AppKit
import CoreGraphics
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
        for i in 0..<120 { markdown += "Paragraph \(i): the quick brown fox jumps over the lazy dog.\n\n" }

        let rendered = MarkdownRenderer().render(markdown)
        let destination = dir.appendingPathComponent("out.pdf")

        let exporter = PDFExporter(destinationURL: destination)
        let done = expectation(description: "export completes")
        var outcome: Result<Void, Error>?
        exporter.export(html: rendered.html, baseURL: dir) { result in
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

        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".md2-preview-") }, "temp render file not cleaned up")

        print("E2E-RESULT pages=\(document?.numberOfPages ?? -1) bytes=\(size)")
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
        exporter.export(html: rendered.html, baseURL: sourceURL.deletingLastPathComponent()) { result in
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
}
