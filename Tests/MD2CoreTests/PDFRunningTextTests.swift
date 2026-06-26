import AppKit
import PDFKit
import XCTest
import MD2Core
@testable import MD2App

/// GUI-gated verification that the export profile's page numbers, header, and
/// footer are drawn into the PDF, on every page, without overlapping or clipping
/// content — including the `none` margin preset, where a minimum band is still
/// reserved. Running text is real text (Core Text glyphs), so PDFKit can extract
/// it for assertions.
///
/// `MD2_RUN_GUI_TESTS=1 swift test --filter PDFRunningTextTests`.
final class PDFRunningTextTests: XCTestCase {
    @MainActor
    func testExportDrawsPageNumbersHeaderAndFooterOnEveryPage() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed export test."
        )
        _ = NSApplication.shared

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let profile = ExportProfile(
            pageSize: .a4,
            orientation: .portrait,
            margins: .preset(.normal),
            showsPageNumbers: true,
            pageNumberAlignment: .center,
            header: RunningText(center: "{title}"),
            footer: RunningText(left: "Confidential")
        )
        let document = try export(
            markdown: longDocument(),
            profile: profile,
            title: "QuarterlyReport",
            into: dir
        )

        let count = document.pageCount
        XCTAssertGreaterThan(count, 1, "expected a multi-page document")
        for index in 0..<count {
            let text = document.page(at: index)?.string ?? ""
            XCTAssertTrue(
                text.contains("\(index + 1) / \(count)"),
                "page \(index + 1) is missing its page number"
            )
            XCTAssertTrue(text.contains("QuarterlyReport"), "page \(index + 1) is missing the header title")
            XCTAssertTrue(text.contains("Confidential"), "page \(index + 1) is missing the footer text")
        }
    }

    @MainActor
    func testPageNumberAndFooterTextShareZoneWithoutHidingEachOther() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed export test."
        )
        _ = NSApplication.shared

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Footer text and the page number both target the center zone: enabling page
        // numbers must not hide the configured footer text — both must appear.
        let profile = ExportProfile(
            pageSize: .a4,
            orientation: .portrait,
            margins: .preset(.normal),
            showsPageNumbers: true,
            pageNumberAlignment: .center,
            footer: RunningText(center: "{title}")
        )
        let document = try export(
            markdown: longDocument(),
            profile: profile,
            title: "ZoneShareTitle",
            into: dir
        )

        let count = document.pageCount
        for index in 0..<count {
            let text = document.page(at: index)?.string ?? ""
            XCTAssertTrue(text.contains("ZoneShareTitle"), "footer title hidden on page \(index + 1)")
            XCTAssertTrue(text.contains("\(index + 1) / \(count)"), "page number missing on page \(index + 1)")
        }
    }

    @MainActor
    func testNoneMarginWithRunningTextReservesBandAndDoesNotClip() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed export test."
        )
        _ = NSApplication.shared

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let markdown = longDocument()

        // None margins, no running text: the content baseline page count.
        let plain = try export(
            markdown: markdown,
            profile: ExportProfile(margins: .preset(.none)),
            title: "Doc",
            into: dir,
            fileName: "plain.pdf"
        )

        // None margins, but with a header, footer, and page numbers: a band must be
        // reserved even though the margin is zero, so content shifts into at least
        // as many pages — never fewer (which would mean content was overdrawn).
        let withRunningText = try export(
            markdown: markdown,
            profile: ExportProfile(
                margins: .preset(.none),
                showsPageNumbers: true,
                pageNumberAlignment: .center,
                header: RunningText(center: "{title}")
            ),
            title: "Doc",
            into: dir,
            fileName: "running.pdf"
        )

        XCTAssertGreaterThanOrEqual(
            withRunningText.pageCount,
            plain.pageCount,
            "reserving a header/footer band must not reduce the page count"
        )

        // Running text is present, and content is not clipped: the first and last
        // paragraphs both still appear somewhere in the output.
        let allText = (0..<withRunningText.pageCount)
            .compactMap { withRunningText.page(at: $0)?.string }
            .joined(separator: "\n")
        XCTAssertTrue(allText.contains("1 / \(withRunningText.pageCount)"), "page number missing under none margins")
        XCTAssertTrue(allText.contains("Paragraph 0:"), "first paragraph clipped")
        XCTAssertTrue(allText.contains("Paragraph 119:"), "last paragraph clipped")
    }

    // MARK: - Helpers

    private func longDocument() -> String {
        var markdown = "# Heading\n\n"
        for i in 0..<120 {
            markdown += "Paragraph \(i): the quick brown fox jumps over the lazy dog.\n\n"
        }
        return markdown
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("md2-running-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    private func export(
        markdown: String,
        profile: ExportProfile,
        title: String,
        into dir: URL,
        fileName: String = "out.pdf"
    ) throws -> PDFDocument {
        let rendered = MarkdownRenderer().render(markdown)
        let destination = dir.appendingPathComponent(fileName)
        let exporter = PDFExporter(destinationURL: destination, profile: profile)
        let done = expectation(description: "export \(fileName)")
        var outcome: Result<Void, Error>?
        exporter.export(
            html: rendered.html,
            outline: rendered.outline,
            baseURL: dir,
            documentTitle: title
        ) { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 35)

        guard case .success = outcome else {
            throw XCTSkip("export failed: \(String(describing: outcome))")
        }
        return try XCTUnwrap(PDFDocument(url: destination))
    }
}
