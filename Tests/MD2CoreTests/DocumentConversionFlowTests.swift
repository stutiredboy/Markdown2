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

    @Test func cancelingUntitledExportDoesNotPromptForMarkdownSave() {
        let converter = FakeConverter()
        var suggestedName: String?
        var pickedMarkdownLocation = false
        let store = DocumentStore(
            documentConverterFactory: { converter },
            pandocAvailabilityProvider: { true },
            conversionDestinationPicker: { _, defaultName in suggestedName = defaultName; return nil },
            saveLocationPicker: { _ in pickedMarkdownLocation = true; return nil }
        )
        store.text = "# Draft"

        store.exportDOCX()

        #expect(suggestedName == "Untitled.docx")
        #expect(!pickedMarkdownLocation)
        #expect(converter.callCount == 0)
        #expect(store.fileURL == nil)
        #expect(store.isDirty)
        #expect(store.alert == nil)
    }

    @Test func untitledExportKeepsMarkdownUntitledAndUsesNoSourceDirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("draft.epub")
        let converter = FakeConverter()
        var pickedMarkdownLocation = false
        let store = DocumentStore(
            documentConverterFactory: { converter },
            pandocAvailabilityProvider: { true },
            conversionDestinationPicker: { _, _ in destination },
            saveLocationPicker: { _ in pickedMarkdownLocation = true; return nil }
        )
        store.text = "# Draft"

        store.exportEPUB()

        #expect(!pickedMarkdownLocation)
        #expect(converter.callCount == 1)
        #expect(converter.capturedMarkdown == "# Draft")
        #expect(converter.capturedResourceDirectory == nil)
        #expect(converter.capturedDestination == destination)
        #expect(store.fileURL == nil)
        #expect(store.isDirty)
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
        #expect(store.alert?.detail.contains("readers are outside this app’s policy") == true)
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

    @Test func conversionFailureUsesDocumentLanguage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = dir.appendingPathComponent("notes.md")
        try "# Doc\n".write(to: sourceURL, atomically: true, encoding: .utf8)

        let converter = FakeConverter(immediateResult: .failure(PandocConverter.ConversionError.conversionFailed("boom")))
        let store = DocumentStore(
            documentConverterFactory: { converter },
            pandocAvailabilityProvider: { true },
            conversionDestinationPicker: { _, _ in dir.appendingPathComponent("notes.docx") },
            alertTextProvider: { L10n.text($0, language: .zhHans) }
        )
        store.open(sourceURL)

        store.exportDOCX()
        #expect(store.alert?.detail == String(format: L10n.text(.conversionFailedWithDetail, language: .zhHans), "boom"))
    }

    @Test func conversionInFlightBlocksOtherExports() async throws {
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
        await store.exportPDF()
        await store.exportHTML()
        store.exportDOCX()
        #expect(pdfPicked == false)
        #expect(htmlPicked == false)
        #expect(converter.callCount == 1)

        converter.finish(.success(()))
        #expect(store.alert?.detail.contains("readers are outside this app’s policy") == true)
    }

    @Test func changingTextDuringDestinationSelectionAbortsAndAllowsRetry() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let converter = FakeConverter()
        var picked: (() -> Void)?
        var confirmsDestination = true
        let store = DocumentStore(
            documentConverterFactory: { converter },
            pandocAvailabilityProvider: { true },
            conversionDestinationPicker: { _, _ in
                picked?()
                return confirmsDestination ? dir.appendingPathComponent("notes.docx") : nil
            }
        )
        store.text = "# Original"
        picked = { [weak store] in store?.text = "# Changed during picker" }

        store.exportDOCX()

        #expect(converter.callCount == 0)
        #expect(store.conversionStoppedForSourceChange)
        #expect(store.alert == nil)

        picked = nil
        confirmsDestination = false
        store.exportDOCX()
        #expect(converter.callCount == 0)
        #expect(!store.conversionStoppedForSourceChange)

        confirmsDestination = true
        store.exportDOCX()
        #expect(converter.callCount == 1)
        #expect(converter.capturedMarkdown == "# Changed during picker")
        #expect(!store.conversionStoppedForSourceChange)
    }

    @Test func editCancelsActiveConversionWithoutPublishingItsLateResult() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let converter = FakeConverter(completesImmediately: false)
        let store = DocumentStore(
            documentConverterFactory: { converter },
            pandocAvailabilityProvider: { true },
            conversionDestinationPicker: { _, _ in dir.appendingPathComponent("notes.docx") }
        )
        store.exportDOCX()
        #expect(store.convertingFormat == .docx)

        store.text = "# Changed during conversion"
        converter.finish(.failure(PandocConverter.ConversionError.conversionFailed("obsolete")))

        #expect(converter.cancelCount == 1)
        #expect(store.convertingFormat == nil)
        #expect(store.conversionStoppedForSourceChange)
        #expect(store.alert == nil)
    }

    @Test func replacingTheDocumentCancelsConversionAndIgnoresItsLateCompletion() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let replacement = dir.appendingPathComponent("replacement.md")
        try "# Another document\n".write(to: replacement, atomically: true, encoding: .utf8)
        let converter = FakeConverter(completesImmediately: false)
        let store = DocumentStore(
            documentConverterFactory: { converter },
            pandocAvailabilityProvider: { true },
            conversionDestinationPicker: { _, _ in dir.appendingPathComponent("notes.epub") }
        )
        store.exportEPUB()

        store.open(replacement)
        converter.finish()

        #expect(converter.cancelCount == 1)
        #expect(store.convertingFormat == nil)
        #expect(!store.conversionStoppedForSourceChange)
        #expect(store.fileURL == replacement)
        #expect(store.alert == nil)
    }

    @Test(arguments: [false, true])
    func pendingExternalChangeCancelsAndBlocksConversionBeforeReload(dirty: Bool) async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("notes.md")
        try "# Original\n".write(to: source, atomically: true, encoding: .utf8)
        let converter = FakeConverter(completesImmediately: false)
        let watcher = ConversionFlowWatcher()
        let store = DocumentStore(
            documentConverterFactory: { converter },
            pandocAvailabilityProvider: { true },
            conversionDestinationPicker: { _, _ in dir.appendingPathComponent("notes.docx") },
            fileWatcherFactory: { watcher }
        )
        store.open(source)
        if dirty { store.text = "# Changed in editor\n" }
        store.exportDOCX()
        try "# Changed on disk\n".write(to: source, atomically: true, encoding: .utf8)
        watcher.onEvent?()

        let deadline = ContinuousClock.now + .seconds(3)
        while store.pendingExternalReload == nil && !store.hasExternalConflict && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(dirty ? store.hasExternalConflict : store.pendingExternalReload != nil)
        converter.finish()
        store.exportDOCX()
        #expect(converter.cancelCount == 1)
        #expect(converter.callCount == 1)
        #expect(store.alert == nil)

        if dirty { store.resolveExternalConflict(reloadingFromDisk: true) }
        store.completeExternalReload(anchor: nil)
        #expect(store.conversionStoppedForSourceChange)
        store.exportDOCX()
        #expect(converter.callCount == 2)
        #expect(converter.capturedMarkdown == "# Changed on disk\n")
    }

    @Test func cancellationAllowsAnotherConversionBeforeOldCallbackReturns() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = FakeConverter(completesImmediately: false)
        let second = FakeConverter(completesImmediately: false)
        let store = DocumentStore(
            documentConverterFactory: { first.callCount == 0 ? first : second },
            pandocAvailabilityProvider: { true },
            conversionDestinationPicker: { _, defaultName in dir.appendingPathComponent(defaultName) }
        )
        store.exportDOCX()
        store.cancelConversion()
        #expect(first.cancelCount == 1)
        #expect(store.convertingFormat == nil)

        store.exportEPUB()
        first.finish()

        #expect(store.convertingFormat == .epub)
        #expect(store.alert == nil)
        second.finish()
        #expect(store.convertingFormat == nil)
        #expect(store.alert?.message.contains("Untitled.epub") == true)
    }

    @Test func refusesDestinationsThatAliasMarkdownSource() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("notes.md")
        let symbolicLink = dir.appendingPathComponent("symbolic.docx")
        let hardLink = dir.appendingPathComponent("hard.docx")
        try "# Original\n".write(to: source, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: source)
        try FileManager.default.linkItem(at: source, to: hardLink)
        let converter = FakeConverter()
        var selectedDestination = source
        let store = DocumentStore(
            documentConverterFactory: { converter },
            pandocAvailabilityProvider: { true },
            conversionDestinationPicker: { _, _ in selectedDestination }
        )
        store.open(source)

        for destination in [source, symbolicLink, hardLink] {
            selectedDestination = destination
            store.alert = nil
            store.exportDOCX()

            #expect(store.alert?.detail == L10n.text(.alertConversionSourceDestination, language: .english))
            #expect(try String(contentsOf: destination, encoding: .utf8) == "# Original\n")
        }
        #expect(converter.callCount == 0)
    }
}

@MainActor
private final class ConversionFlowWatcher: DocumentFileWatching {
    var onEvent: (() -> Void)?
    func watch(url: URL) {}
    func stop() {}
}

@MainActor
private final class FakeConverter: DocumentConverting {
    private(set) var callCount = 0
    private(set) var cancelCount = 0
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
        resourceDirectory: URL?,
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

    func cancel() { cancelCount += 1 }

    func finish(_ result: Result<Void, Error> = .success(())) {
        let completion = pending
        pending = nil
        completion?(result)
    }
}
