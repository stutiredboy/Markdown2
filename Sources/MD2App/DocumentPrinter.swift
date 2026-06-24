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

    private let exporterFactory: @MainActor (URL) -> PDFExporting
    /// Retains the exporter for its asynchronous lifetime; cleared on completion.
    private var exporter: PDFExporting?
    private var temporaryPDFURL: URL?

    init(
        exporterFactory: @escaping @MainActor (URL) -> PDFExporting = { PDFExporter(destinationURL: $0) }
    ) {
        self.exporterFactory = exporterFactory
    }

    func print(
        html: String,
        outline: [Heading],
        baseURL: URL?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        // Render to a temp PDF in the system temp directory: untitled documents
        // have no document directory, and the preview's stale-file sweep only
        // reclaims `.md2-preview-*.html`, so this PDF is cleaned up explicitly.
        let pdfURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("md2-print-\(UUID().uuidString).pdf")
        temporaryPDFURL = pdfURL

        let exporter = exporterFactory(pdfURL)
        self.exporter = exporter
        exporter.export(html: html, outline: outline, baseURL: baseURL) { [weak self] result in
            guard let self else { return }
            self.exporter = nil
            switch result {
            case let .failure(error):
                self.cleanUpTemporaryPDF()
                completion(.failure(error))
            case .success:
                let printResult = self.runPrintOperation(pdfURL: pdfURL)
                self.cleanUpTemporaryPDF()
                completion(printResult)
            }
        }
    }

    /// Loads the rendered PDF and runs PDFKit's standard print operation, which
    /// presents the system print dialog (printer, copies, page range) and
    /// paginates natively. Page content is A4 already; `pageScaleDownToFit`
    /// scales down only if the chosen paper is smaller, avoiding clipping.
    private func runPrintOperation(pdfURL: URL) -> Result<Void, Error> {
        guard let document = PDFDocument(url: pdfURL) else {
            return .failure(PrintError.preparationFailed)
        }

        guard let operation = document.printOperation(
            for: NSPrintInfo.shared,
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

    private func cleanUpTemporaryPDF() {
        if let temporaryPDFURL {
            try? FileManager.default.removeItem(at: temporaryPDFURL)
            self.temporaryPDFURL = nil
        }
    }
}
