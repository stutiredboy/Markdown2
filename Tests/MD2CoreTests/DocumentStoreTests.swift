import Foundation
import Testing
@testable import MD2App
@testable import MD2Core

@MainActor
struct DocumentStoreTests {
    @Test func newStoreIsReusableEmptyDocument() {
        let store = DocumentStore()

        #expect(store.isReusableEmptyDocument)
        #expect(store.fileURL == nil)
        #expect(!store.isDirty)
        #expect(store.displayTitle == "Untitled.md")
    }

    @Test func editingMarksDirtyAndNotReusable() {
        let store = DocumentStore()
        store.text = "# Changed\n\nNew body."

        #expect(store.isDirty)
        #expect(!store.isReusableEmptyDocument)
        #expect(store.displayTitle == "Untitled.md *")
    }

    @Test func reassigningSameTextDoesNotMarkDirty() {
        let store = DocumentStore()
        store.text = store.text

        #expect(!store.isDirty)
        #expect(store.isReusableEmptyDocument)
    }

    @Test func requestModePublishesFreshModeCommands() {
        let store = DocumentStore()

        store.requestMode(.read)
        let first = store.modeCommand
        store.requestMode(.read)
        let second = store.modeCommand

        #expect(first?.mode == .read)
        #expect(second?.mode == .read)
        #expect(first != second)
    }

    @Test func renderedDocumentTracksTextChanges() async {
        let store = DocumentStore()
        store.text = "# Heading One\n\nSome words here."
        // The render that feeds the preview/stats is debounced off the keystroke
        // path; flush it so the synchronous assertions below see current content.
        await store.flushPendingRender()

        #expect(store.rendered.outline.first?.title == "Heading One")
        #expect(store.rendered.html.contains("Heading One"))
        #expect(store.rendered.stats.words > 0)
    }

    @Test func cancellingPDFExportLeavesDocumentStateUnchanged() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("md2-export-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("notes.md")
        let destinationURL = directory.appendingPathComponent("notes.pdf")
        try "# Original\n".write(to: sourceURL, atomically: true, encoding: .utf8)

        var exporterCreated = false
        let store = DocumentStore(
            pdfDestinationPicker: { defaultName in
                #expect(defaultName == "notes.pdf")
                return nil
            },
            pdfExporterFactory: { _, _ in
                exporterCreated = true
                return FakePDFExporter()
            }
        )
        store.open(sourceURL)
        store.text = "# Dirty\n\nUnsaved edit."

        let fileURLBefore = store.fileURL
        let dirtyBefore = store.isDirty
        await store.exportPDF()

        #expect(!exporterCreated)
        #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
        #expect(store.fileURL == fileURLBefore)
        #expect(store.isDirty == dirtyBefore)
    }

    @Test func successfulPDFExportLeavesDirtyDocumentStateUnchanged() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("md2-export-success-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("notes.md")
        let destinationURL = directory.appendingPathComponent("notes.pdf")
        try "# Original\n".write(to: sourceURL, atomically: true, encoding: .utf8)

        let exporter = FakePDFExporter()
        let store = DocumentStore(
            pdfDestinationPicker: { defaultName in
                #expect(defaultName == "notes.pdf")
                return destinationURL
            },
            pdfExporterFactory: { url, _ in
                #expect(url == destinationURL)
                return exporter
            }
        )
        store.open(sourceURL)
        store.text = "# Dirty Export\n\nThis should be flushed into rendered HTML."

        let fileURLBefore = store.fileURL
        await store.exportPDF()

        #expect(exporter.exportCallCount == 1)
        #expect(exporter.html?.contains("Dirty Export") == true)
        #expect(exporter.outline?.map(\.title) == ["Dirty Export"])
        #expect(exporter.baseURL == directory)
        #expect(store.fileURL == fileURLBefore)
        #expect(store.isDirty)
    }

    @Test func toggleTaskChecksAndUnchecksMarker() {
        let store = DocumentStore()
        store.text = "# Title\n\n- [ ] Draft\n- [x] Review"

        store.toggleTask(atLine: 3, to: true)
        #expect(store.text == "# Title\n\n- [x] Draft\n- [x] Review")
        #expect(store.isDirty)

        store.toggleTask(atLine: 4, to: false)
        #expect(store.text == "# Title\n\n- [x] Draft\n- [ ] Review")
    }

    @Test func exportKeepsItsSnapshotAndExcludesOtherExportsDuringPreparation() async throws {
        let exporter = FakePDFExporter()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot.pdf")
        let store = DocumentStore(pdfDestinationPicker: { _ in destination }, pdfExporterFactory: { _, _ in exporter })
        store.text = "# Export Snapshot\n\n" + String(repeating: "**paragraph** text\n\n", count: 8_000)
        let job = Task { await store.exportPDF() }
        try await Task.sleep(for: .milliseconds(10))
        store.text = "# New Editor Content"
        await store.exportPDF()
        await job.value
        #expect(exporter.exportCallCount == 1)
        #expect(exporter.outline?.map(\.title) == ["Export Snapshot"])
        #expect(exporter.html?.contains("New Editor Content") == false)
        await store.flushPendingRender()
        #expect(store.rendered.outline.map(\.title) == ["New Editor Content"])
    }

    @Test func toggleTaskHandlesUppercaseMarker() {
        let store = DocumentStore()
        store.text = "- [X] Draft"

        store.toggleTask(atLine: 1, to: false)

        #expect(store.text == "- [ ] Draft")
    }

    @Test func toggleTaskPreservesNestingAndBlockquotePrefixes() {
        let store = DocumentStore()
        store.text = "- [ ] parent\n    - [ ] child\n\n> - [ ] quoted task"

        store.toggleTask(atLine: 2, to: true)
        store.toggleTask(atLine: 4, to: true)

        #expect(store.text == "- [ ] parent\n    - [x] child\n\n> - [x] quoted task")
    }

    @Test func toggleTaskIsIdempotentForDuplicateRequests() {
        let store = DocumentStore()
        store.text = "- [ ] once"

        store.toggleTask(atLine: 1, to: true)
        let afterFirst = store.text
        store.toggleTask(atLine: 1, to: true)

        #expect(store.text == afterFirst)
        #expect(store.text == "- [x] once")
    }

    @Test func toggleTaskIgnoresInvalidTargets() {
        let store = DocumentStore()
        let original = "# Title\n\nPlain paragraph.\n- [ ] task"
        store.text = original
        let dirtyBefore = store.isDirty

        store.toggleTask(atLine: 1, to: true) // heading, not a task
        store.toggleTask(atLine: 3, to: true) // paragraph, not a task
        store.toggleTask(atLine: 99, to: true) // out of range
        store.toggleTask(atLine: 0, to: true) // below range

        #expect(store.text == original)
        #expect(store.isDirty == dirtyBefore)
    }

    @Test func toggleTaskMatchesRendererTaskLineMetadata() async {
        // The line the renderer stamps on the checkbox is the line the toggle
        // edits: round-trip one through the other.
        let store = DocumentStore()
        store.text = "# Title\n\n> note\n> - [ ] quoted\n\n- [ ] plain"
        await store.flushPendingRender()

        #expect(store.rendered.html.contains(#"data-md2-task-line="4""#))
        #expect(store.rendered.html.contains(#"data-md2-task-line="6""#))

        store.toggleTask(atLine: 4, to: true)
        store.toggleTask(atLine: 6, to: true)

        #expect(store.text == "# Title\n\n> note\n> - [x] quoted\n\n- [x] plain")
    }

    /// F05 in the 2026-10-15 review: the preview still shows A on line 1 when
    /// N lands above it, and a click on A must not check N.
    @Test func clickFromAPreviewBehindTheTextChangesNothing() {
        let store = DocumentStore()
        store.text = "- [ ] A\n- [ ] B"
        let clicked = store.sourceLineRevision
        store.text = "- [ ] N\n- [ ] A\n- [ ] B"

        #expect(!store.toggleTask(atLine: 1, to: true, renderedAt: clicked))
        #expect(store.text == "- [ ] N\n- [ ] A\n- [ ] B")
    }

    /// Comparing the line's text could not tell these apart: line 1 reads the
    /// same before and after, but it is not the task that was clicked.
    @Test func clickFromAStalePreviewIsRefusedOnAnIdenticalLine() {
        let store = DocumentStore()
        store.text = "- [ ] repeat"
        let clicked = store.sourceLineRevision
        store.text = "- [ ] repeat\n- [ ] repeat"

        #expect(!store.toggleTask(atLine: 1, to: true, renderedAt: clicked))
        #expect(store.text == "- [ ] repeat\n- [ ] repeat")
    }

    @Test func clickFromAPreviewOfDeletedOrMovedTasksChangesNothing() {
        let store = DocumentStore()
        store.text = "- [ ] A\n- [ ] B\n- [ ] C"
        let clicked = store.sourceLineRevision

        store.text = "- [ ] B\n- [ ] C"
        #expect(!store.toggleTask(atLine: 1, to: true, renderedAt: clicked))
        store.text = "- [ ] C\n- [ ] A\n- [ ] B"
        #expect(!store.toggleTask(atLine: 2, to: true, renderedAt: clicked))

        #expect(store.text == "- [ ] C\n- [ ] A\n- [ ] B")
    }

    @Test func clickFromThePageOfAReplacedDocumentChangesNothing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("md2-toggle-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("other.md")
        try "- [ ] From disk".write(to: url, atomically: true, encoding: .utf8)

        let store = DocumentStore()
        store.text = "- [ ] Before"
        let clicked = store.sourceLineRevision
        store.open(url)

        #expect(!store.toggleTask(atLine: 1, to: true, renderedAt: clicked))
        #expect(store.text == "- [ ] From disk")
    }

    /// A toggle moves no line, so ticking down a list faster than the preview
    /// re-renders keeps working: every click is still addressed correctly.
    @Test func secondClickBeforeTheRerenderLandsIsNotStale() {
        let store = DocumentStore()
        store.text = "- [ ] A\n- [ ] B"
        let clicked = store.sourceLineRevision

        #expect(store.toggleTask(atLine: 1, to: true, renderedAt: clicked))
        #expect(store.toggleTask(atLine: 2, to: true, renderedAt: clicked))

        #expect(store.text == "- [x] A\n- [x] B")
    }

    @Test func duplicateClickIsIdempotentAndStaysAccepted() {
        let store = DocumentStore()
        store.text = "- [ ] once"
        let clicked = store.sourceLineRevision

        #expect(store.toggleTask(atLine: 1, to: true, renderedAt: clicked))
        #expect(store.toggleTask(atLine: 1, to: true, renderedAt: clicked))

        #expect(store.text == "- [x] once")
    }

    /// Undo goes through the text view like typing, so it is not a toggle, even
    /// when what it takes back was one.
    @Test func undoingAToggleMakesEarlierClicksStale() {
        let store = DocumentStore()
        store.text = "- [ ] A\n- [ ] B"
        let clicked = store.sourceLineRevision
        #expect(store.toggleTask(atLine: 1, to: true, renderedAt: clicked))

        store.undoManager.undo()

        #expect(store.text == "- [ ] A\n- [ ] B")
        #expect(!store.toggleTask(atLine: 2, to: true, renderedAt: clicked))
    }

    /// The preview labels its page with this revision, so it must describe the
    /// text `rendered` was built from and not whatever the text is by then.
    @Test func renderedRevisionTrailsTheTextUntilTheRenderLands() async {
        let store = DocumentStore()
        store.text = "- [ ] A"
        await store.flushPendingRender()
        #expect(store.renderedSourceLineRevision == store.sourceLineRevision)
        let rendered = store.renderedSourceLineRevision

        store.text = "- [ ] N\n- [ ] A"
        #expect(store.renderedSourceLineRevision == rendered)
        #expect(store.sourceLineRevision != rendered)

        await store.flushPendingRender()
        #expect(store.renderedSourceLineRevision == store.sourceLineRevision)
        #expect(store.rendered.html.contains(#"data-md2-task-line="2""#))
    }
}

@MainActor
private final class FakePDFExporter: PDFExporting {
    func cancel() {}
    private(set) var exportCallCount = 0
    private(set) var html: String?
    private(set) var outline: [Heading]?
    private(set) var baseURL: URL?
    private(set) var documentTitle: String?

    func export(
        html: String,
        outline: [Heading],
        baseURL: URL?,
        remoteResourcePolicy: RemoteResourcePolicy,
        documentTitle: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        exportCallCount += 1
        self.html = html
        self.outline = outline
        self.baseURL = baseURL
        self.documentTitle = documentTitle
        completion(.success(()))
    }
}
