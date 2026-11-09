import AppKit
import Foundation
import Testing
@testable import MD2App

@MainActor
private final class CopyFlowWatcher: DocumentFileWatching {
    var onEvent: (() -> Void)?
    var urls: [URL] = []
    var stops = 0
    func watch(url: URL) { urls.append(url) }
    func stop() { stops += 1 }
}

private actor CopyFlowGate {
    private var paused = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            paused = true
            observers.forEach { $0.resume() }
            observers.removeAll()
        }
    }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private struct CopyFlowFixture {
    let directory: URL
    let source: URL
    let destination: URL
    let watcher = CopyFlowWatcher()
    let repository: DocumentRecoveryRepository
    let store: DocumentStore
    let original: Data

    init(bytes: Data = Data("On disk\n".utf8)) throws {
        original = bytes
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("md2-copy-flow-\(UUID())", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("source.md")
        destination = directory.appendingPathComponent("copy.md")
        repository = DocumentRecoveryRepository(directory: directory.appendingPathComponent("recovery"))
        try bytes.write(to: source)
        let fixtureWatcher = watcher
        store = DocumentStore(fileWatcherFactory: { fixtureWatcher }, recoveryRepository: repository,
                              autosaveDelay: 3_600, maximumAutosaveDelay: 7_200, recoveryDelay: 3_600)
        store.open(source)
    }
    func remove() {
        store.closeDocument(discardRecovery: false)
        try? FileManager.default.removeItem(at: directory)
    }
    func create(name: String? = "copy.md") async -> DocumentCopyReceipt? {
        await store.copyFlow.create(from: store, text: { L10n.text($0, language: .english) }, chooseName: { _ in name })
    }
    func names() throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) }
}

@MainActor
struct DocumentCopyFlowTests {
    private func text(_ key: L10nKey) -> String { L10n.text(key, language: .english) }

    @Test func dirtySnapshotPreservesOriginalUndoRecoveryWatcherAndResources() async throws {
        let fixture = try CopyFlowFixture(bytes: Data([0xef, 0xbb, 0xbf]) + Data("On disk\r\n".utf8))
        defer { fixture.remove() }
        let store = fixture.store
        let identity = store.documentIdentity
        let recoveryID = store.recoveryID
        let urls = fixture.watcher.urls
        let markdown = "# Draft\n![image](assets/a.png)\n[notes](other.md)\nbibliography: refs.bib\n"
        store.undoManager.beginUndoGrouping()
        #expect(store.editorSession.applyUndoableEdit(changing: store.text, to: markdown))
        store.undoManager.endUndoGrouping()
        #expect(store.isDirty)
        #expect(store.undoManager.canUndo)
        #expect(store.persistRecoveryNow())
        let recoveryURL = fixture.repository.directory.appendingPathComponent(recoveryID.uuidString + ".json")
        let recoveryBytes = try Data(contentsOf: recoveryURL)
        let receipt = try #require(await fixture.create())
        #expect(receipt.completeness == .textOnly)
        #expect(try Data(contentsOf: fixture.destination) == Data([0xef, 0xbb, 0xbf]) + Data(markdown.replacingOccurrences(of: "\n", with: "\r\n").utf8))
        #expect(try Data(contentsOf: fixture.source) == fixture.original)
        #expect(store.fileURL == fixture.source)
        #expect(store.text == markdown && store.isDirty)
        #expect(store.documentIdentity == identity && store.recoveryID == recoveryID)
        #expect(fixture.watcher.urls == urls && fixture.watcher.stops == 0)
        #expect(try Data(contentsOf: recoveryURL) == recoveryBytes)
        #expect(try fixture.names() == ["source.md", "copy.md", "recovery"])
        store.undoManager.undo()
        #expect(store.text == "On disk\r\n")
        #expect(try Data(contentsOf: fixture.destination).count == receipt.byteCount)
    }

    @Test func loadedLegacyUnicodeAndMixedFormatsRoundTrip() async throws {
        let formats: [MarkdownFileFormat] = [
            .init(encoding: .utf16BE, hasBOM: true, lineEnding: .crlf),
            .init(encoding: .utf32LE, hasBOM: true, lineEnding: .cr),
            .init(encoding: .gbk, lineEnding: .crlf),
            .init(encoding: .utf8, hasBOM: true, lineEnding: .mixed)
        ]
        for format in formats {
            let original = try #require(format.encode("中文\r\n第二行\r末行\n"))
            let fixture = try CopyFlowFixture(bytes: original)
            defer { fixture.remove() }
            fixture.store.text += "新行\n"
            let expected = try #require(fixture.store.fileFormat.encode(fixture.store.text))
            let receipt = try #require(await fixture.create())
            #expect(try Data(contentsOf: fixture.destination) == expected)
            #expect(receipt.writtenFormat == fixture.store.fileFormat)
            #expect(try Data(contentsOf: fixture.source) == original)
        }
    }

    @Test func filenameCancellationAndInvalidNamesNeverWrite() async throws {
        let fixture = try CopyFlowFixture()
        defer { fixture.remove() }
        fixture.store.text = "Dirty"
        #expect(await fixture.create(name: nil) == nil)
        #expect(fixture.store.copyFlow.message == nil)
        for name in ["", "../copy.md", "a/b.md", "a:b.md", " copy.md", "copy.txt", "copy.md\n"] {
            #expect(await fixture.create(name: name) == nil)
            #expect(fixture.store.copyFlow.detail == text(.copyInvalidName))
        }
        #expect(try fixture.names() == ["source.md", "recovery"])
        #expect(fixture.store.text == "Dirty" && fixture.store.isDirty)
        #expect(try Data(contentsOf: fixture.source) == fixture.original)
    }

    @Test func existingFileAndOriginalNameAreNeverOverwritten() async throws {
        let fixture = try CopyFlowFixture()
        defer { fixture.remove() }
        let existing = Data("Existing target".utf8)
        try existing.write(to: fixture.destination)
        #expect(await fixture.create() == nil)
        #expect(fixture.store.copyFlow.detail == text(.copyNameExists))
        #expect(await fixture.create(name: "source.md") == nil)
        #expect(try Data(contentsOf: fixture.destination) == existing)
        #expect(try Data(contentsOf: fixture.source) == fixture.original)
    }

    @Test func untitledDoesNotInvokeSaveOrFilenamePicker() async {
        var saved = false
        var picked = false
        let store = DocumentStore(saveLocationPicker: { _ in saved = true; return nil })
        defer { store.closeDocument(discardRecovery: false) }
        store.text = "Untitled draft"
        let receipt = await store.copyFlow.create(from: store, text: text, chooseName: { _ in picked = true; return "copy.md" })
        #expect(receipt == nil && !saved && !picked)
        #expect(store.fileURL == nil && store.isDirty)
        #expect(store.copyFlow.detail == text(.copySaveFirst))
    }

    @Test func unrepresentableEncodingFailsWithoutConversion() async throws {
        let fixture = try CopyFlowFixture(bytes: Data([0xd6, 0xd0]))
        defer { fixture.remove() }
        fixture.store.text += "🧪"
        #expect(await fixture.create() == nil)
        #expect(fixture.store.fileFormat.encoding == .gbk)
        #expect(fixture.store.encodingConversionRequest == nil)
        #expect(try fixture.names() == ["source.md", "recovery"])
        #expect(try Data(contentsOf: fixture.source) == fixture.original)
    }

    @Test func missingAndSymbolicSourcesFailWithoutCreatingCopy() async throws {
        for symlink in [false, true] {
            let fixture = try CopyFlowFixture()
            defer { fixture.remove() }
            try FileManager.default.removeItem(at: fixture.source)
            if symlink {
                let target = fixture.directory.appendingPathComponent("target.md")
                try fixture.original.write(to: target)
                try FileManager.default.createSymbolicLink(at: fixture.source, withDestinationURL: target)
            }
            #expect(await fixture.create() == nil)
            #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
            #expect(fixture.store.fileURL == fixture.source)
        }
    }

    @Test func unresolvedConflictCanBeCopiedWithoutResolvingOrOverwritingIt() async throws {
        let fixture = try CopyFlowFixture()
        defer { fixture.remove() }
        fixture.store.text = "My draft"
        let external = Data("External version".utf8)
        try external.write(to: fixture.source)
        #expect(!fixture.store.save())
        #expect(fixture.store.hasExternalConflict)
        let request = fixture.store.externalConflictRequest?.id
        let receipt = try #require(await fixture.create())
        #expect(try String(contentsOf: receipt.destinationURL, encoding: .utf8) == "My draft")
        #expect(try Data(contentsOf: fixture.source) == external)
        #expect(fixture.store.hasExternalConflict && fixture.store.isDirty)
        #expect(fixture.store.externalConflictRequest?.id == request)
    }

    @Test func movedSourceAndReusedOldPathCannotCopyInTheWrongDirectory() async throws {
        let fixture = try CopyFlowFixture()
        defer { fixture.remove() }
        fixture.store.text = "Current draft"
        let movedDirectory = fixture.directory.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: movedDirectory, withIntermediateDirectories: false)
        let moved = movedDirectory.appendingPathComponent("source.md")
        try FileManager.default.moveItem(at: fixture.source, to: moved)
        let unrelated = Data("Unrelated file now at old path".utf8)
        try unrelated.write(to: fixture.source)
        #expect(await fixture.create() == nil)
        #expect(fixture.store.copyFlow.detail == text(.copySourceChanged))
        #expect(fixture.store.fileURL == fixture.source && fixture.store.isDirty)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(try Data(contentsOf: moved) == fixture.original)
        #expect(try Data(contentsOf: fixture.source) == unrelated)
    }

    @Test func pickerCapturesLatestTextButRefusesChangedDocumentOrClosure() async throws {
        let fixture = try CopyFlowFixture()
        defer { fixture.remove() }
        let receipt = try #require(await fixture.store.copyFlow.create(from: fixture.store, text: text, chooseName: { _ in
            fixture.store.text = "Edited while naming"
            return "copy.md"
        }))
        #expect(try String(contentsOf: receipt.destinationURL, encoding: .utf8) == "Edited while naming")
        let different = fixture.directory.appendingPathComponent("other.md")
        try Data("Other file".utf8).write(to: different)
        #expect(await fixture.store.copyFlow.create(from: fixture.store, text: text, chooseName: { _ in
            fixture.store.open(different)
            return "wrong.md"
        }) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("wrong.md").path))
        #expect(await fixture.store.copyFlow.create(from: fixture.store, text: text, chooseName: { _ in
            fixture.store.closeDocument(discardRecovery: false)
            return "closed.md"
        }) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("closed.md").path))
    }

    @Test func markedTextIsKeptBeforePickerAfterPickerAndBeforeOpening() async throws {
        let fixture = try CopyFlowFixture()
        defer { fixture.remove() }
        let editor = fixture.store.editorSession.loadTextView(text: fixture.store.text)
        editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        let marked = editor.string
        var picked = false
        #expect(await fixture.store.copyFlow.create(from: fixture.store, text: text, chooseName: { _ in picked = true; return "copy.md" }) == nil)
        #expect(!picked && editor.hasMarkedText() && editor.string == marked)
        editor.unmarkText()
        #expect(await fixture.store.copyFlow.create(from: fixture.store, text: text, chooseName: { _ in
            editor.setMarkedText("音", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
            return "copy.md"
        }) == nil)
        #expect(editor.hasMarkedText())
        editor.unmarkText()
        #expect(await fixture.create() != nil)
        editor.setMarkedText("字", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        let beforeOpen = editor.string
        #expect(!fixture.store.copyFlow.mayOpen(from: fixture.store, text: text))
        #expect(editor.hasMarkedText() && editor.string == beforeOpen)
        #expect(fixture.store.copyFlow.receipt != nil)
        editor.unmarkText()
    }

    @Test func delayedWriteKeepsCapturedRevisionAndIgnoresDuplicateRequest() async throws {
        let fixture = try CopyFlowFixture()
        defer { fixture.remove() }
        fixture.store.text = "Captured draft"
        let gate = CopyFlowGate()
        let task = Task { await fixture.store.copyFlow.create(from: fixture.store, text: text, chooseName: { _ in "copy.md" }, write: { source, destination in
            await gate.pause()
            return try await DocumentCopyFlow.write(source, to: destination)
        }) }
        await gate.waitUntilPaused()
        fixture.store.text = "Later edit"
        var picked = false
        #expect(await fixture.store.copyFlow.create(from: fixture.store, text: text, chooseName: { _ in picked = true; return "second.md" }) == nil)
        #expect(!picked && fixture.store.copyFlow.isRunning)
        await gate.release()
        let receipt = try #require(await task.value)
        #expect(try String(contentsOf: receipt.destinationURL, encoding: .utf8) == "Captured draft")
        #expect(fixture.store.text == "Later edit" && fixture.store.isDirty)
        #expect(!fixture.store.copyFlow.isRunning)
    }

    @Test func cancellationBeforeWriteProducesNoFileButAfterCommitKeepsReceipt() async throws {
        for committed in [false, true] {
            let fixture = try CopyFlowFixture()
            defer { fixture.remove() }
            let gate = CopyFlowGate()
            let task = Task { await fixture.store.copyFlow.create(from: fixture.store, text: text, chooseName: { _ in "copy.md" }, write: { source, destination in
                if committed {
                    let receipt = try await DocumentCopyFlow.write(source, to: destination)
                    await gate.pause()
                    return receipt
                }
                await gate.pause()
                try Task.checkCancellation()
                return try await DocumentCopyFlow.write(source, to: destination)
            }) }
            await gate.waitUntilPaused()
            fixture.store.closeDocument(discardRecovery: false)
            task.cancel()
            await gate.release()
            let receipt = await task.value
            #expect((receipt != nil) == committed)
            #expect(FileManager.default.fileExists(atPath: fixture.destination.path) == committed)
            #expect((fixture.store.copyFlow.receipt != nil) == committed)
            if committed { #expect(fixture.store.copyFlow.message?.contains("copy.md") == true) }
        }
    }

    @Test func dismissingNoticeLeavesCompletedFileAndIndependentStoreState() async throws {
        let fixture = try CopyFlowFixture()
        defer { fixture.remove() }
        fixture.store.text = "Draft for copy"
        let receipt = try #require(await fixture.create())
        let oldRecovery = DocumentRecoverySnapshot(id: UUID(), text: "Obsolete draft", fileURL: receipt.destinationURL,
            identity: nil, format: .init(), fingerprint: nil, isDirty: true, windowFrame: nil)
        try fixture.repository.write(oldRecovery)
        let copy = DocumentCopyFlow.openFreshStore(receipt) { DocumentStore(recoveryRepository: fixture.repository) }
        defer { copy.closeDocument(discardRecovery: false) }
        #expect(copy.text == "Draft for copy" && !copy.isDirty)
        #expect(copy.fileURL == receipt.destinationURL)
        #expect(copy.documentIdentity != fixture.store.documentIdentity)
        #expect(copy.recoveryID != fixture.store.recoveryID && copy.recoveryID != oldRecovery.id)
        #expect(copy.undoManager !== fixture.store.undoManager && !copy.undoManager.canUndo)
        #expect(try fixture.repository.load().contains { $0.id == oldRecovery.id && $0.text == "Obsolete draft" })
        fixture.store.copyFlow.dismiss()
        #expect(fixture.store.copyFlow.receipt == nil && fixture.store.copyFlow.message == nil)
        #expect(try String(contentsOf: receipt.destinationURL, encoding: .utf8) == "Draft for copy")
        #expect(fixture.store.text == "Draft for copy" && fixture.store.isDirty)
    }
}
