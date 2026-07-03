import AppKit
import Foundation
import MD2Core
import UniformTypeIdentifiers

@MainActor
protocol PDFExporting: AnyObject {
    func export(
        html: String,
        outline: [Heading],
        baseURL: URL?,
        documentTitle: String,
        completion: @escaping (Result<Void, Error>) -> Void
    )
}

@MainActor
protocol DocumentPrinting: AnyObject {
    func print(
        html: String,
        outline: [Heading],
        baseURL: URL?,
        profile: ExportProfile,
        documentTitle: String,
        completion: @escaping (Result<Void, Error>) -> Void
    )
}

@MainActor
final class DocumentStore: ObservableObject {
    @Published var text: String {
        didSet {
            guard text != oldValue else { return }
            // The expensive full-document render that feeds the preview/stats is
            // coalesced off the keystroke path (see `scheduleRender`) so sustained
            // typing is never blocked by a whole-document re-render on every
            // character. The load path (`setDocumentText`) renders synchronously
            // itself, so skip scheduling while loading.
            guard !isLoading else { return }
            isDirty = true
            scheduleRender()
            scheduleAutosaveIfNeeded()
        }
    }

    @Published private(set) var rendered: RenderedDocument
    @Published private(set) var fileURL: URL?
    @Published private(set) var isDirty = false
    @Published var alert: DocumentAlert?
    @Published var jumpLine: Int?
    @Published var jumpHeadingID: String?
    @Published var jumpFraction: Double?
    /// Mode-switch viewport anchors, one per destination surface so the
    /// outgoing view can never consume the incoming view's target during the
    /// transition. They take precedence over the single-target jump bindings
    /// above and are consumed once applied.
    @Published var editorJumpAnchor: ViewportAnchor?
    @Published var previewJumpAnchor: ViewportAnchor?
    @Published private(set) var documentIdentity = UUID()
    /// True while the backing file has changed on disk under unsaved edits and
    /// the user has not chosen a side yet. While set, autosave is suspended and
    /// every save request re-presents the conflict prompt instead of writing.
    @Published private(set) var hasExternalConflict = false
    /// Asks the window layer to present the external-change conflict prompt.
    /// Re-set (new identity) each time the prompt must appear; cleared when
    /// the user resolves it.
    @Published var externalConflictRequest: ExternalConflictRequest?
    /// Set when a clean document should reload externally changed content.
    /// `ContentView` observes it, captures the live viewport anchor of the
    /// active surface, and completes the reload via `completeExternalReload`,
    /// so the window keeps showing the same content position.
    @Published private(set) var pendingExternalReload: UUID?
    /// Set by Find menu commands; observed by `ContentView`, which dispatches the
    /// action to whichever surface (editor or preview) is currently active.
    @Published var findCommand: FindCommand?
    /// Set by Mode menu commands; observed by `ContentView`, which dispatches the
    /// action through the same viewport-preserving transition path as the toolbar.
    @Published var modeCommand: ModeCommand?

    private let renderer = MarkdownRenderer()
    /// Retains the in-flight PDF export for its (asynchronous) lifetime; cleared
    /// when the export completes. PDF is a derived artifact — exporting never
    /// touches `fileURL`, `isDirty`, or autosave.
    private var pdfExporter: PDFExporting?
    private let pdfDestinationPicker: @MainActor (String) -> URL?
    /// Resolves the destination for a self-contained HTML export. Injected so the
    /// flow can be tested without the modal `NSSavePanel`.
    private let htmlDestinationPicker: @MainActor (String) -> URL?
    private let pdfExporterFactory: @MainActor (URL, ExportProfile) -> PDFExporting
    /// Supplies the export profile (page geometry, page numbers, headers/footers)
    /// applied to PDF export and Print. Injected so tests can pin a profile; the
    /// app wires it to the live `AppSettings` value.
    private let exportProfileProvider: @MainActor () -> ExportProfile
    /// Supplies the citation/equation-numbering preferences that feed the render
    /// config. Injected so tests can pin them; the app wires it to live settings.
    private let renderConfigProvider: @MainActor () -> (citationStyle: CitationStyle, numberAllEquations: Bool)
    /// Resolves user-facing alert copy from the app's localization table, so
    /// document alerts follow the app language. Injected (the app wires it to
    /// `AppSettings.text(_:)`); defaults to the English table for tests.
    private let alertTextProvider: @MainActor (L10nKey) -> String
    /// Resolves the destination for the first save of an untitled document.
    /// Injected so the save-before-attachment flow can be tested without the
    /// modal `NSSavePanel`.
    private let saveLocationPicker: @MainActor (String) -> URL?
    /// Retains the in-flight print job for its (asynchronous) lifetime; cleared
    /// when printing completes. Like PDF export, printing is a derived artifact —
    /// it never touches `fileURL`, `isDirty`, or autosave.
    private var documentPrinter: DocumentPrinting?
    private let documentPrinterFactory: @MainActor () -> DocumentPrinting
    /// Retains the in-flight DOCX/EPUB conversion for its (asynchronous) lifetime;
    /// cleared on completion. Like the others, a derived artifact.
    private var documentConverter: DocumentConverting?
    private let documentConverterFactory: @MainActor () -> DocumentConverting
    /// Whether an external Pandoc binary is available (gates DOCX/EPUB export).
    private let pandocAvailabilityProvider: @MainActor () -> Bool
    /// Resolves the destination for a DOCX/EPUB export. Injected for testability.
    private let conversionDestinationPicker: @MainActor (DocumentExportFormat, String) -> URL?

    /// True while any derived-artifact job (PDF export, Print, or DOCX/EPUB
    /// conversion) is in flight. All export/print operations are mutually
    /// exclusive — each produces a file from the document's current state — so each
    /// guards on this. (HTML export is synchronous, so its start-guard suffices.)
    private var isProducingDerivedArtifact: Bool {
        pdfExporter != nil || documentPrinter != nil || documentConverter != nil
    }
    private var isLoading = false
    private var autosaveWorkItem: DispatchWorkItem?
    private let autosaveDelay: TimeInterval = 5
    /// Watches the backing file for external modification/replacement/deletion.
    /// Created lazily on first load/save of a file-backed document; injected so
    /// tests can drive events deterministically.
    private let fileWatcherFactory: @MainActor () -> DocumentFileWatching
    private var fileWatcher: DocumentFileWatching?
    /// Fingerprint of the last content this app read from or wrote to the
    /// backing file. The reference every external event and every write is
    /// checked against, so nothing is silently overwritten or needlessly
    /// reloaded.
    private var lastKnownFingerprint: DocumentFileFingerprint?
    /// True when the pending external reload came from the user choosing
    /// "Reload from Disk" in the conflict prompt, which deliberately discards
    /// the in-memory edits.
    private var pendingReloadDiscardsEdits = false
    /// Coalesces the full-document render that feeds the preview/stats so a burst
    /// of typing renders once when the user pauses instead of synchronously on
    /// every keystroke. Bumped on each schedule so only the latest one fires.
    private var renderGeneration = 0
    private var hasPendingRender = false
    private let renderDebounce: TimeInterval = 0.12

    var baseURL: URL? {
        fileURL?.deletingLastPathComponent()
    }

    /// Localized alert copy, with the file name/format interpolated when the
    /// table string is parameterized.
    private func alertText(_ key: L10nKey) -> String {
        alertTextProvider(key)
    }

    private func alertText(_ key: L10nKey, _ argument: String) -> String {
        String(format: alertTextProvider(key), argument)
    }

    var displayTitle: String {
        let name = fileURL?.lastPathComponent ?? "Untitled.md"
        return isDirty ? "\(name) *" : name
    }

    init(
        pdfDestinationPicker: @escaping @MainActor (String) -> URL? = DocumentStore.presentPDFDestination,
        htmlDestinationPicker: @escaping @MainActor (String) -> URL? = DocumentStore.presentHTMLDestination,
        pdfExporterFactory: @escaping @MainActor (URL, ExportProfile) -> PDFExporting = { PDFExporter(destinationURL: $0, profile: $1) },
        documentPrinterFactory: @escaping @MainActor () -> DocumentPrinting = { DocumentPrinter() },
        documentConverterFactory: @escaping @MainActor () -> DocumentConverting = { PandocConverter() },
        pandocAvailabilityProvider: @escaping @MainActor () -> Bool = { PandocConverter.isAvailable() },
        conversionDestinationPicker: @escaping @MainActor (DocumentExportFormat, String) -> URL? = DocumentStore.presentConversionDestination,
        saveLocationPicker: @escaping @MainActor (String) -> URL? = DocumentStore.presentSaveLocation,
        exportProfileProvider: @escaping @MainActor () -> ExportProfile = { .default },
        renderConfigProvider: @escaping @MainActor () -> (citationStyle: CitationStyle, numberAllEquations: Bool) = { (.authorYear, false) },
        alertTextProvider: @escaping @MainActor (L10nKey) -> String = { L10n.text($0, language: .english) },
        fileWatcherFactory: @escaping @MainActor () -> DocumentFileWatching = { DispatchSourceFileWatcher() }
    ) {
        self.pdfDestinationPicker = pdfDestinationPicker
        self.htmlDestinationPicker = htmlDestinationPicker
        self.pdfExporterFactory = pdfExporterFactory
        self.documentPrinterFactory = documentPrinterFactory
        self.documentConverterFactory = documentConverterFactory
        self.pandocAvailabilityProvider = pandocAvailabilityProvider
        self.conversionDestinationPicker = conversionDestinationPicker
        self.saveLocationPicker = saveLocationPicker
        self.exportProfileProvider = exportProfileProvider
        self.renderConfigProvider = renderConfigProvider
        self.alertTextProvider = alertTextProvider
        self.fileWatcherFactory = fileWatcherFactory

        let starterText = Self.starterMarkdown
        text = starterText
        rendered = renderer.render(starterText)
    }

    /// True when this store still holds the untouched starter document, i.e. it
    /// has never been saved to disk and has no unsaved edits. Such a window can
    /// be reused to load a freshly opened file instead of spawning a new one.
    var isReusableEmptyDocument: Bool {
        fileURL == nil && !isDirty && text == Self.starterMarkdown
    }

    @discardableResult
    func save() -> Bool {
        // An unresolved external conflict blocks every write; asking again is
        // the only honest response to another ⌘S.
        if hasExternalConflict {
            externalConflictRequest = ExternalConflictRequest()
            return false
        }
        if let fileURL {
            return write(to: fileURL)
        } else {
            return presentSaveLocationAndWrite()
        }
    }

    func requestMode(_ mode: EditorMode) {
        modeCommand = ModeCommand(mode)
    }

    /// Prompts for a destination and writes there. Backs the first save of an
    /// untitled document (`save()` falls through to it). No longer exposed as a
    /// menu command — relocating an existing file is left to the Finder.
    @discardableResult
    private func presentSaveLocationAndWrite() -> Bool {
        guard let url = saveLocationPicker(fileURL?.lastPathComponent ?? "Untitled.md") else {
            return false
        }
        return write(to: url)
    }

    /// Default save-location picker: the standard `NSSavePanel` for Markdown.
    private static func presentSaveLocation(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = Self.markdownTypes
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultName
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Turns image sources into the Markdown to insert — one `![alt](path)`
    /// reference per image, newline-joined — or `nil` when nothing should be
    /// inserted.
    ///
    /// An existing file (dropped, or a pasted file URL) is linked in place at its
    /// absolute path and needs no save. Raw clipboard data (a screenshot) has no
    /// location, so it is written into `folder` (document-relative) as PNG, which
    /// first requires saving an untitled document — prompting once; a cancelled
    /// save inserts nothing and a write failure surfaces through `alert`.
    func insertImageAttachments(_ sources: [ImageAttachmentSource], folder: String) -> String? {
        guard !sources.isEmpty else { return nil }

        // Only raw clipboard data must be written into the document-relative
        // folder, which needs a file-backed document; linked files need no save.
        let needsAttachmentFolder = sources.contains { source in
            if case .imageData = source { return true }
            return false
        }
        if needsAttachmentFolder, fileURL == nil {
            guard save(), fileURL != nil else { return nil }
        }

        let manager = ImageAttachmentManager()
        var references: [String] = []
        for source in sources {
            switch source {
            case let .file(url):
                references.append(ImageAttachmentManager.directImageReference(forFile: url))
            case let .imageData(data):
                guard let documentDirectory = baseURL else { continue }
                do {
                    let written = try manager.writeImageData(
                        data,
                        toFolder: folder,
                        documentDirectory: documentDirectory
                    )
                    let linkPath = ImageAttachmentManager.markdownLinkPath(written.relativePath)
                    references.append("![\(written.altText)](\(linkPath))")
                } catch {
                    alert = DocumentAlert(
                        message: alertText(.alertAttachmentSaveFailed),
                        detail: error.localizedDescription
                    )
                }
            }
        }

        guard !references.isEmpty else { return nil }
        return references.joined(separator: "\n")
    }

    /// Exports the rendered preview to a paginated PDF chosen by the user. This
    /// is a derived artifact, not the document's on-disk form: it does NOT change
    /// `fileURL` or `isDirty`, and Save As… still writes Markdown source. The
    /// pending render is flushed first so the PDF reflects the latest text, then
    /// an offscreen `PDFExporter` renders and writes the file; failures surface
    /// through the normal `alert` path.
    func exportPDF() {
        // Ignore a second request while an export or print is still in flight;
        // otherwise the new exporter would replace the retained one and abandon
        // the first. Print and Export are mutually exclusive.
        guard !isProducingDerivedArtifact else { return }

        flushPendingRender()

        guard let url = pdfDestinationPicker(pdfFileName) else {
            return
        }

        let exporter = pdfExporterFactory(url, exportProfileProvider())
        pdfExporter = exporter
        exporter.export(
            html: rendered.html,
            outline: rendered.outline,
            baseURL: baseURL,
            documentTitle: exportDocumentTitle
        ) { [weak self] result in
            guard let self else { return }
            self.pdfExporter = nil
            if case let .failure(error) = result {
                self.alert = DocumentAlert(
                    message: self.alertText(.alertCouldNotExport, url.lastPathComponent),
                    detail: error.localizedDescription
                )
            }
        }
    }

    /// Prints the rendered preview through the system print dialog. Like
    /// `exportPDF()`, this is a derived artifact: the pending render is flushed
    /// first so the print reflects the latest text, and it never changes
    /// `fileURL`, `isDirty`, or autosave. Print and Export share the
    /// `isProducingDerivedArtifact` guard, so they are mutually exclusive.
    /// Failures surface through the normal `alert` path.
    func print() {
        guard !isProducingDerivedArtifact else { return }

        flushPendingRender()

        let printer = documentPrinterFactory()
        documentPrinter = printer
        printer.print(
            html: rendered.html,
            outline: rendered.outline,
            baseURL: baseURL,
            profile: exportProfileProvider(),
            documentTitle: exportDocumentTitle
        ) { [weak self] result in
            guard let self else { return }
            self.documentPrinter = nil
            if case let .failure(error) = result {
                self.alert = DocumentAlert(
                    message: self.alertText(.alertCouldNotPrint),
                    detail: error.localizedDescription
                )
            }
        }
    }

    /// Exports the rendered preview as a single self-contained HTML file chosen by
    /// the user, with local images inlined so the file is portable and opens
    /// offline. Like PDF export and Print this is a derived artifact: it does NOT
    /// change `fileURL`, `isDirty`, or autosave, and the pending render is flushed
    /// first so the export reflects the latest text. Mutually exclusive with the
    /// other export/print jobs (it no-ops while one is in flight).
    func exportHTML() {
        guard !isProducingDerivedArtifact else { return }

        flushPendingRender()

        guard let url = htmlDestinationPicker(htmlFileName) else {
            return
        }

        // Untitled documents have no `baseURL`, so relative image paths cannot be
        // resolved; the builder leaves those references as-is rather than failing.
        let html = SelfContainedHTMLBuilder.build(html: rendered.html, baseURL: baseURL)
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            alert = DocumentAlert(
                message: alertText(.alertCouldNotExport, url.lastPathComponent),
                detail: error.localizedDescription
            )
        }
    }

    /// Exports the document to DOCX via an external Pandoc binary. No-op when Pandoc
    /// is unavailable (a guidance alert is shown instead).
    func exportDOCX() {
        exportConverted(to: .docx)
    }

    /// Exports the document to EPUB via an external Pandoc binary. No-op when Pandoc
    /// is unavailable (a guidance alert is shown instead).
    func exportEPUB() {
        exportConverted(to: .epub)
    }

    /// Shared DOCX/EPUB flow: requires Pandoc, saves an untitled document first (so
    /// relative images resolve against a real directory), then converts the
    /// document's *current* Markdown (including unsaved edits) without changing
    /// `fileURL`/dirty/autosave. Mutually exclusive with the other export jobs.
    private func exportConverted(to format: DocumentExportFormat) {
        guard !isProducingDerivedArtifact else { return }

        guard pandocAvailabilityProvider() else {
            alert = DocumentAlert(
                message: alertText(.alertPandocRequired, format.fileExtension.uppercased()),
                detail: alertText(.alertPandocRequiredDetail)
            )
            return
        }

        // Pandoc reads a source file and resolves relative images against a
        // directory, so an untitled document is saved first to establish one; a
        // cancelled save aborts the export cleanly.
        if fileURL == nil {
            guard save() else { return }
        }
        guard let resourceDirectory = baseURL else { return }

        guard let destination = conversionDestinationPicker(format, conversionFileName(for: format)) else {
            return
        }

        let converter = documentConverterFactory()
        documentConverter = converter
        converter.convert(
            markdown: text,
            format: format,
            resourceDirectory: resourceDirectory,
            destination: destination
        ) { [weak self] result in
            guard let self else { return }
            self.documentConverter = nil
            if case let .failure(error) = result {
                self.alert = DocumentAlert(
                    message: self.alertText(.alertCouldNotExport, destination.lastPathComponent),
                    detail: error.localizedDescription
                )
            }
        }
    }

    /// Default PDF file name: the document's name with a `.pdf` extension, or
    /// `Untitled.pdf` for a document that has never been saved.
    private var pdfFileName: String {
        guard let fileURL else { return "Untitled.pdf" }
        return fileURL.deletingPathExtension().lastPathComponent + ".pdf"
    }

    /// Default HTML file name: the document's name with an `.html` extension, or
    /// `Untitled.html` for a document that has never been saved.
    private var htmlFileName: String {
        guard let fileURL else { return "Untitled.html" }
        return fileURL.deletingPathExtension().lastPathComponent + ".html"
    }

    /// Default DOCX/EPUB file name: the document's base name with the format's
    /// extension, or `Untitled.<ext>` for a document that has never been saved.
    private func conversionFileName(for format: DocumentExportFormat) -> String {
        let base = fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        return "\(base).\(format.fileExtension)"
    }

    /// Document title used to resolve the `{title}` running-text token in exported
    /// PDFs: the file's base name without extension, or `Untitled` for an unsaved
    /// document.
    private var exportDocumentTitle: String {
        guard let fileURL else { return "Untitled" }
        return fileURL.deletingPathExtension().lastPathComponent
    }

    private static func presentPDFDestination(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultName
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private static func presentHTMLDestination(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultName
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private static func presentConversionDestination(
        format: DocumentExportFormat,
        defaultName: String
    ) -> URL? {
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultName
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Relays a find action from a menu command to the active document surface.
    func requestFind(_ action: FindCommand.Action) {
        findCommand = FindCommand(action)
    }

    func jump(to heading: Heading) {
        editorJumpAnchor = nil
        previewJumpAnchor = nil
        jumpFraction = nil
        jumpLine = heading.line
        jumpHeadingID = heading.id
    }

    /// Sets the task-list marker on the 1-based source `line` to `checked`,
    /// in response to a checkbox click in the preview. The request is
    /// validated before anything is written — the line must exist and must
    /// be a task item — so a stale or malformed preview message can never
    /// corrupt unrelated text. Applying an absolute state (instead of
    /// flipping) keeps duplicate messages idempotent; re-render, dirty
    /// marking, and autosave ride the normal `text` pipeline. Returns
    /// whether the line was a valid task item (so a caller can skip
    /// reload-related work for ignored requests).
    @discardableResult
    func toggleTask(atLine line: Int, to checked: Bool) -> Bool {
        guard let lineRange = Self.rangeOfLine(line, in: text),
              let updated = Self.settingTaskMarker(in: String(text[lineRange]), to: checked) else {
            return false
        }
        text = text.replacingCharacters(in: lineRange, with: updated)
        // A checkbox click is a discrete action, not sustained typing: render
        // immediately so the preview reflects the toggle without debounce lag.
        flushPendingRender()
        return true
    }

    /// Character range of the 1-based `line` (excluding its terminator),
    /// counting `\n`, `\r\n`, and `\r` as terminators — the same numbering
    /// `normalizedMarkdownLines` gives the renderer's source-line metadata.
    private static func rangeOfLine(_ line: Int, in text: String) -> Range<String.Index>? {
        guard line >= 1 else { return nil }

        var lineNumber = 1
        var lineStart = text.startIndex
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            // "\r\n" is a single Character in Swift, so each terminator is
            // one grapheme regardless of style.
            if character == "\n" || character == "\r" || character == "\r\n" {
                if lineNumber == line {
                    return lineStart..<index
                }
                lineNumber += 1
                index = text.index(after: index)
                lineStart = index
            } else {
                index = text.index(after: index)
            }
        }

        return lineNumber == line ? lineStart..<text.endIndex : nil
    }

    /// Rewrites the task marker of a single source line to `checked`,
    /// returning `nil` when the line is not a task-list item. Mirrors the
    /// renderer's task syntax: optional leading whitespace and blockquote
    /// `>` prefixes, a `-`/`*`/`+` bullet, one space, then `[ ]`, `[x]`, or
    /// `[X]` followed by a space. Only the mark character changes.
    private static func settingTaskMarker(in line: String, to checked: Bool) -> String? {
        var index = line.startIndex

        // Skip indentation and blockquote prefixes (e.g. "  > > - [ ] x").
        while index < line.endIndex, line[index] == " " || line[index] == "\t" || line[index] == ">" {
            index = line.index(after: index)
        }

        guard index < line.endIndex, "-*+".contains(line[index]) else { return nil }
        index = line.index(after: index)
        guard index < line.endIndex, line[index] == " " else { return nil }
        index = line.index(after: index)

        guard index < line.endIndex, line[index] == "[" else { return nil }
        let markIndex = line.index(after: index)
        guard markIndex < line.endIndex, " xX".contains(line[markIndex]) else { return nil }
        let closeIndex = line.index(after: markIndex)
        guard closeIndex < line.endIndex, line[closeIndex] == "]" else { return nil }
        let spaceIndex = line.index(after: closeIndex)
        guard spaceIndex < line.endIndex, line[spaceIndex] == " " else { return nil }

        var updated = line
        updated.replaceSubrange(markIndex...markIndex, with: checked ? "x" : " ")
        return updated
    }

    func open(_ url: URL) {
        load(from: url)
    }

    private func load(from url: URL) {
        do {
            // Read the raw bytes once: the text decodes from them and the
            // fingerprint hashes them, so the stored hash always matches the
            // exact on-disk content (no re-encoding drift).
            let data = try Data(contentsOf: url)
            guard let decoded = MarkdownFileDecoder.decode(data) else {
                alert = DocumentAlert(
                    message: alertText(.alertUndecodableFile, url.lastPathComponent),
                    detail: alertText(.alertUndecodableFileDetail)
                )
                return
            }
            setDocumentText(decoded.text, fileURL: url, dirty: false)
            lastKnownFingerprint = DocumentFileFingerprint.of(data: data, at: url)
            hasExternalConflict = false
            externalConflictRequest = nil
            pendingExternalReload = nil
            pendingReloadDiscardsEdits = false
            startWatchingFile()
        } catch {
            alert = DocumentAlert(
                message: alertText(.alertCouldNotOpen, url.lastPathComponent),
                detail: error.localizedDescription
            )
        }
    }

    @discardableResult
    private func write(to url: URL) -> Bool {
        // Never blind-overwrite content this app has not seen: when writing to
        // the document's own file, a changed on-disk hash means an external
        // edit landed after our last read/write, so the write is aborted and
        // the conflict flow runs instead. (A missing file proceeds — that is
        // the deliberate recreate-after-external-delete path.)
        if url == fileURL, let lastKnown = lastKnownFingerprint {
            let comparison = DocumentFileFingerprint.comparison(
                lastKnown: lastKnown,
                current: DocumentFileFingerprint.current(at: url)
            )
            if comparison == .contentChanged {
                raiseExternalConflict()
                return false
            }
        }

        // Persisting reads `text` directly (always current), but flush so the
        // rendered state/stats match what was just saved.
        flushPendingRender()
        do {
            autosaveWorkItem?.cancel()
            autosaveWorkItem = nil
            let writtenData = Data(text.utf8)
            try text.write(to: url, atomically: true, encoding: .utf8)
            lastKnownFingerprint = DocumentFileFingerprint.of(data: writtenData, at: url)
            fileURL = url
            isDirty = false
            hasExternalConflict = false
            // Re-arm on the path: an atomic write replaced the inode, and a
            // first save has no watcher yet.
            startWatchingFile()
            return true
        } catch {
            alert = DocumentAlert(
                message: alertText(.alertCouldNotSave, url.lastPathComponent),
                detail: error.localizedDescription
            )
            return false
        }
    }

    private func setDocumentText(_ newText: String, fileURL newFileURL: URL?, dirty: Bool) {
        autosaveWorkItem?.cancel()
        autosaveWorkItem = nil
        isLoading = true
        text = newText
        fileURL = newFileURL
        isDirty = dirty
        renderNow()
        documentIdentity = UUID()
        isLoading = false
    }

    /// Schedules a debounced render; only the most recently scheduled one runs.
    private func scheduleRender() {
        renderGeneration &+= 1
        hasPendingRender = true
        let generation = renderGeneration
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.renderGeneration else { return }
                self.renderNow()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + renderDebounce, execute: work)
    }

    /// Renders synchronously now and cancels any pending debounced render.
    private func renderNow() {
        renderGeneration &+= 1
        hasPendingRender = false
        rendered = renderer.render(text, config: buildRenderConfig())
    }

    /// Re-renders the current document so a settings change (citation style,
    /// equation numbering) is reflected in the preview without waiting for the
    /// next edit. A no-op-friendly entry point the app calls on settings change.
    func reRenderForSettingsChange() {
        renderNow()
    }

    /// Builds the academic render config: citation/equation preferences from
    /// settings, plus the document's front matter and associated bibliography.
    /// File IO (locating and reading the `.bib`) is the app layer's responsibility;
    /// the renderer stays pure and receives only parsed data.
    private func buildRenderConfig() -> RenderConfig {
        let fields = FrontMatterReader.fields(in: text)
        let preferences = renderConfigProvider()
        return RenderConfig(
            bibliography: loadBibliography(fromFrontMatter: fields),
            citationStyle: preferences.citationStyle,
            numberAllEquations: preferences.numberAllEquations,
            mathMacros: FrontMatterReader.parseMathMacros(fields["math-macros"])
        )
    }

    /// Resolves the bibliography file — the front-matter `bibliography:` path or an
    /// auto-detected `references.bib` next to the document — against `baseURL`, and
    /// parses it. Returns an empty map when there is no document directory or the
    /// file is missing/unreadable, so citations degrade gracefully to raw keys.
    private func loadBibliography(fromFrontMatter fields: [String: String]) -> [String: BibEntry] {
        guard let baseURL else { return [:] }
        let candidate = baseURL.appendingPathComponent(fields["bibliography"] ?? "references.bib")
        guard let contents = try? String(contentsOf: candidate, encoding: .utf8) else { return [:] }
        return BibTeXParser.parse(contents)
    }

    /// Forces a pending debounced render to complete immediately, so a caller
    /// that then reads `rendered` (a mode switch, a save, the stats bar) sees
    /// content matching the current `text`. A no-op when no render is pending.
    func flushPendingRender() {
        guard hasPendingRender else { return }
        renderNow()
    }

    // MARK: External file changes

    /// Creates (once) and (re-)arms the watcher on the current backing file.
    private func startWatchingFile() {
        guard let fileURL else {
            stopWatchingFile()
            return
        }
        if fileWatcher == nil {
            let watcher = fileWatcherFactory()
            watcher.onEvent = { [weak self] in self?.evaluateExternalChange() }
            fileWatcher = watcher
        }
        fileWatcher?.watch(url: fileURL)
    }

    /// Detaches the watcher (window close). Idempotent.
    func stopWatchingFile() {
        fileWatcher?.stop()
    }

    /// A watcher event fired: fingerprint the file off the main thread, then
    /// decide on the main actor. The captured `lastKnown` is re-checked on
    /// arrival so a save or reload that landed meanwhile invalidates the
    /// stale evaluation instead of acting on it.
    private func evaluateExternalChange() {
        guard let fileURL, let lastKnown = lastKnownFingerprint, !isLoading else { return }
        let url = fileURL
        Task.detached(priority: .utility) { [weak self] in
            let current = DocumentFileFingerprint.current(at: url)
            await MainActor.run { [weak self] in
                self?.applyExternalChange(current: current, lastKnown: lastKnown, url: url)
            }
        }
    }

    private func applyExternalChange(
        current: DocumentFileFingerprint?,
        lastKnown: DocumentFileFingerprint,
        url: URL
    ) {
        guard fileURL == url, lastKnownFingerprint == lastKnown else { return }
        switch ExternalChangeDecision.action(
            for: DocumentFileFingerprint.comparison(lastKnown: lastKnown, current: current),
            isDirty: isDirty
        ) {
        case .ignore:
            // Same bytes; refresh the date so a touch is not re-hashed forever.
            if let current { lastKnownFingerprint = current }
        case .reloadPreservingViewport:
            beginExternalReload()
        case .presentConflict:
            raiseExternalConflict()
        case .markDeletedDirty:
            // Memory is now the only copy: dirty engages close/quit protection,
            // and the next save recreates the file at the original path. The
            // watcher keeps polling the path for an external restore.
            isDirty = true
        }
    }

    /// Starts the viewport-preserving reload handshake: `ContentView` observes
    /// `pendingExternalReload`, captures the active surface's live anchor, and
    /// calls `completeExternalReload(anchor:)`.
    private func beginExternalReload(discardingEdits: Bool = false) {
        if discardingEdits {
            pendingReloadDiscardsEdits = true
        }
        guard pendingExternalReload == nil else { return }
        pendingExternalReload = UUID()
    }

    /// Replaces the document content with the current on-disk content, keeping
    /// `documentIdentity` (so mode, outline visibility, and find state stay)
    /// and landing both surfaces on `anchor`. An edit that slipped in between
    /// the reload request and this completion downgrades to the conflict
    /// prompt rather than clobbering it.
    func completeExternalReload(anchor: ViewportAnchor?) {
        guard pendingExternalReload != nil else { return }
        pendingExternalReload = nil
        let discardsEdits = pendingReloadDiscardsEdits
        pendingReloadDiscardsEdits = false
        guard let fileURL else { return }

        guard let data = try? Data(contentsOf: fileURL),
              let decoded = MarkdownFileDecoder.decode(data) else {
            alert = DocumentAlert(
                message: alertText(.alertCouldNotOpen, fileURL.lastPathComponent),
                detail: alertText(.alertExternalReloadFailedDetail)
            )
            return
        }
        guard !isDirty || discardsEdits else {
            raiseExternalConflict()
            return
        }

        autosaveWorkItem?.cancel()
        autosaveWorkItem = nil
        jumpLine = nil
        jumpHeadingID = nil
        jumpFraction = nil
        if let anchor {
            editorJumpAnchor = anchor
            previewJumpAnchor = anchor
        }
        isLoading = true
        text = decoded.text
        isDirty = false
        renderNow()
        isLoading = false
        lastKnownFingerprint = DocumentFileFingerprint.of(data: data, at: fileURL)
        hasExternalConflict = false
        externalConflictRequest = nil
        startWatchingFile()
    }

    /// Enters the conflict state: writes stop, autosave is suspended, and the
    /// window layer is asked to present the choice. Re-raising while the
    /// prompt is already pending keeps a single prompt.
    private func raiseExternalConflict() {
        hasExternalConflict = true
        autosaveWorkItem?.cancel()
        autosaveWorkItem = nil
        guard externalConflictRequest == nil else { return }
        externalConflictRequest = ExternalConflictRequest()
    }

    /// Applies the user's conflict choice. Reloading discards the in-memory
    /// edits (through the viewport-preserving handshake); keeping acknowledges
    /// the on-disk state as seen — so the next save overwrites it — and lets
    /// autosave resume.
    func resolveExternalConflict(reloadingFromDisk: Bool) {
        externalConflictRequest = nil
        guard hasExternalConflict else { return }
        hasExternalConflict = false
        if reloadingFromDisk {
            beginExternalReload(discardingEdits: true)
        } else {
            if let fileURL, let current = DocumentFileFingerprint.current(at: fileURL) {
                lastKnownFingerprint = current
            }
            scheduleAutosaveIfNeeded()
        }
    }

    private func scheduleAutosaveIfNeeded() {
        guard fileURL != nil, !hasExternalConflict else {
            autosaveWorkItem?.cancel()
            autosaveWorkItem = nil
            return
        }

        autosaveWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.autosaveNow()
            }
        }
        autosaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + autosaveDelay, execute: workItem)
    }

    private func autosaveNow() {
        guard let fileURL, isDirty, !hasExternalConflict else {
            return
        }

        _ = write(to: fileURL)
    }

    static var markdownTypes: [UTType] {
        [
            UTType(filenameExtension: "md"),
            UTType(filenameExtension: "markdown"),
            .plainText
        ].compactMap { $0 }
    }

    private static let starterMarkdown = """
    # Untitled

    Start writing in Markdown.

    - [ ] Draft
    - [ ] Review
    - [ ] Ship
    """
}

struct DocumentAlert: Identifiable {
    let id = UUID()
    let message: String
    let detail: String
}

/// One presentation of the external-change conflict prompt.
struct ExternalConflictRequest: Identifiable, Equatable {
    let id = UUID()
}
