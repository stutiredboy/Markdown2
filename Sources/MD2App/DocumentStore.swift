import AppKit
import Darwin
import Foundation
import MD2Core
import UniformTypeIdentifiers

enum RemoteImageOverride: Equatable {
    case inherit
    case allow
    case block
}

@MainActor
final class DocumentStore: ObservableObject {
    @Published var text: String {
        didSet {
            // Source bytes matter for saving and UTF-16 editor offsets. Swift
            // String equality treats different Unicode normalizations as equal.
            // Most typing changes the byte count. Otherwise NSString compares
            // literal code units efficiently, as the editor session does.
            guard text.utf8.count != oldValue.utf8.count || !(text as NSString).isEqual(to: oldValue) else { return }
            stopConversion(sourceChanged: true)
            textMutationRevision &+= 1
            sourceLineRevision &+= 1
            // The expensive full-document render that feeds the preview/stats is
            // coalesced off the keystroke path (see `scheduleRender`) so sustained
            // typing is never blocked by a whole-document re-render on every
            // character. Loads schedule their own render after updating the file URL.
            guard !isLoading else { return }
            isDirty = true
            scheduleRender()
            scheduleAutosaveIfNeeded()
            scheduleRecovery()
        }
    }

    @Published private(set) var rendered: RenderedDocument
    /// Effective policy, separate from the document's own choice and the
    /// folder's optional grant. The document choice and file veto are ephemeral.
    @Published private(set) var remoteResourcePolicy: RemoteResourcePolicy = .blocked
    @Published private(set) var remoteImageOverride: RemoteImageOverride = .inherit
    private var folderAllowsRemoteImages = false
    private var remoteImageFileReference: DocumentCopyFileReference?
    var onRemoteImageBackingChanged: (() -> Void)?
    var onRemoteImageOverrideChanged: ((RemoteImageOverride) -> Void)?

    var remoteImageBacking: (url: URL, reference: DocumentCopyFileReference)? {
        guard !isClosed, !backingFileMissing, let fileURL, let remoteImageFileReference else { return nil }
        return (fileURL, remoteImageFileReference)
    }
    @Published private(set) var remoteResourceContextToken = UUID()
    @Published private(set) var renderedRemoteResourceContextToken: UUID?
    private var remoteResourceInvalidator: (@MainActor () -> Void)?

    var hasCurrentResourcePreview: Bool {
        renderedRemoteResourceContextToken == remoteResourceContextToken
    }

    var canInspectRemoteResources: Bool {
        !isClosed && hasCurrentResourcePreview && !hasPendingRender
    }

    func inspectRemoteResources() async -> RemoteResourceReport? {
        guard !Task.isCancelled, canInspectRemoteResources else { return nil }
        let token = remoteResourceContextToken
        let generation = renderGeneration
        let body = rendered.body
        let inspection = Task.detached(priority: .userInitiated) { RemoteResourceReport.inspect(body: body) }
        let report = await withTaskCancellationHandler {
            await inspection.value
        } onCancel: {
            inspection.cancel()
        }
        guard resourceContextIsCurrent(token), renderGeneration == generation else { return nil }
        return report
    }

    /// Called by a native control only. This deliberately bypasses the source
    /// text pipeline: permission changes create no dirty, save, or Undo action.
    func setRemoteImagesAllowed(_ allowed: Bool) {
        setRemoteImageOverride(allowed ? .allow : .inherit)
    }

    func setRemoteImageOverride(_ choice: RemoteImageOverride) {
        guard !isClosed else { return }
        if remoteImageOverride != choice { remoteImageOverride = choice }
        onRemoteImageOverrideChanged?(choice)
        updateRemoteImagePolicy()
    }

    func setFolderRemoteImages(allowed: Bool, blockedForFile: Bool) {
        guard !isClosed else { return }
        folderAllowsRemoteImages = allowed
        if blockedForFile, remoteImageOverride == .inherit { remoteImageOverride = .block }
        else if !blockedForFile, remoteImageOverride == .block { remoteImageOverride = .inherit }
        updateRemoteImagePolicy()
    }

    private func updateRemoteImagePolicy() {
        let allowsImages = remoteImageOverride == .allow || (remoteImageOverride == .inherit && folderAllowsRemoteImages)
        let policy: RemoteResourcePolicy = allowsImages ? .allowRemoteImages : .blocked
        guard policy != remoteResourcePolicy else { return }
        replaceRemoteResourceContext(policy: policy)
        renderImmediately()
    }

    private func refreshInheritedRemoteImages() {
        if folderAllowsRemoteImages && remoteImageOverride == .inherit { onRemoteImageBackingChanged?() }
    }

    private func resetRemoteImageChoices() {
        if remoteImageOverride != .inherit { remoteImageOverride = .inherit }
        folderAllowsRemoteImages = false
    }

    /// SwiftUI teardown runs later; cancel the active WebKit context synchronously
    /// before a policy or document replacement can return to the event loop.
    func registerRemoteResourceInvalidator(for token: UUID, _ invalidate: @escaping @MainActor () -> Void) {
        guard !isClosed, token == remoteResourceContextToken else { invalidate(); return }
        remoteResourceInvalidator = invalidate
    }

    private func replaceRemoteResourceContext(
        policy: RemoteResourcePolicy = .blocked,
        keepingConversionNotice: Bool = false
    ) {
        remoteResourceInvalidator?()
        remoteResourceInvalidator = nil
        // Advance identity before cancellation callbacks: they may complete
        // synchronously and must not publish an obsolete error or clear a new job.
        remoteResourceContextToken = UUID()
        remoteResourcePolicy = policy
        renderedRemoteResourceContextToken = nil
        renderGeneration &+= 1
        pdfExporter?.cancel()
        documentPrinter?.cancel()
        if keepingConversionNotice {
            stopConversion(sourceChanged: true)
        } else {
            cancelConversion()
        }
        pdfExporter = nil
        documentPrinter = nil
        preparingDerivedArtifact = nil
    }

    private func resourceContextIsCurrent(_ token: UUID) -> Bool {
        !Task.isCancelled && !isClosed && remoteResourceContextToken == token
    }
    let copyFlow = DocumentCopyFlow()
    @Published private(set) var fileURL: URL? {
        didSet {
            if oldValue != fileURL {
                stopConversion(sourceChanged: true)
                editorSession.invalidatePasteContext()
            }
        }
    }
    @Published private(set) var isDirty = false
    @Published private(set) var fileFormat = MarkdownFileFormat()
    @Published private(set) var backingFileMissing = false {
        didSet {
            if backingFileMissing && !oldValue { stopConversion(sourceChanged: true) }
        }
    }
    @Published var encodingConversionRequest: UUID?
    private var encodingWarningShown = false
    private let confirmEncodingConversion: @MainActor (String) -> Bool
    private var fileIdentity: DocumentFileIdentity?
    private var copyFileReference: DocumentCopyFileReference?
    var copySaveIO = DocumentCopySaveIO()
    private let recoveryRepository: DocumentRecoveryRepository?
    private let historyRepository: DocumentHistoryRepository?
    private let keepsLocalHistory: @MainActor () -> Bool
    private var historyFileID: DocumentHistoryFileID?
    private var historyLineage = UUID()
    private(set) var recoveryID = UUID()
    var windowFrame: String? { didSet { if windowFrame != oldValue { scheduleRecovery() } } }
    private var recoveryTask: Task<Void, Never>?
    private var recoveryErrorReported = false
    private var isClosed = false {
        didSet {
            if oldValue != isClosed { editorSession.invalidatePasteContext(isOpen: !isClosed) }
        }
    }
    @Published var alert: DocumentAlert?
    private var headingNavigationTask: Task<Void, Never>?
    @Published var jumpLine: Int?
    @Published var jumpHeadingID: String?
    @Published var jumpFraction: Double?
    /// Mode-switch viewport anchors, one per destination surface so the
    /// outgoing view can never consume the incoming view's target during the
    /// transition. They take precedence over the single-target jump bindings
    /// above and are consumed once applied.
    @Published var editorJumpAnchor: ViewportAnchor?
    @Published var previewJumpAnchor: ViewportAnchor?
    /// A source line for the editor to select, sent by a preview gutter click;
    /// the editor clears it once applied.
    @Published var editorLineSelection: LineSelectionRequest?
    @Published private(set) var documentIdentity = UUID() {
        didSet {
            if oldValue != documentIdentity { editorSession.invalidatePasteContext() }
        }
    }
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
    @Published var formatCommand: MarkdownFormatCommand?
    /// Read-mode formatting first reveals the source target without editing it.
    @Published var showsFormattingTargetNotice = false
    @Published var tableEditingRejection: MarkdownTableEditing.Rejection?
    @Published var pasteNotice: MarkdownPasteNotice?

    func requestFormat(_ action: MarkdownEditing.Action) {
        if editorSession.textView?.hasMarkedText() == true { return }
        // Focus can arrive before the new editor has visible geometry. Ignore
        // repeated commands while its first source-target reveal is pending;
        // never queue an edit to run later without a fresh user command.
        guard !editorSession.revealSelectionOnNextHost else { return }
        if let editor = editorSession.textView, let window = editor.window {
            // A find field or Settings control owns the keyboard in Write mode.
            guard window.firstResponder === editor else { return }
            showsFormattingTargetNotice = false
            formatCommand = MarkdownFormatCommand(action: action)
            return
        }
        // Rendered selection is not a source range: repeated text, links and
        // formula output cannot be mapped by guessing. The first command only
        // reveals the retained source selection. A new command after the user
        // sees/focuses that target is required to edit it.
        formatCommand = nil
        showsFormattingTargetNotice = true
        editorSession.revealSelectionOnNextHost = true
        requestMode(.write)
    }

    /// Reuse Read's reveal-first rule; a native field must never route table
    /// editing to the retained source text behind it.
    func requestTableEdit(_ action: MarkdownTableEditing.Action) {
        if let field = NSApp.keyWindow?.firstResponder as? NSTextView,
           field !== editorSession.textView { return }
        requestFormat(.tableEdit(action))
    }

    /// The document's undo history. The window hands it to the Edit menu and the
    /// editor's text view registers its edits on it, so all three share one
    /// stack that belongs to the document rather than to any one view.
    let undoManager = StructuredEditUndoManager()
    /// The editor text system — one text view for the document's lifetime,
    /// re-hosted by every editor it mounts. Its undo actions target that view,
    /// so keeping it here is what keeps them valid across mode switches.
    private(set) lazy var editorSession: MarkdownEditorSession = {
        let session = MarkdownEditorSession(undoManager: undoManager)
        // Read mode: undo/redo (and checkbox toggles) still edit the unmounted
        // text view; its text is the document's.
        session.onPasteNotice = { [weak self] notice in self?.pasteNotice = notice }
        session.onUnmountedTextChange = { [weak self] text in
            self?.text = text
        }
        session.onTableEditingResult = { [weak self] rejection in
            self?.tableEditingRejection = rejection
        }
        return session
    }()

    private let renderer = MarkdownRenderer()
    private let renderWorker: DocumentRenderWorker
    private var renderTask: Task<Void, Never>?
    private var renderDebounceTask: Task<Void, Never>?
    private var isDebouncingRender = false
    private var preparingDerivedArtifact: UUID?
    /// Retains the in-flight PDF export for its (asynchronous) lifetime; cleared
    /// when the export completes. PDF is a derived artifact — exporting never
    /// touches `fileURL`, `isDirty`, or autosave.
    private var pdfExporter: PDFExporting?
    private let pdfDestinationPicker: @MainActor (String) -> URL?
    /// Resolves the destination for a self-contained HTML export. Injected so the
    /// flow can be tested without the modal `NSSavePanel`.
    private let htmlDestinationPicker: @MainActor (String) -> URL?
    private let pdfExporterFactory: (@MainActor (URL, ExportProfile) -> PDFExporting)?
    /// Supplies the export profile (page geometry, page numbers, headers/footers)
    /// applied to PDF export and Print. Injected so tests can pin a profile; the
    /// app wires it to the live `AppSettings` value.
    private let exportProfileProvider: @MainActor () -> ExportProfile
    /// Supplies the citation/equation-numbering preferences that feed the render
    /// config. Injected so tests can pin them; the app wires it to live settings.
    private let renderConfigProvider: @MainActor () -> (citationStyle: CitationStyle, numberAllEquations: Bool)
    private let syntaxConfigProvider: @MainActor () -> (InlineFeatures, AlertLanguage)
    /// Resolves user-facing alert copy from the app's localization table, so
    /// document alerts follow the app language. Injected (the app wires it to
    /// `AppSettings.text(_:)`); defaults to the English table for tests.
    private let alertTextProvider: @MainActor (L10nKey) -> String
    /// Resolves the destination for the first save of an untitled document.
    /// Injected so the save-before-attachment flow can be tested without the
    /// modal `NSSavePanel`.
    private let saveLocationPicker: @MainActor (String) -> URL?
    @Published private(set) var isWorkingOnAttachments = false
    /// Injectable asynchronous boundary; production work never decodes on MainActor.
    var attachmentWorker: @Sendable (AttachmentCollection.Job) async -> AttachmentCollection.Output = { job in
        await Task.detached(priority: .userInitiated) { job.run() }.value
    }
    private let confirmExternalAttachmentDirectory: (@MainActor (URL) -> Bool)?
    /// Approval belongs to this document and exact resolved target, for this session.
    private var approvedAttachmentDestinations: Set<AttachmentApproval> = []
    private struct AttachmentApproval: Hashable {
        let document: URL
        let directory: URL
    }
    /// Retains the in-flight print job for its (asynchronous) lifetime; cleared
    /// when printing completes. Like PDF export, printing is a derived artifact —
    /// it never touches `fileURL`, `isDirty`, or autosave.
    private var documentPrinter: DocumentPrinting?
    private let documentPrinterFactory: @MainActor () -> DocumentPrinting
    private enum ConversionState {
        case choosingDestination(UUID)
        case running(UUID, DocumentExportFormat, DocumentConverting)
        case sourceChanged

        var operationID: UUID? {
            switch self {
            case .choosingDestination(let id), .running(let id, _, _): id
            case .sourceChanged: nil
            }
        }
    }
    @Published private var conversion: ConversionState?
    var convertingFormat: DocumentExportFormat? {
        guard case .running(_, let format, _) = conversion else { return nil }
        return format
    }
    var conversionStoppedForSourceChange: Bool {
        if case .sourceChanged = conversion { return true }
        return false
    }

    private let documentConverterFactory: @MainActor () -> DocumentConverting
    /// Whether an external Pandoc binary is available (gates DOCX/EPUB export).
    private let pandocAvailabilityProvider: @MainActor () -> Bool
    /// Resolves the destination for a DOCX/EPUB export. Injected for testability.
    private let conversionDestinationPicker: (@MainActor (DocumentExportFormat, String) -> URL?)?

    /// True while any derived-artifact job (PDF export, Print, or DOCX/EPUB
    /// conversion) is in flight. All export/print operations are mutually
    /// exclusive — each produces a file from the document's current state — so each
    /// guards on this, including the background preparation stage.
    var isProducingDerivedArtifact: Bool {
        preparingDerivedArtifact != nil || pdfExporter != nil || documentPrinter != nil || conversion?.operationID != nil
    }
    private var isLoading = false
    private var autosaveTask: Task<Void, Never>?
    private var autosaveDeadlineTask: Task<Void, Never>?
    private let autosaveDelay: TimeInterval
    private let maximumAutosaveDelay: TimeInterval
    private let recoveryDelay: TimeInterval
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
    /// A reload choice authorizes discarding only the text the user saw when
    /// confirming. Edits during asynchronous viewport capture need a new choice.
    private var pendingReloadDiscardRevision: Int?
    /// Coalesces the full-document render that feeds the preview/stats so a burst
    /// of typing renders once when the user pauses instead of synchronously on
    /// every keystroke. Bumped on each schedule so only the latest one fires.
    private var renderGeneration = 0
    private var hasPendingRender = false
    private let renderDebounce: Duration = .milliseconds(120)
    /// Counts the text changes that can move a task to another line, which is
    /// every change but `toggleTask`'s. A preview's line numbers mean something
    /// only in the revision it was rendered from.
    private(set) var sourceLineRevision = 0
    /// Unlike source-line mapping, this also advances for task checkbox edits.
    private var textMutationRevision = 0
    /// The `sourceLineRevision` of the text `rendered` was built from. Always
    /// set together with `rendered`, whose publication carries it to the preview.
    private(set) var renderedSourceLineRevision = 0
    private(set) var renderedTextMutationRevision = 0
    private(set) var renderedEditableFormulaLines: Set<Int> = []

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
        pdfExporterFactory: (@MainActor (URL, ExportProfile) -> PDFExporting)? = nil,
        documentPrinterFactory: @escaping @MainActor () -> DocumentPrinting = { DocumentPrinter() },
        documentConverterFactory: @escaping @MainActor () -> DocumentConverting = { PandocConverter() },
        pandocAvailabilityProvider: @escaping @MainActor () -> Bool = { PandocConverter.isAvailable() },
        conversionDestinationPicker: (@MainActor (DocumentExportFormat, String) -> URL?)? = nil,
        saveLocationPicker: @escaping @MainActor (String) -> URL? = DocumentStore.presentSaveLocation,
        confirmExternalAttachmentDirectory: (@MainActor (URL) -> Bool)? = nil,
        exportProfileProvider: @escaping @MainActor () -> ExportProfile = { .default },
        renderConfigProvider: @escaping @MainActor () -> (citationStyle: CitationStyle, numberAllEquations: Bool) = { (.authorYear, false) },
        syntaxConfigProvider: @escaping @MainActor () -> (InlineFeatures, AlertLanguage) = { (.init(), .english) },
        alertTextProvider: @escaping @MainActor (L10nKey) -> String = { L10n.text($0, language: .english) },
        fileWatcherFactory: @escaping @MainActor () -> DocumentFileWatching = { DispatchSourceFileWatcher() },
        recoveryRepository: DocumentRecoveryRepository? = nil,
        historyRepository: DocumentHistoryRepository? = nil,
        keepsLocalHistory: @escaping @MainActor () -> Bool = { true },
        autosaveDelay: TimeInterval = 5,
        maximumAutosaveDelay: TimeInterval = 30,
        recoveryDelay: TimeInterval = 1,
        confirmEncodingConversion: @escaping @MainActor (String) -> Bool = { _ in false },
        renderWorker: DocumentRenderWorker = DocumentRenderWorker()
    ) {
        self.pdfDestinationPicker = pdfDestinationPicker
        self.htmlDestinationPicker = htmlDestinationPicker
        self.pdfExporterFactory = pdfExporterFactory
        self.documentPrinterFactory = documentPrinterFactory
        self.documentConverterFactory = documentConverterFactory
        self.pandocAvailabilityProvider = pandocAvailabilityProvider
        self.conversionDestinationPicker = conversionDestinationPicker
        self.saveLocationPicker = saveLocationPicker
        self.confirmExternalAttachmentDirectory = confirmExternalAttachmentDirectory
        self.exportProfileProvider = exportProfileProvider
        self.renderConfigProvider = renderConfigProvider
        self.syntaxConfigProvider = syntaxConfigProvider
        self.alertTextProvider = alertTextProvider
        self.fileWatcherFactory = fileWatcherFactory
        self.recoveryRepository = recoveryRepository
        self.historyRepository = historyRepository
        self.keepsLocalHistory = keepsLocalHistory
        self.autosaveDelay = autosaveDelay
        self.maximumAutosaveDelay = maximumAutosaveDelay
        self.recoveryDelay = recoveryDelay
        self.confirmEncodingConversion = confirmEncodingConversion
        self.renderWorker = renderWorker

        let starterText = Self.starterMarkdown
        text = starterText
        rendered = renderer.render(starterText, assetMode: .appScheme, remoteResourcePolicy: .blocked)
        renderedRemoteResourceContextToken = remoteResourceContextToken
    }

    /// True when this store still holds the untouched starter document, i.e. it
    /// has never been saved to disk and has no unsaved edits. Such a window can
    /// be reused to load a freshly opened file instead of spawning a new one.
    /// A provisional input-method buffer belongs to this window even before it
    /// reaches `text` and marks the document dirty.
    var isReusableEmptyDocument: Bool {
        fileURL == nil && !isDirty && text == Self.starterMarkdown
            && editorSession.textView?.hasMarkedText() != true
    }

    /// Read-only editor capture. In particular, do not refresh a moved source or
    /// save an untitled draft as a side effect of creating a copy.
    func captureCopySource() throws -> DocumentCopySource {
        guard !isClosed, !backingFileMissing else { throw DocumentCopyFlowError.unavailable }
        guard editorSession.textView?.hasMarkedText() != true else { throw DocumentCopyFlowError.composing }
        guard let fileURL else { throw DocumentCopyFlowError.untitled }
        return DocumentCopySource(documentID: documentIdentity, revision: textMutationRevision,
                                  text: text, format: fileFormat, url: fileURL, identity: fileIdentity)
    }

    @discardableResult
    func save() -> Bool {
        // An unresolved external conflict blocks every write; asking again is
        // the only honest response to another ⌘S.
        if hasExternalConflict {
            externalConflictRequest = ExternalConflictRequest()
            return false
        }
        refreshFileLocation()
        if backingFileMissing { return presentSaveLocationAndWrite() }
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
        func entryPath(_ url: URL) -> String {
            url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
        }
        let vacantBackingURL = fileURL.flatMap { url -> URL? in
            var entry = stat()
            guard backingFileMissing, lstat(url.path, &entry) != 0, errno == ENOENT else { return nil }
            return url
        }
        guard let url = saveLocationPicker(fileURL?.lastPathComponent ?? "Untitled.md") else {
            return false
        }
        return write(to: url, requiresVacantDestination: vacantBackingURL.map(entryPath) == entryPath(url))
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

    /// Validation/copying runs off MainActor. Passing an insertion range applies
    /// the result through the retained text system, as a single native undo step.
    func insertImageAttachments(_ sources: [ImageAttachmentSource], folder: String,
                                handling: ImageFileHandling = .copy,
                                insertionRange: NSRange? = nil, expectedText: String? = nil) async -> String? {
        guard !sources.isEmpty, !isWorkingOnAttachments, !isClosed,
              !hasExternalConflict, !backingFileMissing,
              editorSession.textView?.hasMarkedText() != true,
              expectedText.map({ (text as NSString).isEqual(to: $0) }) ?? true else { return nil }
        let identity = documentIdentity, revision = textMutationRevision
        let selection = editorSession.textView?.selectedRange()
        let needsFolder = handling == .copy || sources.contains { if case .imageData = $0 { return true }; return false }
        if needsFolder, fileURL == nil { guard save(), fileURL != nil else { return nil } }
        let url = fileURL
        guard attachmentSnapshotIsCurrent(identity, revision: revision, url: url),
              selection == editorSession.textView?.selectedRange() else { return nil }
        let destination: AttachmentCollection.Destination?
        if needsFolder {
            guard let resolved = attachmentDestination(folder: folder) else { return nil }
            destination = resolved
        } else { destination = nil }
        guard attachmentSnapshotIsCurrent(identity, revision: revision, url: url) else { return nil }
        isWorkingOnAttachments = true
        defer { isWorkingOnAttachments = false }
        let output = await attachmentWorker(.insert(sources, handling, destination))
        refreshFileLocation()
        guard attachmentSnapshotIsCurrent(identity, revision: revision, url: url),
              selection == editorSession.textView?.selectedRange() else {
            reportAttachments(output, adopted: false, collection: false); return nil
        }
        if let range = insertionRange, !output.text.isEmpty {
            let original = text as NSString
            guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
                  range.location <= original.length, range.length <= original.length - range.location,
                  applyAttachmentEdit(changing: text,
                      to: original.replacingCharacters(in: range, with: output.text)) else {
                reportAttachments(output, adopted: false, collection: false); return nil
            }
            editorSession.textView?.setSelectedRange(NSRange(location: range.location + output.text.utf16.count, length: 0))
        }
        if !output.issues.isEmpty { reportAttachments(output, adopted: true, collection: false) }
        return output.text.isEmpty ? nil : output.text
    }

    func collectLocalImages(folder: String) async {
        guard !isWorkingOnAttachments, !isClosed, !hasExternalConflict, !backingFileMissing,
              editorSession.textView?.hasMarkedText() != true else { return }
        let identity = documentIdentity, revision = textMutationRevision
        let source = text
        if fileURL == nil { guard save(), fileURL != nil else { return } }
        let url = fileURL
        guard let destination = attachmentDestination(folder: folder),
              attachmentSnapshotIsCurrent(identity, revision: revision, url: url) else { return }
        isWorkingOnAttachments = true
        defer { isWorkingOnAttachments = false }
        let output = await attachmentWorker(.collect(source, destination))
        refreshFileLocation()
        guard attachmentSnapshotIsCurrent(identity, revision: revision, url: url),
              applyAttachmentEdit(changing: source, to: output.text) else {
            reportAttachments(output, adopted: false, collection: true); return
        }
        reportAttachments(output, adopted: true, collection: true)
    }

    private func applyAttachmentEdit(changing current: String, to updated: String) -> Bool {
        // An explicit group also works when a caller disables groupsByEvent.
        // Keep the entire collection separate from the preceding native typing.
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        return editorSession.applyUndoableEdit(changing: current, to: updated)
    }

    private func attachmentSnapshotIsCurrent(_ identity: UUID, revision: Int, url: URL?) -> Bool {
        !Task.isCancelled && !isClosed && documentIdentity == identity && textMutationRevision == revision && fileURL == url &&
            !hasExternalConflict && !backingFileMissing && editorSession.textView?.hasMarkedText() != true
    }

    private func attachmentDestination(folder: String) -> AttachmentCollection.Destination? {
        guard let baseURL, let fileURL else { return nil }
        let destination = ImageAttachmentManager.destination(toFolder: folder, documentDirectory: baseURL)
        var approvedDirectory: URL?
        if destination.isExternal {
            let approval = AttachmentApproval(document: fileURL.standardizedFileURL, directory: destination.directory)
            if !approvedAttachmentDestinations.contains(approval) {
                let confirmed = confirmExternalAttachmentDirectory?(destination.directory)
                    ?? presentExternalAttachmentConfirmation(destination.directory)
                guard confirmed else { return nil }
                approvedAttachmentDestinations.insert(approval)
            }
            approvedDirectory = destination.directory
        }
        return AttachmentCollection.Destination(documentDirectory: baseURL, folder: folder,
                                                 approvedExternalDirectory: approvedDirectory)
    }

    private func reportAttachments(_ output: AttachmentCollection.Output, adopted: Bool, collection: Bool) {
        var lines = [alertText(.attachmentWrittenCount, String(output.written))]
        if !adopted { lines.append(alertText(.attachmentStale)) }
        else { lines.append(alertText(.attachmentReferenceCount, String(output.references))) }
        if collection { lines.append(alertText(.attachmentCollectionScope)) }
        for issue in output.issues.prefix(8) {
            let reason = alertText(issue.reason)
            lines.append(issue.name.isEmpty ? reason : "\(reason): \(issue.name)")
        }
        if output.issues.count > 8 { lines.append(alertText(.alertHTMLExportMoreImages, String(output.issues.count - 8))) }
        alert = DocumentAlert(message: alertText(.attachmentReport), detail: lines.joined(separator: "\n\n"))
    }

    private func presentExternalAttachmentConfirmation(_ directory: URL) -> Bool {
        let prompt = NSAlert()
        prompt.alertStyle = .warning
        prompt.messageText = alertText(.alertExternalAttachmentDirectory)
        prompt.informativeText = alertText(.alertExternalAttachmentDirectoryDetail, directory.path)
        prompt.addButton(withTitle: alertText(.cancel))
        prompt.addButton(withTitle: alertText(.useAttachmentFolder))
        return prompt.runModal() == .alertSecondButtonReturn
    }

    /// Exports the rendered preview to a paginated PDF chosen by the user. This
    /// is a derived artifact, not the document's on-disk form: it does NOT change
    /// `fileURL` or `isDirty`, and Save As… still writes Markdown source. The
    /// current text is captured and rendered off the main actor, then
    /// an offscreen `PDFExporter` renders and writes the file; failures surface
    /// through the normal `alert` path.
    func exportPDF() async {
        // Ignore a second request while an export or print is still in flight;
        // otherwise the new exporter would replace the retained one and abandon
        // the first. Print and Export are mutually exclusive.
        guard !isClosed, !isProducingDerivedArtifact else { return }

        onRemoteImageBackingChanged?()
        let contextToken = remoteResourceContextToken
        guard let url = pdfDestinationPicker(pdfFileName) else { return }
        onRemoteImageBackingChanged?()
        guard resourceContextIsCurrent(contextToken), !isProducingDerivedArtifact, allowsExport(to: url) else {
            return
        }

        let preparationID = UUID()
        preparingDerivedArtifact = preparationID
        defer { if preparingDerivedArtifact == preparationID { preparingDerivedArtifact = nil } }
        let baseURL = self.baseURL
        let exportDocumentTitle = self.exportDocumentTitle
        let profile = exportProfileProvider()
        let snapshot = makeRenderSnapshot()
        let remoteImageBlockedLabel = alertText(.remoteImageBlocked)
        let rendered = await renderWorker.render(snapshot)
        refreshInheritedRemoteImages()
        guard resourceContextIsCurrent(contextToken), allowsExport(to: url) else { return }

        let exporter = pdfExporterFactory?(url, profile) ?? PDFExporter(destinationURL: url, profile: profile,
            canWriteDestination: { [weak self] in
                guard let self else { return false }
                return !self.exportDestinationIsSource(url)
            })
        pdfExporter = exporter
        exporter.export(
            html: rendered.html,
            outline: rendered.outline,
            baseURL: baseURL,
            remoteResourcePolicy: snapshot.remoteResourcePolicy,
            documentTitle: exportDocumentTitle,
            remoteImageBlockedLabel: remoteImageBlockedLabel
        ) { [weak self] result in
            guard let self, self.resourceContextIsCurrent(contextToken) else { return }
            self.pdfExporter = nil
            if case let .failure(error) = result {
                let detail = if case .sourceDestination = error as? PDFExporter.ExportError {
                    self.alertText(.alertExportSourceDestination)
                } else { error.localizedDescription }
                self.alert = DocumentAlert(
                    message: self.alertText(.alertCouldNotExport, url.lastPathComponent),
                    detail: detail
                )
            }
        }
    }

    /// Prints the rendered preview through the system print dialog. Like
    /// `exportPDF()`, this captures and renders the current text asynchronously.
    /// It never changes
    /// `fileURL`, `isDirty`, or autosave. Print and Export share the
    /// `isProducingDerivedArtifact` guard, so they are mutually exclusive.
    /// Failures surface through the normal `alert` path.
    func print() async {
        guard !isClosed, !isProducingDerivedArtifact else { return }
        onRemoteImageBackingChanged?()
        let contextToken = remoteResourceContextToken

        let preparationID = UUID()
        preparingDerivedArtifact = preparationID
        defer { if preparingDerivedArtifact == preparationID { preparingDerivedArtifact = nil } }
        let baseURL = self.baseURL
        let exportDocumentTitle = self.exportDocumentTitle
        let profile = exportProfileProvider()
        let snapshot = makeRenderSnapshot()
        let remoteImageBlockedLabel = alertText(.remoteImageBlocked)
        let rendered = await renderWorker.render(snapshot)
        refreshInheritedRemoteImages()
        guard resourceContextIsCurrent(contextToken) else { return }

        let printer = documentPrinterFactory()
        documentPrinter = printer
        printer.print(
            html: rendered.html,
            outline: rendered.outline,
            baseURL: baseURL,
            remoteResourcePolicy: snapshot.remoteResourcePolicy,
            profile: profile,
            documentTitle: exportDocumentTitle,
            remoteImageBlockedLabel: remoteImageBlockedLabel
        ) { [weak self] result in
            guard let self, self.resourceContextIsCurrent(contextToken) else { return }
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
    /// offline. Images that stay outside the file are named in a notice once it is
    /// written. Like PDF export and Print this is a derived artifact: it does NOT
    /// change `fileURL`, `isDirty`, or autosave. A snapshot is rendered in the
    /// background before writing. Mutually exclusive with the
    /// other export/print jobs (it no-ops while one is in flight).
    func exportHTML() async {
        guard !isClosed, !isProducingDerivedArtifact else { return }

        let contextToken = remoteResourceContextToken
        guard let url = htmlDestinationPicker(htmlFileName), resourceContextIsCurrent(contextToken),
              !isProducingDerivedArtifact, allowsExport(to: url) else {
            return
        }

        let preparationID = UUID()
        preparingDerivedArtifact = preparationID
        defer { if preparingDerivedArtifact == preparationID { preparingDerivedArtifact = nil } }
        let snapshot = makeRenderSnapshot()
        // The worker also performs file reads, bounded decoding and base64
        // encoding; the export keeps using the captured document/base URL.
        let export = await renderWorker.renderSelfContainedHTML(snapshot)
        guard resourceContextIsCurrent(contextToken), allowsExport(to: url) else { return }
        do {
            try export.html.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            alert = DocumentAlert(
                message: alertText(.alertCouldNotExport, url.lastPathComponent),
                detail: error.localizedDescription
            )
            return
        }
        if let notice = htmlExportNotice(for: export, fileName: url.lastPathComponent) {
            alert = notice
        }
    }

    /// How many image names each group of the HTML export notice lists.
    private static let maximumListedImages = 5

    /// Names known image omissions and explains the offline diagram boundary.
    /// Diagram presence alone does not establish that an image was omitted.
    /// Each image group is capped so remote images cannot hide a missing local one.
    private func htmlExportNotice(for export: SelfContainedHTMLBuilder.Output, fileName: String) -> DocumentAlert? {
        let localNames = export.unembeddedLocalImages.map { name in
            guard let reason = export.localImageFailures[name] else { return name }
            return "\(name) — \(alertText(reason.noticeKey))"
        }
        let groups = [
            (heading: alertText(.alertHTMLExportRemoteImages), names: export.remoteImages),
            (heading: alertText(.alertHTMLExportLocalImages), names: localNames)
        ].filter { !$0.names.isEmpty }
        guard !groups.isEmpty || export.containsDiagrams else { return nil }

        var sections = groups.map { group in
            var lines = [group.heading] + group.names.prefix(Self.maximumListedImages)
            if group.names.count > Self.maximumListedImages {
                lines.append(alertText(.alertHTMLExportMoreImages, String(group.names.count - Self.maximumListedImages)))
            }
            return lines.joined(separator: "\n")
        }
        if export.containsDiagrams {
            sections.append(alertText(.alertHTMLExportDiagramResources))
        }
        return DocumentAlert(
            message: alertText(groups.isEmpty ? .alertHTMLExported : .alertHTMLExportIncomplete, fileName),
            detail: sections.joined(separator: "\n\n")
        )
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

    /// Export the committed editor text, including unsaved edits. Untitled
    /// documents use the converter's private directory for relative resources.
    private func exportConverted(to format: DocumentExportFormat) {
        guard !isClosed, !isProducingDerivedArtifact, !hasExternalConflict,
              pendingExternalReload == nil else { return }
        let formatName = format.fileExtension.uppercased()
        guard pandocAvailabilityProvider() else {
            alert = DocumentAlert(
                message: alertText(.alertPandocRequired, formatName),
                detail: alertText(.alertPandocRequiredDetail)
            )
            return
        }
        guard editorSession.textView?.hasMarkedText() != true else {
            alert = DocumentAlert(message: alertText(.conversionDestinationTitle, formatName),
                                  detail: alertText(.copyFinishComposition))
            return
        }
        refreshFileLocation()

        // The native picker runs a nested event loop. Reserve this operation
        // before showing it, so an edit, reload or another command cannot hand
        // its stale destination to the converter.
        let id = UUID()
        conversion = .choosingDestination(id)
        defer {
            if case .choosingDestination(let pendingID) = conversion, pendingID == id {
                conversion = nil
            }
        }
        let defaultName = conversionFileName(for: format)
        let destination = if let conversionDestinationPicker {
            conversionDestinationPicker(format, defaultName)
        } else {
            presentConversionDestination(format: format, defaultName: defaultName)
        }
        guard conversion?.operationID == id, let destination else { return }
        refreshFileLocation()
        guard conversion?.operationID == id else { return }
        guard editorSession.textView?.hasMarkedText() != true else {
            stopConversion(sourceChanged: true)
            return
        }
        guard allowsExport(to: destination) else { return }

        let converter = documentConverterFactory()
        conversion = .running(id, format, converter)
        converter.convert(
            markdown: text,
            format: format,
            resourceDirectory: baseURL,
            destination: destination
        ) { [weak self] result in
            guard let self, self.conversion?.operationID == id else { return }
            self.conversion = nil
            if case let .failure(error) = result {
                let detail = (error as? PandocConverter.ConversionError)?.detail(using: self.alertText)
                    ?? error.localizedDescription
                self.alert = DocumentAlert(
                    message: self.alertText(.alertCouldNotExport, destination.lastPathComponent),
                    detail: detail
                )
            } else {
                self.alert = DocumentAlert(
                    message: self.alertText(.alertExternalFormatExported, destination.lastPathComponent),
                    detail: self.alertText(.alertExternalFormatNetworkBoundary)
                )
            }
        }
    }

    /// Detach before canceling. A converter can call back synchronously when
    /// canceled or complete after a different operation has started.
    func cancelConversion() {
        stopConversion()
    }

    private func stopConversion(sourceChanged: Bool = false) {
        guard let conversion, !sourceChanged || conversion.operationID != nil else { return }
        self.conversion = sourceChanged ? .sourceChanged : nil
        if case .running(_, _, let converter) = conversion { converter.cancel() }
    }

    private func allowsExport(to destination: URL) -> Bool {
        guard exportDestinationIsSource(destination) else { return true }
        alert = DocumentAlert(message: alertText(.alertCouldNotExport, destination.lastPathComponent),
                              detail: alertText(.alertExportSourceDestination))
        return false
    }

    private func exportDestinationIsSource(_ destination: URL) -> Bool {
        guard let fileURL else { return false }
        let source = fileIdentity?.resolve(fallback: fileURL) ?? fileURL
        if source.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() { return true }
        var sourceInfo = stat()
        var destinationInfo = stat()
        return stat(source.path, &sourceInfo) == 0 && stat(destination.path, &destinationInfo) == 0
            && sourceInfo.st_dev == destinationInfo.st_dev && sourceInfo.st_ino == destinationInfo.st_ino
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

    private func presentConversionDestination(
        format: DocumentExportFormat,
        defaultName: String
    ) -> URL? {
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.title = alertText(.conversionDestinationTitle, format.fileExtension.uppercased())
        panel.message = alertText(.conversionDestinationNotice)
        panel.directoryURL = baseURL
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultName
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Relays a find action from a menu command to the active document surface.
    func requestFind(_ action: FindCommand.Action) {
        findCommand = FindCommand(action)
    }

    /// Wait for the current text, including unsaved edits in an already-open
    /// document. A newer link, a different document, or a close cancels this jump.
    func requestHeadingNavigation(_ fragment: String?) {
        headingNavigationTask?.cancel()
        headingNavigationTask = nil
        guard let fragment else { return }
        let identity = documentIdentity
        headingNavigationTask = Task { [weak self] in
            guard let self else { return }
            await self.flushPendingRender()
            guard !Task.isCancelled, !self.isClosed, self.documentIdentity == identity else { return }
            if fragment.isEmpty {
                self.editorJumpAnchor = nil
                self.previewJumpAnchor = nil
                self.jumpHeadingID = nil
                self.jumpLine = 1
                self.jumpFraction = 0
            } else if let heading = self.rendered.outline.heading(forID: fragment) {
                self.jump(to: heading)
            } else {
                self.alert = DocumentAlert(message: self.alertText(.alertHeadingNotFound),
                    detail: self.alertText(.alertHeadingNotFoundDetail, fragment))
            }
        }
    }

    func reportMissingLocalLink(_ url: URL) {
        alert = DocumentAlert(message: alertText(.alertCouldNotOpen, url.lastPathComponent),
                              detail: alertText(.recentDocumentMissingDetail))
    }

    func jump(to heading: Heading) {
        headingNavigationTask?.cancel()
        headingNavigationTask = nil
        editorJumpAnchor = nil
        previewJumpAnchor = nil
        jumpFraction = nil
        jumpLine = heading.line
        jumpHeadingID = heading.id
    }

    struct PreviewFormulaTarget {
        fileprivate let identity: UUID
        let revision: Int
        let line: Int
        let edit: DisplayFormulaEdit?
    }

    enum PreviewFormulaResult { case applied, unchanged, requiresSource, stale }

    func previewFormulaTarget(line: Int, renderedAt revision: Int) -> PreviewFormulaTarget? {
        guard !isClosed, hasCurrentResourcePreview, revision == renderedTextMutationRevision,
              revision == textMutationRevision, line > 0, line <= rendered.stats.lines else { return nil }
        return PreviewFormulaTarget(identity: documentIdentity, revision: revision, line: line,
                                    edit: rendered.displayFormulaEdits[line])
    }

    func isCurrent(_ target: PreviewFormulaTarget) -> Bool {
        guard target.identity == documentIdentity,
              let current = previewFormulaTarget(line: target.line, renderedAt: target.revision) else { return false }
        return current.edit == target.edit
    }

    func applyPreviewFormula(_ target: PreviewFormulaTarget, replacement: String,
                             beforeMutation: () -> Bool = { true },
                             isReading: @escaping @MainActor () -> Bool) async -> PreviewFormulaResult {
        guard !Task.isCancelled, isReading(), isCurrent(target) else { return .stale }
        guard let edit = target.edit,
              let replacement = DisplayFormulaEdit.validatedReplacement(replacement) else { return .requiresSource }
        let currentText = text
        let source = currentText as NSString
        guard edit.range.location >= 0, edit.range.length >= 0, edit.range.location <= source.length,
              edit.range.length <= source.length - edit.range.location,
              (source.substring(with: edit.range) as NSString).isEqual(to: edit.source) else { return .stale }
        guard !(edit.source as NSString).isEqual(to: replacement) else { return .unchanged }

        // New TeX can turn this line into the previous table's row or link
        // definition. Reuse the renderer off the main actor to prove ownership
        // before authorizing the single native replacement.
        let proposed = source.replacingCharacters(in: edit.range, with: replacement)
        let candidate = await renderWorker.render(makeRenderSnapshot(text: proposed))
        guard !Task.isCancelled, isReading(), isCurrent(target) else { return .stale }
        let newRange = NSRange(location: edit.range.location, length: replacement.utf16.count)
        guard let mapped = candidate.displayFormulaEdits[target.line], mapped.range == newRange,
              (mapped.source as NSString).isEqual(to: replacement) else { return .requiresSource }
        guard beforeMutation() else { return .stale }

        let applied = await editorSession.applyPreviewFormulaEdit(changing: currentText, range: edit.range,
                                                                  replacement: replacement) {
            isReading() && self.isCurrent(target)
        }
        return applied ? .applied : .stale
    }

    /// Sets the task-list marker on the 1-based source `line` to `checked`,
    /// in response to a checkbox click in the preview. `revision` is the
    /// `sourceLineRevision` the clicked page was rendered from: the line is that
    /// page's number, so a request from any other revision is refused rather
    /// than applied to whatever task sits on that line now. The request is
    /// also validated before anything is written — the line must exist and must
    /// be a task item — so a malformed preview message can never corrupt
    /// unrelated text. Applying an absolute state (instead of flipping) keeps
    /// duplicate messages idempotent; re-render, dirty marking, and autosave
    /// ride the normal `text` pipeline. The change goes through the editor's
    /// text view, so it is one undoable step ordered with the user's typing.
    /// Returns whether the request was accepted; a caller must put a refused
    /// click's checkbox back, since no re-render follows it.
    @discardableResult
    func toggleTask(atLine line: Int, to checked: Bool, renderedAt revision: Int) -> Bool {
        guard revision == sourceLineRevision,
              let lineRange = Self.rangeOfLine(line, in: text),
              let updated = Self.settingTaskMarker(in: String(text[lineRange]), to: checked) else {
            return false
        }
        let toggled = text.replacingCharacters(in: lineRange, with: updated)
        // A repeated request for the state the line already has changes nothing,
        // and must not leave an empty step on the undo stack.
        guard toggled != text else { return true }
        if !editorSession.applyUndoableEdit(changing: text, to: toggled) {
            text = toggled
        }
        // A marker moves no line, so the page still addresses this text: a
        // second box clicked before the re-render lands is not a stale click.
        sourceLineRevision = revision
        // A checkbox click is a discrete action, not sustained typing: render
        // immediately so the preview reflects the toggle without debounce lag.
        renderImmediately()
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
        let target = DocumentLinkTarget(url)
        if load(from: target.fileURL) {
            requestHeadingNavigation(target.fragment)
        }
    }

    func matchesFolderFile(at url: URL) -> Bool {
        guard fileIdentity?.isFolderFile == true, let copyFileReference else { return false }
        return (try? copyFileReference.validate(at: url)) != nil
    }

    /// Explicitly opening a new file at the missing file's path frees that
    /// path for the new editor while keeping the previous editor as a draft.
    func detachUnavailableFolderDraft(replacedBy url: URL, verifiedReference: DocumentCopyFileReference? = nil) {
        guard backingFileMissing, let identity = fileIdentity, identity.isFolderFile,
              let fileURL else { return }
        let samePath = verifiedReference != nil ? fileURL.path == url.path
            : fileURL.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path
        guard samePath, let replacement = verifiedReference ?? (try? DocumentCopyFileReference.open(at: url)),
              !identity.matchesFolderEntry(replacement) else { return }
        stopWatchingFile()
        copyFileReference = nil
        fileIdentity = nil
        self.fileURL = nil
        remoteImageFileReference = nil
        resetRemoteImageChoices()
        lastKnownFingerprint = nil
        backingFileMissing = false
        updateHistoryIdentity(nil)
        replaceRemoteResourceContext()
        onRemoteImageBackingChanged?()
        renderImmediately()
        persistRecoveryNow()
    }

    func openVerifiedFolderFile(_ opened: FolderIndex.OpenedFile, decoded: MarkdownFileDecoder.DecodedFile?,
                                replacingCleanPreview: Bool = false) throws {
        guard !isClosed, isReusableEmptyDocument || (replacingCleanPreview && !isDirty) else {
            throw FolderIndex.Failure.fileUnavailable
        }
        let historyID = historyIdentity(at: opened.url)
        try opened.validate()
        guard let decoded else {
            showUndecodableFile(opened.url)
            return
        }
        if replacingCleanPreview {
            approvedAttachmentDestinations.removeAll()
            jumpLine = nil
            jumpHeadingID = nil
            jumpFraction = nil
            editorJumpAnchor = nil
            previewJumpAnchor = nil
            editorLineSelection = nil
            editorSession.revealSelectionOnNextHost = false
        }
        installLoadedFile(decoded, url: opened.url, data: opened.data, fingerprint: opened.fingerprint,
                          identity: DocumentFileIdentity(folderReference: opened.fileReference),
                          reference: opened.fileReference, historyID: historyID)
        if replacingCleanPreview, let textView = editorSession.textView {
            let start = NSRange(location: 0, length: 0)
            textView.setSelectedRange(start)
            textView.scrollRangeToVisible(start)
        }
    }

    /// Consume validated bytes without another path read. The pinned identity
    /// remains authoritative across the UI handoff and subsequent copy saves.
    func openVerifiedCopy(_ opened: DocumentCopyOpenData, decoded: MarkdownFileDecoder.DecodedFile) throws {
        let receipt = opened.receipt
        guard isReusableEmptyDocument, !isClosed else { throw DocumentCopyOpenError.invalidData }
        let historyID = historyIdentity(at: receipt.destinationURL)
        try DocumentCopyReader.validateDirectory(receipt)
        try receipt.fileReference.validate(at: receipt.destinationURL)
        let fingerprint = DocumentFileFingerprint(
            modificationDate: DocumentFileFingerprint.modificationDate(at: receipt.destinationURL),
            contentHash: receipt.contentHash)
        installLoadedFile(decoded, url: receipt.destinationURL, data: opened.data, fingerprint: fingerprint,
                          identity: DocumentFileIdentity(copyReference: receipt.fileReference),
                          reference: receipt.fileReference, historyID: historyID)
    }

    private func installLoadedFile(_ decoded: MarkdownFileDecoder.DecodedFile, url: URL, data: Data,
                                   fingerprint: DocumentFileFingerprint, identity: DocumentFileIdentity,
                                   reference: DocumentCopyFileReference? = nil,
                                   imageReference: DocumentCopyFileReference? = nil, historyID: DocumentHistoryFileID?) {
        fileFormat = decoded.format
        copyFileReference = reference
        remoteImageFileReference = reference ?? imageReference
        fileIdentity = identity
        backingFileMissing = false
        encodingWarningShown = false
        encodingConversionRequest = nil
        setDocumentText(decoded.text, fileURL: url, dirty: false)
        lastKnownFingerprint = fingerprint
        hasExternalConflict = false
        externalConflictRequest = nil
        pendingExternalReload = nil
        pendingReloadDiscardRevision = nil
        startWatchingFile()
        onRemoteImageBackingChanged?()
        persistRecoveryNow()
        recordHistory(data, reason: .opened, fileID: historyID)
    }

    private func showUndecodableFile(_ url: URL) {
        alert = DocumentAlert(
            message: alertText(.alertUndecodableFile, url.lastPathComponent),
            detail: alertText(.alertUndecodableFileDetail)
        )
    }

    @discardableResult
    private func load(from url: URL) -> Bool {
        do {
            // Read the raw bytes once: the text decodes from them and the
            // fingerprint hashes them, so the stored hash always matches the
            // exact on-disk content (no re-encoding drift).
            let readID = historyIdentity(at: url)
            let (data, imageReference) = try readOrdinaryDocument(at: url)
            let historyID = unchangedHistoryIdentity(readID, at: url)
            guard let decoded = MarkdownFileDecoder.decode(data) else {
                showUndecodableFile(url)
                return false
            }
            installLoadedFile(decoded, url: url, data: data, fingerprint: .of(data: data, at: url),
                              identity: DocumentFileIdentity(url: url),
                              imageReference: imageReference, historyID: historyID)
            let directory = url.deletingLastPathComponent()
            Task.detached(priority: .background) { LegacyPreviewCleaner.clean(in: directory) }
            return true
        } catch {
            alert = DocumentAlert(
                message: alertText(.alertCouldNotOpen, url.lastPathComponent),
                detail: error.localizedDescription
            )
            return false
        }
    }

    /// Folder inheritance requires a pin to the bytes actually read. Ordinary
    /// opens retain their existing fallback for links and larger files.
    private func readOrdinaryDocument(at url: URL) throws -> (Data, DocumentCopyFileReference?) {
        if FolderIndex.isMarkdownExtension(url.pathExtension),
           let reference = try? DocumentCopyFileReference.open(at: url),
           let data = try? reference.read(at: url, maximumCount: FolderIndex.maximumOpenBytes) {
            return (data, reference)
        }
        return (try Data(contentsOf: url), nil)
    }

    @discardableResult
    private func write(to requestedURL: URL, automatically: Bool = false, requiresVacantDestination: Bool = false) -> Bool {
        guard !isClosed else { return false }
        // Preserve destination intent across the modal encoding prompt: the
        // watcher may follow a rename while that nested run loop is active.
        let folderBacked = fileIdentity?.isFolderFile == true
        let writingBackingFile = requestedURL == fileURL || (folderBacked &&
            requestedURL.resolvingSymlinksInPath().path == fileURL?.resolvingSymlinksInPath().path)
        let writingDocumentIdentity = documentIdentity

        var outputFormat = fileFormat
        var data = outputFormat.encode(text)
        if data == nil {
            if automatically {
                if !encodingWarningShown {
                    encodingWarningShown = true
                    encodingConversionRequest = UUID()
                }
                return false
            }
            guard confirmEncodingConversion(fileFormat.encodingLabel) else { return false }
            outputFormat.encoding = .utf8
            data = outputFormat.encode(text)
        }
        guard let writtenData = data else { return false }
        // An encoding confirmation runs a nested event loop. Resolve and verify
        // the destination only after it returns, before accepting any write.
        guard !isClosed, !hasExternalConflict, documentIdentity == writingDocumentIdentity else { return false }
        // Resolve again at the write boundary, even before the watcher fires.
        if writingBackingFile { refreshFileLocation() }
        let url = writingBackingFile && !requiresVacantDestination ? (fileURL ?? requestedURL) : requestedURL
        if backingFileMissing && (automatically || (writingBackingFile && (copyFileReference != nil || folderBacked))) {
            if !automatically {
                alert = DocumentAlert(message: alertText(.alertCouldNotSave, url.lastPathComponent),
                                      detail: alertText(folderBacked ? .folderSaveUnavailable : .copySaveUnavailable))
            }
            return false
        }
        if !requiresVacantDestination, url == fileURL, let lastKnown = lastKnownFingerprint {
            let comparison = DocumentFileFingerprint.comparison(
                lastKnown: lastKnown, current: DocumentFileFingerprint.current(at: url, reference: copyFileReference))
            if comparison == .contentChanged {
                raiseExternalConflict()
                return false
            }
            // A missing fingerprint also means an unreadable or nonregular
            // replacement. An ordinary Save has no permission to replace it.
            if comparison == .missing {
                markBackingFileMissing()
                if !automatically { reportUnverifiedSaveDestination(url) }
                return false
            }
        }

        do {
            cancelAutosave()
            let priorHistoryID = writingBackingFile ? historyIdentity(at: url) : nil
            let needsLinkedSaveRecovery = !requiresVacantDestination && Self.hasMultipleHardLinks(at: url)
            if needsLinkedSaveRecovery {
                if writingBackingFile, !isDirty, lastKnownFingerprint?.contentHash == DocumentFileFingerprint.hash(of: writtenData) {
                    return true
                }
                if !persistRecoveryNow() {
                    if !automatically {
                        alert = DocumentAlert(message: alertText(.alertCouldNotSave, url.lastPathComponent),
                                              detail: alertText(.alertRecoveryRequiredForLinkedSave))
                    }
                    return false
                }
            }
            let (newCopyReference, savedHistoryID, imageReference) = try Self.writePreservingMetadata(writtenData, to: url,
                replacingReference: writingBackingFile ? copyFileReference : nil, copyIO: copySaveIO,
                protectsLinkedDestination: folderBacked,
                requiresVacantDestination: requiresVacantDestination,
                securedLinkedSaveRecovery: needsLinkedSaveRecovery,
                captureHistoryIdentity: historyRepository != nil,
                trackImageIdentity: FolderIndex.isMarkdownExtension(url.pathExtension)
                    && writtenData.count <= FolderIndex.maximumOpenBytes,
                verifyNewFile: keepsLocalHistory() && historyRepository?.canRecord(byteCount: writtenData.count) == true)
            copyFileReference = newCopyReference
            remoteImageFileReference = newCopyReference ?? imageReference
            lastKnownFingerprint = DocumentFileFingerprint.of(data: writtenData, at: url)
            fileURL = url
            fileIdentity = newCopyReference.map {
                folderBacked ? DocumentFileIdentity(folderReference: $0) : DocumentFileIdentity(copyReference: $0)
            } ?? DocumentFileIdentity(url: url)
            fileFormat = outputFormat
            isDirty = false
            backingFileMissing = false
            encodingWarningShown = false
            encodingConversionRequest = nil
            hasExternalConflict = false
            startWatchingFile()
            onRemoteImageBackingChanged?()
            persistRecoveryNow()
            recordHistory(writtenData, reason: .saved, fileID: savedHistoryID, replacing: priorHistoryID)
            return true
        } catch {
            if error is UnverifiedSaveDestination {
                reportUnverifiedSaveDestination(url)
            } else {
                alert = DocumentAlert(message: alertText(.alertCouldNotSave, url.lastPathComponent),
                                      detail: error is DocumentCopyOpenError
                                        ? alertText(folderBacked ? .folderSaveUnavailable : .copySaveUnavailable)
                                        : error.localizedDescription)
            }
            persistRecoveryNow()
            return false
        }
    }

    private struct UnverifiedSaveDestination: Error {}

    private func reportUnverifiedSaveDestination(_ url: URL) {
        alert = DocumentAlert(message: alertText(.alertCouldNotSave, url.lastPathComponent),
                              detail: alertText(.alertUnverifiedSaveDestination))
    }

    /// A pinned document always replaces a directory entry atomically and
    /// retains its independent save route if another hard link appears.
    private static func writePreservingMetadata(_ data: Data, to url: URL,
                                                replacingReference: DocumentCopyFileReference?,
                                                copyIO: DocumentCopySaveIO = .init(),
                                                protectsLinkedDestination: Bool,
                                                requiresVacantDestination: Bool,
                                                securedLinkedSaveRecovery: Bool,
                                                captureHistoryIdentity: Bool,
                                                trackImageIdentity: Bool,
                                                verifyNewFile: Bool) throws
        -> (DocumentCopyFileReference?, DocumentHistoryFileID?, DocumentCopyFileReference?) {
        try replacingReference?.validate(at: url)
        func inspectDestination() throws -> DocumentCopyFileIdentity? {
            if protectsLinkedDestination, let replacingReference {
                return try DocumentCopyFileReference.open(at: url, matching: replacingReference.identity,
                                                          noFollowAncestors: true).identity
            }
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                if errno == ENOENT { return nil }
                throw UnverifiedSaveDestination()
            }
            if !protectsLinkedDestination, info.st_mode & S_IFMT == S_IFLNK {
                guard stat(url.path, &info) == 0 else { throw UnverifiedSaveDestination() }
            }
            guard info.st_mode & S_IFMT == S_IFREG, access(url.path, R_OK) == 0 else {
                throw UnverifiedSaveDestination()
            }
            if protectsLinkedDestination, info.st_nlink != 1 { throw DocumentCopyOpenError.changed }
            return DocumentCopyFileIdentity(info)
        }
        let destinationIdentity = try inspectDestination()
        if requiresVacantDestination, destinationIdentity != nil { throw UnverifiedSaveDestination() }
        func historyIdentity(matching descriptor: Int32) -> DocumentHistoryFileID? {
            var written = stat()
            guard captureHistoryIdentity, descriptor >= 0,
                  let identity = DocumentHistoryFileID(url: url),
                  fstat(descriptor, &written) == 0, identity.matches(written) else { return nil }
            return identity
        }

        func matchingImageReference(_ reference: DocumentCopyFileReference?) -> DocumentCopyFileReference? {
            guard let reference, (try? reference.validate(at: url)) != nil else { return nil }
            return reference
        }

        let manager = FileManager.default
        guard let destinationIdentity else {
            if replacingReference != nil { throw DocumentCopyOpenError.unavailable }
            if requiresVacantDestination {
                let replacement = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: url, create: true)
                defer { try? manager.removeItem(at: replacement) }
                let staged = replacement.appendingPathComponent(UUID().uuidString)
                try data.write(to: staged)
                let descriptor = captureHistoryIdentity ? Darwin.open(staged.path, O_EVTONLY | O_CLOEXEC) : -1
                let imageReference = trackImageIdentity ? try? DocumentCopyFileReference.open(at: staged) : nil
                defer { if descriptor >= 0 { Darwin.close(descriptor) } }
                guard renamex_np(staged.path, url.path, UInt32(RENAME_EXCL)) == 0 else {
                    if errno == EEXIST { throw UnverifiedSaveDestination() }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                return (nil, historyIdentity(matching: descriptor), matchingImageReference(imageReference))
            }
            try data.write(to: url, options: .atomic)
            let imageReference: DocumentCopyFileReference?
            if trackImageIdentity, let pin = try? DocumentCopyFileReference.open(at: url),
               let current = try? pin.read(at: url, expectedCount: data.count), current == data {
                imageReference = pin
            } else {
                imageReference = nil
            }
            // Foundation's new-file write does not expose its temporary
            // descriptor. Confirm the first save's bytes before indexing it.
            guard captureHistoryIdentity else { return (nil, nil, imageReference) }
            let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { return (nil, nil, imageReference) }
            let bytes = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? bytes.close() }
            guard let identity = historyIdentity(matching: bytes.fileDescriptor) else { return (nil, nil, imageReference) }
            if !verifyNewFile { return (nil, identity, imageReference) }
            guard let current = try? (bytes.read(upToCount: data.count + 1) ?? Data()),
                  current == data, historyIdentity(matching: bytes.fileDescriptor) == identity else { return (nil, nil, imageReference) }
            return (nil, identity, imageReference)
        }
        if replacingReference == nil && !protectsLinkedDestination && hasMultipleHardLinks(at: url) {
            // Replacing an inode severs its other names. For a hard-linked file,
            // update that inode after securing a recovery snapshot instead.
            guard securedLinkedSaveRecovery else { throw UnverifiedSaveDestination() }
            let original = try Data(contentsOf: url)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(handle.fileDescriptor, &info) == 0, DocumentCopyFileIdentity(info) == destinationIdentity,
                  try inspectDestination() == destinationIdentity else { throw UnverifiedSaveDestination() }
            do {
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: data)
                try handle.synchronize()
            } catch {
                try? handle.truncate(atOffset: 0)
                try? handle.write(contentsOf: original)
                try? handle.synchronize()
                throw error
            }
            return (nil, historyIdentity(matching: handle.fileDescriptor), nil)
        }
        let replacement = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                          appropriateFor: url, create: true)
        defer { try? manager.removeItem(at: replacement) }
        let temporary = replacement.appendingPathComponent(UUID().uuidString)
        if replacingReference != nil { try copyIO.writeTemporary(data, temporary) }
        else { try data.write(to: temporary) }
        // replaceItemAt preserves the original creation time. Read the new
        // identity after replacement and match it against the staged inode
        // held open here, even if another process replaces the public path.
        let historyDescriptor = captureHistoryIdentity ? Darwin.open(temporary.path, O_EVTONLY | O_CLOEXEC) : -1
        defer { if historyDescriptor >= 0 { Darwin.close(historyDescriptor) } }
        let reference: DocumentCopyFileReference?
        let imageReference = trackImageIdentity && replacingReference == nil
            ? try? DocumentCopyFileReference.open(at: temporary) : nil
        if let replacingReference {
            reference = try DocumentCopyFileReference.open(at: temporary)
            try replacingReference.validate(at: url)
            guard try inspectDestination() == destinationIdentity else { throw UnverifiedSaveDestination() }
            try copyIO.replace(url, temporary)
        } else {
            reference = nil
            guard try inspectDestination() == destinationIdentity, !hasMultipleHardLinks(at: url) else {
                throw UnverifiedSaveDestination()
            }
            _ = try manager.replaceItemAt(url, withItemAt: temporary, backupItemName: nil, options: [])
        }
        try reference?.validate(at: url)
        return (reference, historyIdentity(matching: historyDescriptor), matchingImageReference(imageReference))
    }

    private static func hasMultipleHardLinks(at url: URL) -> Bool {
        var info = stat()
        return stat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_nlink > 1
    }

    func resolveEncodingConversion(convertToUTF8: Bool) {
        encodingConversionRequest = nil
        guard convertToUTF8 else { return }
        fileFormat.encoding = .utf8
        encodingWarningShown = false
        persistRecoveryNow()
        _ = save()
    }

    private func setDocumentText(_ newText: String, fileURL newFileURL: URL?, dirty: Bool) {
        resetRemoteImageChoices()
        replaceRemoteResourceContext()
        headingNavigationTask?.cancel()
        headingNavigationTask = nil
        cancelAutosave()
        isLoading = true
        text = newText
        // Another document's history does not apply to this one.
        editorSession.resetText(to: newText)
        fileURL = newFileURL
        isDirty = dirty
        renderImmediately()
        documentIdentity = UUID()
        isLoading = false
    }

    /// Keep one active parse and one pending revision, without retaining a
    /// document snapshot for every keystroke while the worker is busy.
    private func scheduleRender(delay: Duration? = nil) {
        guard !isClosed else { return }
        renderGeneration &+= 1
        let generation = renderGeneration
        hasPendingRender = true
        renderDebounceTask?.cancel()
        let delay = delay ?? renderDebounce
        isDebouncingRender = delay > .zero
        renderDebounceTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled, let self, self.renderGeneration == generation else { return }
            self.isDebouncingRender = false
            self.startRenderIfNeeded()
        }
    }

    private func startRenderIfNeeded() {
        guard !isClosed, renderTask == nil, hasPendingRender else { return }
        refreshInheritedRemoteImages()
        let contextToken = remoteResourceContextToken
        let generation = renderGeneration
        let revision = sourceLineRevision
        let mutationRevision = textMutationRevision
        let snapshot = makeRenderSnapshot()
        let worker = renderWorker
        renderTask = Task { [weak self] in
            let result = await worker.render(snapshot)
            guard let self else { return }
            self.refreshInheritedRemoteImages()
            self.renderTask = nil
            if self.renderGeneration == generation, self.resourceContextIsCurrent(contextToken) {
                self.renderedSourceLineRevision = revision
                self.renderedTextMutationRevision = mutationRevision
                self.renderedEditableFormulaLines = Set(result.displayFormulaEdits.keys)
                self.rendered = result
                self.renderedRemoteResourceContextToken = contextToken
                self.hasPendingRender = false
            } else if !self.isDebouncingRender {
                self.startRenderIfNeeded()
            }
        }
    }

    func renderImmediately() { scheduleRender(delay: .zero) }

    func reRenderForSettingsChange() { renderImmediately() }

    private func makeRenderSnapshot(text source: String? = nil) -> DocumentRenderSnapshot {
        let preferences = renderConfigProvider()
        let syntax = syntaxConfigProvider()
        return DocumentRenderSnapshot(text: source ?? text, baseURL: baseURL,
            citationStyle: preferences.citationStyle, numberAllEquations: preferences.numberAllEquations,
            inlineFeatures: syntax.0, alertLanguage: syntax.1,
            remoteResourcePolicy: remoteResourcePolicy,
            offlineHTMLLabels: OfflineHTMLLabels(remoteImageBlocked: alertText(.offlineHTMLRemoteImageBlocked),
                                                 localImageUnavailable: alertText(.offlineHTMLLocalImageUnavailable)))
    }

    /// Await the latest generation without blocking the main actor. If an edit
    /// arrives during the wait, continue until that newer generation is published.
    func flushPendingRender() async {
        if isDebouncingRender { renderImmediately() }
        while hasPendingRender {
            if let renderTask { await renderTask.value }
            else { await renderDebounceTask?.value }
        }
    }

    // MARK: External file changes

    /// Creates (once) and (re-)arms the watcher on the current backing file.
    private func startWatchingFile() {
        guard let fileURL, !(backingFileMissing && fileIdentity?.isFolderFile == true) else {
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
        refreshFileLocation()
        guard let fileURL, let lastKnown = lastKnownFingerprint, !isLoading, !isClosed,
              !(backingFileMissing && fileIdentity?.isFolderFile == true) else { return }
        let url = fileURL
        let reference = copyFileReference
        Task.detached(priority: .utility) { [weak self] in
            let current = DocumentFileFingerprint.current(at: url, reference: reference)
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
        guard fileURL == url, lastKnownFingerprint == lastKnown, !isClosed else { return }
        if let copyFileReference, (try? copyFileReference.validate(at: url)) == nil {
            refreshFileLocation()
            return
        }
        switch ExternalChangeDecision.action(
            for: DocumentFileFingerprint.comparison(lastKnown: lastKnown, current: current),
            isDirty: isDirty
        ) {
        case .ignore:
            // Same bytes; refresh the date so a touch is not re-hashed forever.
            if let current {
                lastKnownFingerprint = current
                if copyFileReference == nil { fileIdentity = DocumentFileIdentity(url: url) }
                backingFileMissing = false
                updateHistoryIdentity(historyIdentity(at: url))
            }
        case .reloadPreservingViewport:
            beginExternalReload()
        case .presentConflict:
            raiseExternalConflict()
        case .markDeletedDirty:
            markBackingFileMissing()
        }
    }

    /// Starts the viewport-preserving reload handshake: `ContentView` observes
    /// `pendingExternalReload`, captures the active surface's live anchor, and
    /// calls `completeExternalReload(anchor:)`.
    private func beginExternalReload(discardingEdits: Bool = false) {
        if discardingEdits {
            pendingReloadDiscardRevision = textMutationRevision
        }
        guard pendingExternalReload == nil else { return }
        stopConversion(sourceChanged: true)
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
        let discardRevision = pendingReloadDiscardRevision
        pendingReloadDiscardRevision = nil
        refreshFileLocation()
        guard let fileURL else { return }

        let readID = historyIdentity(at: fileURL)
        let loaded: (Data, DocumentCopyFileReference?)? = if backingFileMissing {
            nil
        } else if let copyFileReference {
            (try? copyFileReference.read(at: fileURL)).map { ($0, copyFileReference) }
        } else {
            try? readOrdinaryDocument(at: fileURL)
        }
        guard let (data, imageReference) = loaded, let decoded = MarkdownFileDecoder.decode(data) else {
            alert = DocumentAlert(
                message: alertText(.alertCouldNotOpen, fileURL.lastPathComponent),
                detail: alertText(.alertExternalReloadFailedDetail)
            )
            return
        }
        let historyID = unchangedHistoryIdentity(readID, at: fileURL)
        guard !isDirty || discardRevision == textMutationRevision else {
            raiseExternalConflict()
            return
        }

        // The input method can own a provisional buffer while the document is
        // still clean. Do not accept the disk text/fingerprint unless the kept
        // editor can accept it too; its later commit would otherwise resurrect
        // the old document and silently autosave over the external version.
        // A successful reset also clears undo actions against the replaced text.
        guard editorSession.resetText(to: decoded.text) else {
            raiseExternalConflict()
            return
        }

        resetRemoteImageChoices()
        replaceRemoteResourceContext(keepingConversionNotice: true)
        remoteImageFileReference = imageReference
        cancelAutosave()
        jumpLine = nil
        jumpHeadingID = nil
        jumpFraction = nil
        if let anchor {
            editorJumpAnchor = anchor
            previewJumpAnchor = anchor
        }
        fileFormat = decoded.format
        if copyFileReference == nil { fileIdentity = DocumentFileIdentity(url: fileURL) }
        backingFileMissing = false
        encodingWarningShown = false
        encodingConversionRequest = nil
        isLoading = true
        text = decoded.text
        isDirty = false
        renderImmediately()
        isLoading = false
        lastKnownFingerprint = DocumentFileFingerprint.of(data: data, at: fileURL)
        hasExternalConflict = false
        externalConflictRequest = nil
        startWatchingFile()
        onRemoteImageBackingChanged?()
        persistRecoveryNow()
        recordHistory(data, reason: .externalReload, fileID: historyID)
    }

    /// Enters the conflict state: writes stop, autosave is suspended, and the
    /// window layer is asked to present the choice. Re-raising while the
    /// prompt is already pending keeps a single prompt.
    private func raiseExternalConflict() {
        stopConversion(sourceChanged: true)
        hasExternalConflict = true
        cancelAutosave()
        persistRecoveryNow()
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
            refreshFileLocation()
            if let fileURL, !(backingFileMissing && fileIdentity?.isFolderFile == true),
               let current = DocumentFileFingerprint.current(at: fileURL, reference: copyFileReference) {
                lastKnownFingerprint = current
                if copyFileReference == nil { fileIdentity = DocumentFileIdentity(url: fileURL) }
            }
            scheduleAutosaveIfNeeded()
            persistRecoveryNow()
        }
    }

    private func cancelAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
        autosaveDeadlineTask?.cancel()
        autosaveDeadlineTask = nil
    }

    private func scheduleAutosaveIfNeeded() {
        guard !isClosed, fileURL != nil, !hasExternalConflict, !backingFileMissing else {
            cancelAutosave()
            return
        }
        autosaveTask?.cancel()
        autosaveTask = delayedTask(after: autosaveDelay) { $0.autosaveNow() }
        // Starts at the first unsaved edit, never postponed by more typing.
        if autosaveDeadlineTask == nil {
            autosaveDeadlineTask = delayedTask(after: maximumAutosaveDelay) { $0.autosaveNow() }
        }
    }

    private func delayedTask(after seconds: TimeInterval, action: @escaping @MainActor (DocumentStore) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard !Task.isCancelled, let self, !self.isClosed else { return }
            action(self)
        }
    }

    private func autosaveNow() {
        cancelAutosave()
        guard let fileURL, isDirty, !hasExternalConflict, !backingFileMissing, !isClosed else { return }
        _ = write(to: fileURL, automatically: true)
    }

    /// Called before every disk evaluation and write. Changing the URL must
    /// also rebase relative images/links and the window's represented URL.
    func refreshFileLocation() {
        guard let previous = fileURL, !isClosed else { return }
        defer { onRemoteImageBackingChanged?() }
        if let identity = fileIdentity, identity.isFolderFile, copyFileReference == nil {
            guard let reference = identity.reopenFolderFile(at: previous) else {
                markBackingFileMissing()
                return
            }
            copyFileReference = reference
            fileIdentity = DocumentFileIdentity(folderReference: reference)
            backingFileMissing = false
            startWatchingFile()
        }
        guard let resolved = fileIdentity?.resolve(fallback: previous),
              DocumentFileFingerprint.isReadableRegularFile(at: resolved) else {
            markBackingFileMissing()
            return
        }
        backingFileMissing = false
        guard resolved != previous else { return }
        fileURL = resolved
        if copyFileReference == nil { fileIdentity = DocumentFileIdentity(url: resolved) }
        startWatchingFile()
        renderImmediately()
        persistRecoveryNow()
    }

    private func markBackingFileMissing() {
        backingFileMissing = true
        onRemoteImageBackingChanged?()
        isDirty = true
        cancelAutosave()
        persistRecoveryNow()
    }

    // MARK: Recovery and session restoration

    private func historyIdentity(at url: URL) -> DocumentHistoryFileID? {
        guard historyRepository != nil else { return nil }
        return DocumentHistoryFileID(url: url)
    }

    private func unchangedHistoryIdentity(_ known: DocumentHistoryFileID?, at url: URL) -> DocumentHistoryFileID? {
        guard let known, historyIdentity(at: url) == known else { return nil }
        return known
    }

    private func recordHistory(_ data: Data, reason: DocumentHistoryReason, fileID: DocumentHistoryFileID?,
                               replacing previousID: DocumentHistoryFileID? = nil) {
        let continuation = previousID != nil && previousID == historyFileID ? previousID : nil
        updateHistoryIdentity(fileID, keepingLineage: continuation != nil)
        guard let fileID, let historyRepository else { return }
        if keepsLocalHistory() {
            historyRepository.record(data, format: fileFormat, reason: reason, for: fileID, replacing: continuation)
        } else if let continuation {
            historyRepository.reassociate(from: continuation, to: fileID)
        }
    }

    private func updateHistoryIdentity(_ fileID: DocumentHistoryFileID?, keepingLineage: Bool = false) {
        if fileID != historyFileID && !keepingLineage { historyLineage = UUID() }
        historyFileID = fileID
    }

    /// Viewing history never follows a path by mutating the source window.
    func captureHistorySource() throws -> DocumentHistorySource {
        guard !isClosed, !backingFileMissing else { throw DocumentHistoryFlowError.sourceChanged }
        guard editorSession.textView?.hasMarkedText() != true else { throw DocumentHistoryFlowError.composing }
        guard keepsLocalHistory() else { throw DocumentHistoryFlowError.disabled }
        guard let fileURL else { throw DocumentHistoryFlowError.untitled }
        guard let repository = historyRepository, let fileID = historyFileID else {
            throw DocumentHistoryFlowError.sourceUnavailable
        }
        return DocumentHistorySource(documentID: documentIdentity, lineage: historyLineage,
            url: fileURL, fileID: fileID, repository: repository)
    }


    private func scheduleRecovery() {
        guard recoveryRepository != nil, recoveryTask == nil, !isClosed else { return }
        // Throttle, not debounce: continuous typing still reaches disk each second.
        recoveryTask = delayedTask(after: recoveryDelay) { $0.persistRecoveryNow() }
    }

    @discardableResult
    func persistRecoveryNow() -> Bool {
        recoveryTask?.cancel()
        recoveryTask = nil
        guard !isClosed, let recoveryRepository else { return true }
        do {
            try recoveryRepository.write(DocumentRecoverySnapshot(
                id: recoveryID, text: isDirty || fileURL == nil ? text : "", fileURL: fileURL, identity: fileIdentity,
                format: fileFormat, fingerprint: lastKnownFingerprint, isDirty: isDirty,
                windowFrame: windowFrame))
            recoveryErrorReported = false
            return true
        } catch {
            if !recoveryErrorReported {
                alert = DocumentAlert(message: alertText(.alertRecoveryFailed), detail: error.localizedDescription)
                recoveryErrorReported = true
            }
            return false
        }
    }

    func restore(_ snapshot: DocumentRecoverySnapshot, openingFolderFile: FolderIndex.OpenedFile? = nil) {
        remoteImageFileReference = nil
        defer { onRemoteImageBackingChanged?() }
        historyFileID = nil
        historyLineage = UUID()
        recoveryID = snapshot.id
        windowFrame = snapshot.windowFrame
        fileFormat = snapshot.format
        fileIdentity = snapshot.identity
        lastKnownFingerprint = snapshot.fingerprint
        if let url = snapshot.fileURL, openingFolderFile != nil || snapshot.identity?.isFolderFile == true {
            restoreFolderDocument(snapshot, url: url, selectedFile: openingFolderFile)
            return
        }
        let resolved = snapshot.fileURL.flatMap { snapshot.identity?.resolve(fallback: $0) }
        setDocumentText(snapshot.text, fileURL: resolved ?? snapshot.fileURL, dirty: snapshot.isDirty)
        if let url = snapshot.fileURL {
            if let resolved {
                fileIdentity = DocumentFileIdentity(url: resolved)
                let current = DocumentFileFingerprint.current(at: resolved)
                if !snapshot.isDirty, current != nil {
                    if !load(from: resolved) {
                        isDirty = true
                        raiseExternalConflict()
                    }
                } else if current == nil {
                    markBackingFileMissing()
                } else if snapshot.fingerprint?.contentHash != current?.contentHash {
                    raiseExternalConflict() // Keep both versions until the user chooses.
                } else {
                    historyFileID = historyIdentity(at: resolved)
                }
            } else {
                fileURL = url
                markBackingFileMissing()
            }
            startWatchingFile()
        }
        scheduleAutosaveIfNeeded()
        persistRecoveryNow()
    }

    private func restoreFolderDocument(_ snapshot: DocumentRecoverySnapshot, url: URL,
                                       selectedFile: FolderIndex.OpenedFile?) {
        let restoreURL = selectedFile?.url ?? url
        let identityMatches = snapshot.identity?.isFolderFile != true
            || selectedFile.map { snapshot.identity?.matchesFolderEntry($0.fileReference) == true } == true
        let selectedReference = identityMatches ? selectedFile?.fileReference : nil
        let reference = selectedReference ?? snapshot.identity?.reopenFolderFile(at: restoreURL)
        guard let reference else {
            setDocumentText(snapshot.text, fileURL: restoreURL, dirty: snapshot.isDirty)
            markBackingFileMissing()
            return
        }
        copyFileReference = reference
        let identity = DocumentFileIdentity(folderReference: reference)
        fileIdentity = identity
        setDocumentText(snapshot.text, fileURL: restoreURL, dirty: snapshot.isDirty)
        do {
            let verifiedSelection = selectedReference != nil ? selectedFile : nil
            try verifiedSelection?.validate()
            let data = try verifiedSelection?.data ?? reference.read(at: restoreURL)
            let current = verifiedSelection?.fingerprint ?? .of(data: data, at: restoreURL)
            let historyID = historyIdentity(at: restoreURL)
            if !snapshot.isDirty {
                guard let decoded = MarkdownFileDecoder.decode(data) else {
                    showUndecodableFile(restoreURL)
                    markBackingFileMissing()
                    return
                }
                installLoadedFile(decoded, url: restoreURL, data: data, fingerprint: current,
                                  identity: identity, reference: reference, historyID: historyID)
                return
            }
            if snapshot.identity?.matchesFolderEntry(reference) == true { remoteImageFileReference = reference }
            if snapshot.fingerprint?.contentHash != current.contentHash {
                raiseExternalConflict()
            } else {
                historyFileID = historyID
            }
            startWatchingFile()
            scheduleAutosaveIfNeeded()
            persistRecoveryNow()
        } catch {
            markBackingFileMissing()
        }
    }

    /// Explicit close discards the record only after Save/Don't Save succeeded.
    /// Quit keeps records so both saved windows and untitled drafts reopen.
    @discardableResult
    func closeDocument(discardRecovery: Bool) -> Bool {
        if discardRecovery, let recoveryRepository {
            do { try recoveryRepository.remove(recoveryID) }
            catch {
                alert = DocumentAlert(message: alertText(.alertRecoveryFailed), detail: error.localizedDescription)
                return false
            }
        }
        isClosed = true
        resetRemoteImageChoices()
        remoteImageFileReference = nil
        replaceRemoteResourceContext()
        renderDebounceTask?.cancel()
        renderDebounceTask = nil
        hasPendingRender = false
        copyFlow.cancel()
        headingNavigationTask?.cancel()
        headingNavigationTask = nil
        cancelAutosave()
        recoveryTask?.cancel()
        recoveryTask = nil
        stopWatchingFile()
        fileIdentity = nil
        copyFileReference = nil
        return true
    }

    /// Flush safe in-place edits on Quit. Conflicts, missing files, and edits
    /// needing an encoding decision remain in recovery without a blocking panel.
    @discardableResult
    func prepareForTermination() -> Bool {
        refreshFileLocation()
        if let fileURL, isDirty, !hasExternalConflict, !backingFileMissing,
           fileFormat.encode(text) != nil {
            _ = write(to: fileURL, automatically: true)
        }
        recoveryErrorReported = false
        return persistRecoveryNow()
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
