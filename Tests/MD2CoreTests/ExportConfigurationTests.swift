import AppKit
import Foundation
import Testing
import MD2Core
@testable import MD2App

@MainActor
struct ExportConfigurationTests {
    // MARK: - Persistence

    @Test func exportProfileDefaultsWhenUnset() {
        let defaults = UserDefaults(suiteName: "ExportConfig-default-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        #expect(settings.exportProfile == .default)
    }

    @Test func exportProfilePersistsAcrossInstances() {
        let suiteName = "ExportConfig-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = AppSettings(defaults: defaults)
        first.exportProfile = ExportProfile(
            pageSize: .letter,
            orientation: .landscape,
            margins: .custom(top: 10, left: 20, bottom: 30, right: 40),
            showsPageNumbers: true,
            pageNumberAlignment: .right,
            footer: RunningText(center: "{page} / {pageCount}")
        )

        let second = AppSettings(defaults: defaults)
        #expect(second.exportProfile == first.exportProfile)
        #expect(second.exportProfile.pageSize == .letter)
        #expect(second.exportProfile.orientation == .landscape)
        #expect(second.exportProfile.showsPageNumbers)
    }

    // MARK: - Print info matches the profile

    @Test func printInfoMatchesPortraitProfile() {
        let info = DocumentPrinter.makePrintInfo(for: ExportProfile(pageSize: .letter, orientation: .portrait))
        #expect(info.orientation == .portrait)
        #expect(abs(min(info.paperSize.width, info.paperSize.height) - 612) < 1)
        #expect(abs(max(info.paperSize.width, info.paperSize.height) - 792) < 1)
    }

    @Test func printInfoMatchesLandscapeProfile() {
        let info = DocumentPrinter.makePrintInfo(for: ExportProfile(pageSize: .letter, orientation: .landscape))
        #expect(info.orientation == .landscape)
        // Robust to whether AppKit swaps paperSize for orientation: the paper's
        // dimensions are Letter regardless of which is treated as width/height.
        #expect(abs(min(info.paperSize.width, info.paperSize.height) - 612) < 1)
        #expect(abs(max(info.paperSize.width, info.paperSize.height) - 792) < 1)
    }

    // MARK: - The active profile flows into export and print

    @Test func exportPDFAppliesProfileFromProvider() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("md2-export-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("out.pdf")

        let profile = ExportProfile(pageSize: .legal, orientation: .landscape, showsPageNumbers: true)
        var capturedProfile: ExportProfile?
        let store = DocumentStore(
            pdfDestinationPicker: { _ in destination },
            pdfExporterFactory: { _, passed in
                capturedProfile = passed
                return CapturingExporter()
            },
            exportProfileProvider: { profile }
        )

        store.exportPDF()
        #expect(capturedProfile == profile)
    }

    @Test func printAppliesProfileFromProvider() {
        let profile = ExportProfile(pageSize: .letter, showsPageNumbers: true)
        let printer = CapturingPrinter()
        let store = DocumentStore(
            documentPrinterFactory: { printer },
            exportProfileProvider: { profile }
        )

        store.print()
        #expect(printer.capturedProfile == profile)
    }
}

@MainActor
private final class CapturingExporter: PDFExporting {
    func export(
        html: String,
        outline: [Heading],
        baseURL: URL?,
        documentTitle: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        completion(.success(()))
    }
}

@MainActor
private final class CapturingPrinter: DocumentPrinting {
    private(set) var capturedProfile: ExportProfile?

    func print(
        html: String,
        outline: [Heading],
        baseURL: URL?,
        profile: ExportProfile,
        documentTitle: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        capturedProfile = profile
        completion(.success(()))
    }
}
