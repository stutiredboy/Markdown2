import Foundation
import Testing
import MD2Core
@testable import MD2App

@MainActor
struct DocumentConversionFlowTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("md2-convert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func exportDOCXShowsGuidanceWhenPandocUnavailable() {
        let converter = FakeConverter()
        var pickedDestination = false
        let store = DocumentStore(
            documentConverterFactory: { converter },
            pandocAvailabilityProvider: { false },
            conversionDestinationPicker: { _, _ in pickedDestination = true; return nil }
        )

        store.exportDOCX()

        #expect(store.alert != nil)
        #expect(converter.callCount == 0)
        #expect(pickedDestination == false)
    }

    @Test func exportDOCXAbortsWhenUntitledSaveCancelled() {
        let converter = FakeConverter()
        var pickedDestination = false
        // A fresh store is untitled (no fileURL); a nil save location is a cancel.
        let store = DocumentStore(
            documentConverterFactory: { converter },
            pandocAvailabilityProvider: { true },
            conversionDestinationPicker: { _, _ in pickedDestination = true; return nil },
            saveLocationPicker: { _ in nil }
        )

        store.exportDOCX()

        #expect(converter.callCount == 0)
        #expect(pickedDestination == false)
        #expect(store.fileURL == nil)
    }

    @Test func exportDOCXConvertsTitledDocumentWithCurrentText() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = dir.appendingPathComponent("notes.md")
        try "# Original\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let destination = dir.appendingPathComponent("notes.docx")

        let converter = FakeConverter()
        let store = DocumentStore(
            documentConverterFactory: { converter },
            pandocAvailabilityProvider: { true },
            conversionDestinationPicker: { _, _ in destination }
        )
        store.open(sourceURL)
        store.text = "# Edited\n\nUnsaved changes."

        let fileURLBefore = store.fileURL
        let dirtyBefore = store.isDirty
        store.exportDOCX()

        #expect(converter.callCount == 1)
        #expect(converter.capturedFormat == .docx)
        // Conversion uses the document's current (edited) Markdown, not the file.
        #expect(converter.capturedMarkdown == "# Edited\n\nUnsaved changes.")
        #expect(converter.capturedResourceDirectory == store.baseURL)
        #expect(converter.capturedDestination == destination)
        // Derived artifact: document state is untouched.
        #expect(store.fileURL == fileURLBefore)
        #expect(store.isDirty == dirtyBefore)
        #expect(store.alert == nil)
    }

    @Test func exportEPUBUsesEpubFormat() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = dir.appendingPathComponent("notes.md")
        try "# Doc\n".write(to: sourceURL, atomically: true, encoding: .utf8)

        let converter = FakeConverter()
        let store = DocumentStore(
            documentConverterFactory: { converter },
            pandocAvailabilityProvider: { true },
            conversionDestinationPicker: { _, _ in dir.appendingPathComponent("notes.epub") }
        )
        store.open(sourceURL)

        store.exportEPUB()
        #expect(converter.capturedFormat == .epub)
    }

    @Test func conversionFailureSurfacesAlert() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = dir.appendingPathComponent("notes.md")
        try "# Doc\n".write(to: sourceURL, atomically: true, encoding: .utf8)

        let converter = FakeConverter(immediateResult: .failure(PandocConverter.ConversionError.conversionFailed("boom")))
        let store = DocumentStore(
            documentConverterFactory: { converter },
            pandocAvailabilityProvider: { true },
            conversionDestinationPicker: { _, _ in dir.appendingPathComponent("notes.docx") }
        )
        store.open(sourceURL)

        store.exportDOCX()
        #expect(store.alert != nil)
    }

    @Test func conversionInFlightBlocksOtherExports() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = dir.appendingPathComponent("notes.md")
        try "# Doc\n".write(to: sourceURL, atomically: true, encoding: .utf8)

        let converter = FakeConverter(completesImmediately: false)
        var pdfPicked = false
        var htmlPicked = false
        let store = DocumentStore(
            pdfDestinationPicker: { _ in pdfPicked = true; return nil },
            htmlDestinationPicker: { _ in htmlPicked = true; return nil },
            documentConverterFactory: { converter },
            pandocAvailabilityProvider: { true },
            conversionDestinationPicker: { _, _ in dir.appendingPathComponent("notes.docx") }
        )
        store.open(sourceURL)

        store.exportDOCX() // starts and stays in flight (deferred)
        #expect(converter.callCount == 1)

        // Other export commands are ignored while a conversion is in flight.
        store.exportPDF()
        store.exportHTML()
        store.exportDOCX()
        #expect(pdfPicked == false)
        #expect(htmlPicked == false)
        #expect(converter.callCount == 1)

        converter.finish(.success(()))
        #expect(store.alert == nil)
    }
}

@MainActor
private final class FakeConverter: DocumentConverting {
    private(set) var callCount = 0
    private(set) var capturedMarkdown: String?
    private(set) var capturedFormat: DocumentExportFormat?
    private(set) var capturedResourceDirectory: URL?
    private(set) var capturedDestination: URL?

    private let completesImmediately: Bool
    private let immediateResult: Result<Void, Error>
    private var pending: ((Result<Void, Error>) -> Void)?

    init(completesImmediately: Bool = true, immediateResult: Result<Void, Error> = .success(())) {
        self.completesImmediately = completesImmediately
        self.immediateResult = immediateResult
    }

    func convert(
        markdown: String,
        format: DocumentExportFormat,
        resourceDirectory: URL,
        destination: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        callCount += 1
        capturedMarkdown = markdown
        capturedFormat = format
        capturedResourceDirectory = resourceDirectory
        capturedDestination = destination
        if completesImmediately {
            completion(immediateResult)
        } else {
            pending = completion
        }
    }

    func finish(_ result: Result<Void, Error> = .success(())) {
        pending?(result)
        pending = nil
    }
}
