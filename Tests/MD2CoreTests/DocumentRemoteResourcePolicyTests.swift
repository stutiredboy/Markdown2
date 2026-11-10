import AppKit
import Foundation
import MD2Core
import Testing
@testable import MD2App

@MainActor
struct DocumentRemoteResourcePolicyTests {
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("md2-remote-document-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func grantIsWindowLocalAndCannotBeSetBySource() async {
        let first = DocumentStore(), second = DocumentStore()
        first.text = "---\nremoteResourcePolicy: allowRemoteImages\nremote-images: true\n---\n![remote](https://example.invalid/p.png)"
        await first.flushPendingRender()
        #expect(first.remoteResourcePolicy == .blocked)
        #expect(first.remoteResourceContextToken != second.remoteResourceContextToken)
        first.setRemoteImagesAllowed(true)
        #expect(first.remoteResourcePolicy == .allowRemoteImages)
        #expect(second.remoteResourcePolicy == .blocked)
        first.closeDocument(discardRecovery: true)
        second.closeDocument(discardRecovery: true)
    }

    @Test func permissionInvalidatesSynchronouslyWithoutEditingSavingOrUndo() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("same.md")
        let bytes = Data("- [ ] first\n- [ ] second".utf8)
        try bytes.write(to: url)
        let store = DocumentStore()
        store.open(url)
        await store.flushPendingRender()
        let cleanToken = store.remoteResourceContextToken
        var invalidated = false
        store.registerRemoteResourceInvalidator(for: cleanToken) {
            #expect(store.remoteResourceContextToken == cleanToken)
            #expect(store.remoteResourcePolicy == .blocked)
            invalidated = true
        }
        store.setRemoteImagesAllowed(true)
        #expect(invalidated)
        #expect(store.remoteResourceContextToken != cleanToken)
        #expect(!store.hasCurrentResourcePreview)
        #expect(!store.isDirty)
        #expect(!store.undoManager.canUndo)
        #expect(try Data(contentsOf: url) == bytes)
        store.toggleTask(atLine: 1, to: true)
        let editedText = store.text
        let actionName = store.undoManager.undoActionName
        store.setRemoteImagesAllowed(false)
        #expect(store.text == editedText)
        #expect(store.isDirty)
        #expect(store.undoManager.undoActionName == actionName)
        store.undoManager.undo()
        #expect(Data(store.text.utf8) == bytes)
        store.closeDocument(discardRecovery: true)
    }

    @Test func sameBytesReopenAndOtherDocumentResetGrant() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("a.md"), second = directory.appendingPathComponent("b.md")
        try Data("same".utf8).write(to: first)
        try Data("same".utf8).write(to: second)
        let store = DocumentStore()
        store.open(first)
        for next in [first, second] {
            store.setRemoteImagesAllowed(true)
            let token = store.remoteResourceContextToken
            store.open(next)
            #expect(store.remoteResourcePolicy == .blocked)
            #expect(store.remoteResourceContextToken != token)
            #expect(!store.hasCurrentResourcePreview)
        }
        store.closeDocument(discardRecovery: true)
    }

    @Test func ordinaryEditRenameAndSaveKeepCurrentSessionGrant() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent("old.md"), renamed = directory.appendingPathComponent("renamed.md")
        try Data("original".utf8).write(to: old)
        let store = DocumentStore()
        store.open(old)
        store.setRemoteImagesAllowed(true)
        let token = store.remoteResourceContextToken
        store.text = "edited"
        try FileManager.default.moveItem(at: old, to: renamed)
        store.refreshFileLocation()
        #expect(store.save())
        #expect(store.remoteResourceContextToken == token)
        #expect(store.remoteResourcePolicy == .allowRemoteImages)
        #expect(store.fileURL?.resolvingSymlinksInPath() == renamed.resolvingSymlinksInPath())
        store.closeDocument(discardRecovery: true)
    }

    @Test func acceptedExternalReloadResetsGrantWhilePreservingDocumentUIIdentity() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("document.md")
        try Data("original".utf8).write(to: url)
        let store = DocumentStore()
        store.open(url)
        store.setRemoteImagesAllowed(true)
        let identity = store.documentIdentity, token = store.remoteResourceContextToken
        store.text = "unsaved"
        try Data("external".utf8).write(to: url)
        #expect(!store.save()) // Detect the conflict without a timing-sensitive watcher wait.
        store.resolveExternalConflict(reloadingFromDisk: true)
        store.completeExternalReload(anchor: nil)
        #expect(store.text == "external")
        #expect(store.documentIdentity == identity)
        #expect(store.remoteResourcePolicy == .blocked)
        #expect(store.remoteResourceContextToken != token)
        store.closeDocument(discardRecovery: true)
    }

    @Test func recoveryAndSettingsContainNoGrant() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = DocumentRecoveryRepository(directory: directory.appendingPathComponent("recovery"))
        let suiteName = "md2-remote-settings-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        let storedBefore = defaults.persistentDomain(forName: suiteName) as NSDictionary?
        let store = DocumentStore(exportProfileProvider: { settings.exportProfile }, recoveryRepository: repository)
        store.setRemoteImagesAllowed(true)
        #expect(store.persistRecoveryNow())
        let snapshot = try #require(repository.load().first)
        let data = try JSONEncoder().encode(snapshot)
        #expect(!String(decoding: data, as: UTF8.self).contains("remoteResource"))
        #expect(defaults.persistentDomain(forName: suiteName) as NSDictionary? == storedBefore)
        let restored = DocumentStore()
        restored.setRemoteImagesAllowed(true)
        restored.restore(snapshot)
        #expect(restored.remoteResourcePolicy == .blocked)
        store.closeDocument(discardRecovery: true)
        restored.closeDocument(discardRecovery: true)
    }

    @Test func staleRegistrationIsInvalidatedAndCannotReplaceCurrentPageInvalidator() {
        let store = DocumentStore()
        let old = store.remoteResourceContextToken
        store.setRemoteImagesAllowed(true)
        var currentInvalidated = false, staleInvalidated = false
        store.registerRemoteResourceInvalidator(for: store.remoteResourceContextToken) { currentInvalidated = true }
        store.registerRemoteResourceInvalidator(for: old) { staleInvalidated = true }
        #expect(staleInvalidated)
        #expect(!currentInvalidated)
        store.setRemoteImagesAllowed(false)
        #expect(currentInvalidated)
        store.closeDocument(discardRecovery: true)
    }

    @Test func exportCapturesGrantAndRevocationCancelsWithoutPublishingObsoleteCompletion() async {
        let exporter = DeferredRemoteExporter()
        let store = DocumentStore(pdfDestinationPicker: { _ in URL(fileURLWithPath: "/unused.pdf") },
                                  pdfExporterFactory: { _, _ in exporter })
        store.setRemoteImagesAllowed(true)
        await store.exportPDF()
        #expect(exporter.policies == [.allowRemoteImages])
        store.setRemoteImagesAllowed(false)
        #expect(exporter.cancelCount == 1)
        exporter.finish(.failure(CancellationError()))
        #expect(store.alert == nil)
        await store.exportPDF()
        #expect(exporter.policies == [.allowRemoteImages, .blocked])
        store.closeDocument(discardRecovery: true)
        #expect(exporter.cancelCount == 2)
    }

    @Test func printCapturesGrantAndClosingCancelsIt() async {
        let printer = DeferredRemotePrinter()
        let store = DocumentStore(documentPrinterFactory: { printer })
        store.setRemoteImagesAllowed(true)
        await store.print()
        #expect(printer.policy == .allowRemoteImages)
        store.closeDocument(discardRecovery: true)
        #expect(printer.cancelCount == 1)
        #expect(store.remoteResourcePolicy == .blocked)
        printer.completion?(.failure(CancellationError()))
        #expect(store.alert == nil)
    }

    @Test(arguments: [false, true])
    func nativeExportKeepsItsCapturedLabelWhenLanguageChangesDuringRendering(printing: Bool) async {
        let gate = RemoteRenderingGate()
        let worker = DocumentRenderWorker(beforeRendering: { await gate.pauseIfArmed() })
        let exporter = DeferredRemoteExporter()
        let printer = DeferredRemotePrinter()
        let language = RemoteAlertLanguage()
        let store = DocumentStore(pdfDestinationPicker: { _ in URL(fileURLWithPath: "/unused.pdf") },
                                  pdfExporterFactory: { _, _ in exporter },
                                  documentPrinterFactory: { printer },
                                  alertTextProvider: { L10n.text($0, language: language.value) },
                                  renderWorker: worker)
        let capturedLabel = L10n.text(.remoteImageBlocked, language: language.value)
        await store.flushPendingRender()
        await gate.arm()
        let job = Task {
            if printing { await store.print() } else { await store.exportPDF() }
        }
        await gate.waitUntilStarted()
        language.value = .english
        #expect(L10n.text(.remoteImageBlocked, language: language.value) != capturedLabel)
        #expect(exporter.labels.isEmpty && printer.labels.isEmpty)
        await gate.release()
        await job.value
        #expect((printing ? printer.labels : exporter.labels) == [capturedLabel])
        store.closeDocument(discardRecovery: true)
    }

    @Test func oldPDFPreparationCannotStartAfterRevokeOrClearANewerJob() async {
        let gate = RemoteRenderingGate()
        let worker = DocumentRenderWorker(beforeRendering: { await gate.pauseIfArmed() })
        let exporter = DeferredRemoteExporter()
        let store = DocumentStore(pdfDestinationPicker: { _ in URL(fileURLWithPath: "/unused.pdf") },
                                  pdfExporterFactory: { _, _ in exporter }, renderWorker: worker)
        store.setRemoteImagesAllowed(true)
        await store.flushPendingRender()
        await gate.arm()
        let oldJob = Task { await store.exportPDF() }
        await gate.waitUntilStarted()
        store.setRemoteImagesAllowed(false)
        await store.exportPDF()
        #expect(exporter.policies == [.blocked])
        await gate.release()
        await oldJob.value
        await store.exportPDF() // The new pending exporter still excludes another one.
        #expect(exporter.policies == [.blocked])
        store.closeDocument(discardRecovery: true)
    }

    @Test func oldHTMLPreparationCannotPublishAfterClose() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("stale.html")
        let gate = RemoteRenderingGate()
        let worker = DocumentRenderWorker(beforeRendering: { await gate.pauseIfArmed() })
        let store = DocumentStore(htmlDestinationPicker: { _ in destination }, renderWorker: worker)
        await gate.arm()
        let oldJob = Task { await store.exportHTML() }
        await gate.waitUntilStarted()
        store.closeDocument(discardRecovery: true)
        await gate.release()
        await oldJob.value
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(store.alert == nil)
    }

    @Test func oldPreviewRenderCannotPublishUnderANewerPermissionEpoch() async {
        let gate = RemoteRenderingGate()
        let worker = DocumentRenderWorker(beforeRendering: { await gate.pauseIfArmed() })
        let store = DocumentStore(renderWorker: worker)
        await gate.arm()
        store.setRemoteImagesAllowed(true)
        let flush = Task { await store.flushPendingRender() }
        await gate.waitUntilStarted()
        store.setRemoteImagesAllowed(false)
        #expect(!store.hasCurrentResourcePreview)
        await gate.release()
        await flush.value
        #expect(store.hasCurrentResourcePreview)
        #expect(store.rendered.html.contains("img-src data: md2-local-image:"))
        #expect(!store.rendered.html.contains("img-src data: md2-local-image: http:"))
        store.closeDocument(discardRecovery: true)
    }

    @Test func offlineWorkerNeverInheritsAllowedSnapshot() async {
        let worker = DocumentRenderWorker()
        let snapshot = DocumentRenderSnapshot(text: "![remote](https://example.invalid/image.png)", baseURL: nil,
                                              citationStyle: .authorYear, numberAllEquations: false,
                                              remoteResourcePolicy: .allowRemoteImages)
        let preview = await worker.render(snapshot)
        #expect(preview.html.contains("http: https:"))
        let offline = await worker.renderSelfContainedHTML(snapshot) { html, _ in
            #expect(html.contains("img-src data:;"))
            #expect(!html.contains("img-src data: http:"))
            return SelfContainedHTMLBuilder.Output(html: html, remoteImages: [], unembeddedLocalImages: [])
        }
        #expect(offline.html.contains("img-src data:;"))
    }

    @Test func pendingConversionIsCancelledAndOnlyCurrentCompletionShowsBoundaryNotice() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("document.md")
        try Data("# Document".utf8).write(to: source)
        let converter = DeferredRemoteConverter()
        let store = DocumentStore(documentConverterFactory: { converter },
                                  pandocAvailabilityProvider: { true },
                                  conversionDestinationPicker: { _, _ in directory.appendingPathComponent("out.docx") })
        store.open(source)
        store.setRemoteImagesAllowed(true)
        store.exportDOCX()
        store.setRemoteImagesAllowed(false)
        #expect(converter.cancelCount == 1)
        converter.finish(.success(()))
        #expect(store.alert == nil)
        store.exportDOCX()
        converter.finish(.success(()))
        #expect(store.alert?.detail.contains("Network access was blocked during conversion") == true)
        #expect(store.alert?.detail.contains("Use HTML or PDF") == true)
        store.closeDocument(discardRecovery: true)
    }

    @Test func exportedHTMLCSPIsOfflineEvenWithSessionGrant() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("out.html")
        let store = DocumentStore(htmlDestinationPicker: { _ in destination })
        store.text = "![remote](https://example.invalid/image.png)"
        store.setRemoteImagesAllowed(true)
        await store.exportHTML()
        let html = try String(contentsOf: destination, encoding: .utf8)
        #expect(html.contains("img-src data:;"))
        #expect(!html.contains("img-src data: http:"))
        #expect(store.alert?.detail.contains("inactive placeholders") == true)
        store.closeDocument(discardRecovery: true)
    }

    @Test func allSessionAndOfflineBoundaryLabelsAreLocalized() {
        let keys: [L10nKey] = [.remoteImages, .remoteImagesBlocked, .remoteImagesAllowed, .remoteImagesAllow,
                              .remoteImagesAllowConfirm, .remoteImagesRevoke, .remoteImagesExplanation,
                              .remoteImagesPrivacy, .remoteImagesAllowedExplanation, .remoteImagesPreparing,
                              .remoteImageBlocked, .offlineHTMLRemoteImageBlocked, .offlineHTMLLocalImageUnavailable,
                              .alertHTMLExported, .alertHTMLExportDiagramResources,
                              .alertExternalFormatExported, .alertExternalFormatNetworkBoundary]
        for key in keys {
            let english = L10n.text(key, language: .english), chinese = L10n.text(key, language: .zhHans)
            #expect(english != key.rawValue)
            #expect(chinese != key.rawValue)
            #expect(chinese != english)
        }
    }
}

@MainActor
private final class RemoteAlertLanguage {
    var value = AppLanguage.zhHans
}

private actor RemoteRenderingGate {
    private var armed = false
    private var paused: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func arm() { armed = true }
    func pauseIfArmed() async {
        guard armed else { return }
        armed = false
        await withCheckedContinuation { continuation in
            paused = continuation
            started?.resume()
            started = nil
        }
    }
    func waitUntilStarted() async {
        if paused != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { paused?.resume(); paused = nil }
}

@MainActor
private final class DeferredRemoteExporter: PDFExporting {
    var policies: [RemoteResourcePolicy] = []
    var labels: [String] = []
    var cancelCount = 0
    private var completion: ((Result<Void, Error>) -> Void)?
    func export(html: String, outline: [Heading], baseURL: URL?, remoteResourcePolicy: RemoteResourcePolicy,
                documentTitle: String, remoteImageBlockedLabel: String,
                completion: @escaping (Result<Void, Error>) -> Void) {
        policies.append(remoteResourcePolicy)
        labels.append(remoteImageBlockedLabel)
        self.completion = completion
    }
    func cancel() { cancelCount += 1 }
    func finish(_ result: Result<Void, Error>) { completion?(result); completion = nil }
}

@MainActor
private final class DeferredRemotePrinter: DocumentPrinting {
    var policy: RemoteResourcePolicy?
    var labels: [String] = []
    var cancelCount = 0
    var completion: ((Result<Void, Error>) -> Void)?
    func print(html: String, outline: [Heading], baseURL: URL?, remoteResourcePolicy: RemoteResourcePolicy,
               profile: ExportProfile, documentTitle: String, remoteImageBlockedLabel: String,
               completion: @escaping (Result<Void, Error>) -> Void) {
        policy = remoteResourcePolicy
        labels.append(remoteImageBlockedLabel)
        self.completion = completion
    }
    func cancel() { cancelCount += 1 }
}

@MainActor
private final class DeferredRemoteConverter: DocumentConverting {
    var cancelCount = 0
    private var completion: ((Result<Void, Error>) -> Void)?
    func convert(markdown: String, format: DocumentExportFormat, resourceDirectory: URL, destination: URL,
                 completion: @escaping (Result<Void, Error>) -> Void) {
        self.completion = completion
    }
    func cancel() { cancelCount += 1 }
    func finish(_ result: Result<Void, Error>) { completion?(result); completion = nil }
}
