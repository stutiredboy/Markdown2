import AppKit
import Foundation
import Testing
@testable import MD2App

@MainActor
struct DocumentHistoryFlowTests {
    @Test func restoreSelectedDiskVersionProtectsDraftAndOpensAnIndependentCopy() async throws {
        let format = MarkdownFileFormat(encoding: .utf16BE, hasBOM: true, lineEnding: .mixed)
        let original = "# 初稿\r\n![图](assets/figure.png)\r第三行\n"
        let bytes = try #require(format.encode(original))
        let fixture = try HistoryFlowFixture(bytes: bytes)
        defer { fixture.close() }
        let source = fixture.store
        let documentID = source.documentIdentity
        let recoveryID = source.recoveryID
        source.text += "Second version\r\n"
        #expect(source.save())
        let currentDisk = try Data(contentsOf: fixture.file)
        let watched = fixture.watcher.observed

        let draft = "Unsaved version\n"
        source.undoManager.beginUndoGrouping()
        #expect(source.editorSession.applyUndoableEdit(changing: source.text, to: draft))
        source.undoManager.endUndoGrouping()
        #expect(source.persistRecoveryNow())
        let recoveryURL = fixture.recovery.directory.appendingPathComponent(recoveryID.uuidString + ".json")
        let recoveryBefore = try Data(contentsOf: recoveryURL)

        let browser = try DocumentHistoryFlow(store: source)
        await browser.load()
        #expect(browser.revisions.map(\.reason) == [.saved, .opened])
        try await choose(try #require(browser.revisions.last), in: browser)
        #expect(browser.excerpt == original)
        #expect(await browser.restore(named: fixture.file.lastPathComponent, makeStore: fixture.newStore) == nil)
        #expect(browser.message == .copyNameExists)
        let copy = try #require(await browser.restore(named: fixture.copy.lastPathComponent, makeStore: fixture.newStore))
        defer { copy.closeDocument(discardRecovery: true) }

        #expect(copy.fileURL == fixture.copy && copy.text == original && copy.fileFormat == format)
        #expect(!copy.isDirty && !copy.undoManager.canUndo && copy.recoveryID != recoveryID)
        #expect(copy.documentIdentity != documentID)
        #expect(try Data(contentsOf: fixture.copy) == bytes)
        #expect(try Data(contentsOf: fixture.file) == currentDisk)
        #expect(try Data(contentsOf: recoveryURL) == recoveryBefore)
        #expect(source.text == draft && source.isDirty && source.documentIdentity == documentID)
        #expect(source.recoveryID == recoveryID && fixture.watcher.observed == watched)
        source.undoManager.undo()
        #expect(source.text == original + "Second version\r\n")
        #expect(copy.text == original)
    }

    @Test func offlineRenameTracksTheFileWithoutGivingHistoryToAReusedName() async throws {
        let fixture = try HistoryFlowFixture()
        defer { fixture.close() }
        fixture.store.text = "Edited"
        #expect(fixture.store.save())
        let moved = fixture.file.deletingLastPathComponent().appendingPathComponent("moved.md")
        try FileManager.default.moveItem(at: fixture.file, to: moved)
        try Data("Different document".utf8).write(to: fixture.file)

        let reused = fixture.newStore()
        defer { reused.closeDocument(discardRecovery: true) }
        reused.open(fixture.file)
        let reusedHistory = try DocumentHistoryFlow(store: reused)
        await reusedHistory.load()
        #expect(reusedHistory.revisions.map(\.reason) == [.opened])
        try await choose(try #require(reusedHistory.revisions.first), in: reusedHistory)
        #expect(reusedHistory.excerpt == "Different document")

        let reopened = fixture.newStore()
        defer { reopened.closeDocument(discardRecovery: true) }
        reopened.open(moved)
        let movedHistory = try DocumentHistoryFlow(store: reopened)
        await movedHistory.load()
        #expect(movedHistory.revisions.map(\.reason) == [.saved, .opened])
    }

    @Test func acceptedExternalReloadRecordsInPlaceEditsAndSeparatesAnAtomicReplacement() async throws {
        let fixture = try HistoryFlowFixture()
        defer { fixture.close() }
        let store = fixture.store
        store.text = "Unsaved conflict draft"
        try Data("In-place external edit".utf8).write(to: fixture.file)
        #expect(!store.save() && store.hasExternalConflict)
        let browser = try DocumentHistoryFlow(store: store)
        await browser.load()
        #expect(browser.revisions.map(\.reason) == [.opened])
        try await choose(try #require(browser.revisions.first), in: browser)
        let copy = try #require(await browser.restore(named: fixture.copy.lastPathComponent, makeStore: fixture.newStore))
        defer { copy.closeDocument(discardRecovery: true) }
        #expect(copy.text == "First version")
        #expect(store.hasExternalConflict && store.text == "Unsaved conflict draft")
        #expect(try String(contentsOf: fixture.file, encoding: .utf8) == "In-place external edit")
        store.resolveExternalConflict(reloadingFromDisk: true)
        store.completeExternalReload(anchor: nil)

        let accepted = try DocumentHistoryFlow(store: store)
        await accepted.load()
        #expect(accepted.revisions.map(\.reason) == [.externalReload, .opened])
        try await choose(try #require(accepted.revisions.first), in: accepted)

        try Data("Replaced in the cloud".utf8).write(to: fixture.file, options: .atomic)
        #expect(await accepted.restore(named: "stale.md", makeStore: fixture.newStore) == nil)
        #expect(accepted.message == .historySourceChanged)
        #expect(!FileManager.default.fileExists(atPath: fixture.file.deletingLastPathComponent().appendingPathComponent("stale.md").path))
        #expect(!store.save() && store.hasExternalConflict)
        store.resolveExternalConflict(reloadingFromDisk: true)
        store.completeExternalReload(anchor: nil)
        let replacement = try DocumentHistoryFlow(store: store)
        await replacement.load()
        #expect(replacement.revisions.map(\.reason) == [.externalReload])
        #expect(!store.isDirty && store.text == "Replaced in the cloud")
    }

    @Test func selectionDeletedAfterPreviewFailsSafelyAndDocumentStillOpens() async throws {
        let fixture = try HistoryFlowFixture()
        defer { fixture.close() }
        let browser = try DocumentHistoryFlow(store: fixture.store)
        await browser.load()
        try await choose(try #require(browser.revisions.first), in: browser)
        try await fixture.history.removeAll()

        #expect(await browser.restore(named: fixture.copy.lastPathComponent, makeStore: fixture.newStore) == nil)
        #expect(browser.message == .historyRevisionUnavailable)
        #expect(!FileManager.default.fileExists(atPath: fixture.copy.path))

        let reopened = fixture.newStore()
        defer { reopened.closeDocument(discardRecovery: true) }
        reopened.open(fixture.file)
        #expect(reopened.text == "First version" && !reopened.isDirty)
    }

    @Test func restoringAnASCIIVersionOfALegacyFileRetainsItsSavedFormat() async throws {
        let fixture = try HistoryFlowFixture(bytes: Data([0xd6, 0xd0, 0x0d, 0x0a]))
        defer { fixture.close() }
        fixture.store.text = "ASCII only"
        #expect(fixture.store.save())
        let browser = try DocumentHistoryFlow(store: fixture.store)
        await browser.load()
        try await choose(try #require(browser.revisions.first), in: browser)
        let copy = try #require(await browser.restore(named: fixture.copy.lastPathComponent, makeStore: fixture.newStore))
        defer { copy.closeDocument(discardRecovery: true) }
        #expect(copy.text == "ASCII only")
        #expect(copy.fileFormat == .init(encoding: .gbk, lineEnding: .crlf))
        copy.text += "\n中文"
        #expect(copy.save())
        #expect(try Data(contentsOf: fixture.copy) == Data("ASCII only\r\n".utf8) + Data([0xd6, 0xd0, 0xce, 0xc4]))
        await fixture.history.flush()
    }

    @Test func disabledRecordingKeepsEarlierRevisionsAcrossSaveWithoutCapturingNewText() async throws {
        var enabled = true
        let fixture = try HistoryFlowFixture(keepsHistory: { enabled })
        defer { fixture.close() }
        enabled = false
        fixture.store.text = "Text saved while history is off"
        #expect(fixture.store.save())
        do {
            _ = try DocumentHistoryFlow(store: fixture.store)
            Issue.record("History should be unavailable while disabled")
        } catch DocumentHistoryFlowError.disabled {}

        enabled = true
        let browser = try DocumentHistoryFlow(store: fixture.store)
        await browser.load()
        #expect(browser.revisions.map(\.reason) == [.opened])
        try await choose(try #require(browser.revisions.first), in: browser)
        #expect(browser.excerpt == "First version")
    }

    private func choose(_ revision: DocumentHistoryRevision, in browser: DocumentHistoryFlow) async throws {
        browser.select(revision)
        for _ in 0..<100 {
            if !browser.isLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!browser.isLoading && browser.excerpt != nil)
    }
}

@MainActor
private final class HistoryFlowFixture {
    let directory: URL
    let file: URL
    let copy: URL
    let history: DocumentHistoryRepository
    let recovery: DocumentRecoveryRepository
    let watcher = HistoryFlowWatcher()
    let store: DocumentStore

    init(bytes: Data = Data("First version".utf8), keepsHistory: @escaping @MainActor () -> Bool = { true }) throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("md2-history-flow-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("source.md")
        copy = directory.appendingPathComponent("copy.md")
        history = DocumentHistoryRepository(directory: directory.appendingPathComponent("history", isDirectory: true))
        recovery = DocumentRecoveryRepository(directory: directory.appendingPathComponent("recovery", isDirectory: true))
        try bytes.write(to: file)
        let watcher = watcher
        store = DocumentStore(fileWatcherFactory: { watcher }, recoveryRepository: recovery, historyRepository: history,
            keepsLocalHistory: keepsHistory,
            autosaveDelay: 3_600, maximumAutosaveDelay: 3_600, recoveryDelay: 3_600)
        store.open(file)
    }

    func newStore() -> DocumentStore {
        DocumentStore(fileWatcherFactory: { HistoryFlowWatcher() }, recoveryRepository: recovery,
            historyRepository: history, autosaveDelay: 3_600, maximumAutosaveDelay: 3_600, recoveryDelay: 3_600)
    }

    func close() {
        store.closeDocument(discardRecovery: true)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class HistoryFlowWatcher: DocumentFileWatching {
    var onEvent: (() -> Void)?
    var observed: [URL] = []
    func watch(url: URL) { observed.append(url) }
    func stop() {}
}
