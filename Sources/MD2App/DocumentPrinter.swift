import AppKit
import Foundation
import MD2Core
import PDFKit

/// Prints a document's rendered preview by reusing the proven export pipeline:
/// it renders the same HTML to a temporary PDF with `PDFExporter`, then hands
/// that PDF to PDFKit's standard print operation. Driving `NSPrintOperation`
/// directly off an offscreen `WKWebView` produced structurally invalid output
/// (see `PDFExporter`), so printing goes through the already-paginated PDF
/// instead — which also keeps print output identical to PDF export.
@MainActor
final class DocumentPrinter: DocumentPrinting {
    enum PrintError: LocalizedError {
        case preparationFailed

        var errorDescription: String? {
            switch self {
            case .preparationFailed:
                return "The document could not be prepared for printing."
            }
        }
    }

    private let exporterFactory: @MainActor (URL, ExportProfile) -> PDFExporting
    /// Retains the exporter for its asynchronous lifetime; cleared on completion.
    private var exporter: PDFExporting?
    private var temporaryPDFURL: URL?

    init(
        exporterFactory: @escaping @MainActor (URL, ExportProfile) -> PDFExporting = { PDFExporter(destinationURL: $0, profile: $1) }
    ) {
        self.exporterFactory = exporterFactory
    }

    func print(
        html: String,
        outline: [Heading],
        baseURL: URL?,
        profile: ExportProfile,
        documentTitle: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        // Render to a temp PDF in the system temp directory: untitled documents
        // have no document directory, and the preview's stale-file sweep only
        // reclaims `.md2-preview-*.html`, so this PDF is cleaned up explicitly.
        let pdfURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("md2-print-\(UUID().uuidString).pdf")
        temporaryPDFURL = pdfURL

        let exporter = exporterFactory(pdfURL, profile)
        self.exporter = exporter
        exporter.export(
            html: html,
            outline: outline,
            baseURL: baseURL,
            documentTitle: documentTitle
        ) { [weak self] result in
            guard let self else { return }
            self.exporter = nil
            switch result {
            case let .failure(error):
                self.cleanUpTemporaryPDF()
                completion(.failure(error))
            case .success:
                let printResult = self.runPrintOperation(pdfURL: pdfURL, profile: profile)
                self.cleanUpTemporaryPDF()
                completion(printResult)
            }
        }
    }

    /// Loads the rendered PDF and runs PDFKit's standard print operation, which
    /// presents the system print dialog (printer, copies, page range) and
    /// paginates natively. The print info is pre-configured to the profile's page
    /// size and orientation so the panel opens matching the exported PDF geometry —
    /// not the system default paper — avoiding a surprising mismatch and a wasteful
    /// scale-down; `pageScaleDownToFit` still guards against a smaller chosen paper.
    private func runPrintOperation(pdfURL: URL, profile: ExportProfile) -> Result<Void, Error> {
        guard let document = PDFDocument(url: pdfURL) else {
            return .failure(PrintError.preparationFailed)
        }

        guard let operation = document.printOperation(
            for: Self.makePrintInfo(for: profile),
            scalingMode: .pageScaleDownToFit,
            autoRotate: true
        ) else {
            return .failure(PrintError.preparationFailed)
        }

        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
        return .success(())
    }

    /// Builds an `NSPrintInfo` pre-configured to the profile's page size and
    /// orientation, copied from the shared info so global print state is untouched.
    /// `paperSize` is set to the page's portrait dimensions and `orientation`
    /// applies landscape, so the print panel reflects the configured paper.
    static func makePrintInfo(for profile: ExportProfile, base: NSPrintInfo = .shared) -> NSPrintInfo {
        let info = (base.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.paperSize = profile.pageSize.portraitPoints
        info.orientation = profile.orientation == .landscape ? .landscape : .portrait
        return info
    }

    private func cleanUpTemporaryPDF() {
        if let temporaryPDFURL {
            try? FileManager.default.removeItem(at: temporaryPDFURL)
            self.temporaryPDFURL = nil
        }
    }
}
