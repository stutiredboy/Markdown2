import Foundation
import Testing
@testable import MD2App

/// Exercise the same comparison and revision-bound consent as the window.
@MainActor
func resolveDisplayedConflict(in store: DocumentStore, reloadingFromDisk: Bool) async throws {
    let comparison = try #require(await store.externalConflictComparison())
    try #require(await store.resolveExternalConflict(comparison, reloadingFromDisk: reloadingFromDisk))
}

/// Test double: the store's injectable watcher, driven manually.
@MainActor
private final class FakeFileWatcher: DocumentFileWatching {
    var onEvent: (() -> Void)?
    private(set) var watchedURLs: [URL] = []
    private(set) var stopCount = 0

    func watch(url: URL) { watchedURLs.append(url) }
    func stop() { stopCount += 1 }
    func fire() { onEvent?() }
}

@MainActor
private func waitUntil(
    timeout: TimeInterval = 3,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 30_000_000)
    }
    return condition()
}

@MainActor
private func settle(_ seconds: TimeInterval = 0.4) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

private func makeTempDocument(_ content: String, name: String = "doc.md") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("md2-external-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url
}

struct DocumentFileFingerprintTests {
    @Test func sameBytesCompareUnchangedAcrossDates() {
        let data = Data("# Doc\n".utf8)
        let older = DocumentFileFingerprint(modificationDate: Date(timeIntervalSince1970: 1), contentHash: DocumentFileFingerprint.hash(of: data))
        let newer = DocumentFileFingerprint(modificationDate: Date(), contentHash: DocumentFileFingerprint.hash(of: data))
        #expect(DocumentFileFingerprint.comparison(lastKnown: older, current: newer) == .unchanged)
    }

    @Test func differentBytesCompareContentChanged() {
        let a = DocumentFileFingerprint(modificationDate: nil, contentHash: DocumentFileFingerprint.hash(of: Data("a".utf8)))
        let b = DocumentFileFingerprint(modificationDate: nil, contentHash: DocumentFileFingerprint.hash(of: Data("b".utf8)))
        #expect(DocumentFileFingerprint.comparison(lastKnown: a, current: b) == .contentChanged)
    }

    @Test func missingFileComparesMissing() {
        let a = DocumentFileFingerprint(modificationDate: nil, contentHash: DocumentFileFingerprint.hash(of: Data("a".utf8)))
        #expect(DocumentFileFingerprint.comparison(lastKnown: a, current: nil) == .missing)
    }

    @Test func currentReadsDiskAndReportsMissing() throws {
        let url = try makeTempDocument("# On disk\n")
        let current = DocumentFileFingerprint.current(at: url)
        #expect(current != nil)
        #expect(current?.contentHash == DocumentFileFingerprint.hash(of: Data("# On disk\n".utf8)))
        try FileManager.default.removeItem(at: url)
        #expect(DocumentFileFingerprint.current(at: url) == nil)
    }
}

struct ExternalChangeDecisionTests {
    @Test func decisionMatrix() {
        #expect(ExternalChangeDecision.action(for: .unchanged, isDirty: false) == .ignore)
        #expect(ExternalChangeDecision.action(for: .unchanged, isDirty: true) == .ignore)
        #expect(ExternalChangeDecision.action(for: .contentChanged, isDirty: false) == .reloadPreservingViewport)
        #expect(ExternalChangeDecision.action(for: .contentChanged, isDirty: true) == .presentConflict)
        #expect(ExternalChangeDecision.action(for: .missing, isDirty: false) == .markDeletedDirty)
        #expect(ExternalChangeDecision.action(for: .missing, isDirty: true) == .markDeletedDirty)
    }
}

@MainActor
struct DocumentExternalChangeTests {
    private func makeStore(_ watcher: FakeFileWatcher) -> DocumentStore {
        DocumentStore(fileWatcherFactory: { watcher })
    }

    @Test func loadAttachesWatcherAndCloseDetaches() throws {
        let watcher = FakeFileWatcher()
        let store = makeStore(watcher)
        let url = try makeTempDocument("# Doc\n")
        store.open(url)
        #expect(watcher.watchedURLs == [url])
        store.stopWatchingFile()
        #expect(watcher.stopCount == 1)
    }

    @Test func ownSaveEventIsIgnored() async throws {
        let watcher = FakeFileWatcher()
        let store = makeStore(watcher)
        let url = try makeTempDocument("# Doc\n")
        store.open(url)
        store.text = "# Doc\n\nEdited body."
        #expect(store.save())
        watcher.fire()
        await settle()
        #expect(!store.hasExternalConflict)
        #expect(store.pendingExternalReload == nil)
        #expect(store.text == "# Doc\n\nEdited body.")
    }

    @Test func cleanExternalEditAutoReloadsPreservingIdentity() async throws {
        let watcher = FakeFileWatcher()
        let store = makeStore(watcher)
        let url = try makeTempDocument("# Doc\n")
        store.open(url)
        let identity = store.documentIdentity

        try "# Doc\n\nChanged outside.\n".write(to: url, atomically: true, encoding: .utf8)
        watcher.fire()
        let requested = await waitUntil { store.pendingExternalReload != nil }
        #expect(requested)

        store.completeExternalReload(anchor: nil)
        #expect(store.text == "# Doc\n\nChanged outside.\n")
        #expect(!store.isDirty)
        #expect(store.documentIdentity == identity)
        #expect(!store.hasExternalConflict)
    }

    @Test func metadataOnlyTouchIsIgnored() async throws {
        let watcher = FakeFileWatcher()
        let store = makeStore(watcher)
        let url = try makeTempDocument("# Doc\n")
        store.open(url)

        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: url.path
        )
        watcher.fire()
        await settle()
        #expect(store.pendingExternalReload == nil)
        #expect(!store.hasExternalConflict)
        #expect(store.text == "# Doc\n")
    }

    @Test func dirtyExternalEditRaisesConflictAndKeepMineOverwrites() async throws {
        let watcher = FakeFileWatcher()
        let store = makeStore(watcher)
        let url = try makeTempDocument("# Doc\n")
        store.open(url)
        store.text = "# Doc\n\nMy unsaved edit."

        try "# Doc\n\nExternal edit.\n".write(to: url, atomically: true, encoding: .utf8)
        watcher.fire()
        let conflicted = await waitUntil { store.hasExternalConflict }
        #expect(conflicted)
        #expect(store.text == "# Doc\n\nMy unsaved edit.")
        #expect(store.externalConflictRequest != nil)

        // A save while the conflict is unresolved never writes.
        #expect(!store.save())
        #expect(try String(contentsOf: url, encoding: .utf8) == "# Doc\n\nExternal edit.\n")

        try await resolveDisplayedConflict(in: store, reloadingFromDisk: false)
        #expect(!store.hasExternalConflict)
        #expect(store.save())
        #expect(try String(contentsOf: url, encoding: .utf8) == "# Doc\n\nMy unsaved edit.")
    }

    @Test func conflictReloadFromDiskDiscardsEdits() async throws {
        let watcher = FakeFileWatcher()
        let store = makeStore(watcher)
        let url = try makeTempDocument("# Doc\n")
        store.open(url)
        store.text = "# Doc\n\nMy unsaved edit."

        try "# Doc\n\nExternal edit.\n".write(to: url, atomically: true, encoding: .utf8)
        watcher.fire()
        let conflicted = await waitUntil { store.hasExternalConflict }
        #expect(conflicted)

        try await resolveDisplayedConflict(in: store, reloadingFromDisk: true)
        let requested = await waitUntil { store.pendingExternalReload != nil }
        #expect(requested)
        store.completeExternalReload(anchor: nil)

        #expect(store.text == "# Doc\n\nExternal edit.\n")
        #expect(!store.isDirty)
        #expect(!store.hasExternalConflict)
    }

    @Test func comparisonAndCopyKeepOriginalPausedUntilAnExplicitChoice() async throws {
        let url = try makeTempDocument("")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = MarkdownFileFormat(encoding: .utf16LE, hasBOM: true, lineEnding: .crlf)
        let base = "第一段\r\n\r\n第二段\r\n"
        let editor = base.replacingOccurrences(of: "第一段", with: "编辑器修改第一段")
        let disk = base.replacingOccurrences(of: "第二段", with: "磁盘修改第二段")
        try #require(format.encode(base)).write(to: url)
        let watcher = FakeFileWatcher()
        let recovery = DocumentRecoveryRepository(directory: directory.appendingPathComponent("Recovery"))
        let store = DocumentStore(fileWatcherFactory: { watcher }, recoveryRepository: recovery,
                                  autosaveDelay: 0.01, maximumAutosaveDelay: 0.03)
        defer { store.closeDocument(discardRecovery: true) }
        store.open(url)
        store.text = editor
        let diskBytes = try #require(format.encode(disk))
        try diskBytes.write(to: url)
        #expect(!store.save())
        let comparison = try #require(await store.externalConflictComparison())
        #expect(comparison.editorText == editor)
        #expect(comparison.diskText == disk)
        #expect(comparison.editorFormat == format && comparison.diskFormat == format)
        let receipt = try #require(await store.copyFlow.create(from: store, text: { L10n.text($0, language: .english) },
                                                               chooseName: { _ in "Manuscript Copy.md" }))
        #expect(try Data(contentsOf: receipt.destinationURL) == format.encode(editor))
        #expect(store.prepareForTermination())
        #expect(try recovery.load().first?.text == editor)
        store.deferExternalConflict()
        // Simulate a later watcher notification. It must not reopen a dismissed sheet.
        watcher.fire()
        await settle(0.12)
        #expect(store.externalConflictRequest == nil)
        #expect(store.hasExternalConflict && store.isDirty)
        #expect(try Data(contentsOf: url) == diskBytes)
        #expect(!store.save())
        #expect(store.externalConflictRequest != comparison.request)
        #expect(await !store.resolveExternalConflict(comparison, reloadingFromDisk: false))
        try await resolveDisplayedConflict(in: store, reloadingFromDisk: false)
        #expect(await waitUntil { !store.isDirty })
        #expect(try Data(contentsOf: url) == format.encode(editor))
    }

    @Test(arguments: [true, false])
    func decisionRejectsNewerDiskOrEditorRevision(reload: Bool) async throws {
        let url = try makeTempDocument("Base")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = makeStore(FakeFileWatcher())
        defer { store.closeDocument(discardRecovery: true) }
        store.open(url)
        store.text = "Editor draft"
        try Data("Disk version 1".utf8).write(to: url)
        #expect(!store.save())
        let original = try #require(await store.externalConflictComparison())
        try Data("Disk version 2".utf8).write(to: url)
        #expect(await !store.resolveExternalConflict(original, reloadingFromDisk: reload))
        let refreshed = try #require(await store.externalConflictComparison())
        #expect(refreshed.diskText == "Disk version 2")
        store.text = "More editor edits"
        #expect(await !store.resolveExternalConflict(refreshed, reloadingFromDisk: reload))
        #expect(store.hasExternalConflict && store.isDirty && store.pendingExternalReload == nil)
        #expect(try Data(contentsOf: url) == Data("Disk version 2".utf8))
    }

    @Test(arguments: [true, false])
    func encodingConversionInvalidatesComparedEditorFormat(duringViewportCapture: Bool) async throws {
        let url = try makeTempDocument("")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gbk = Data([0xd6, 0xdc, 0xb1, 0xa8]) // 周报
        try gbk.write(to: url)
        let watcher = FakeFileWatcher()
        let store = DocumentStore(fileWatcherFactory: { watcher }, autosaveDelay: 0.01)
        defer { store.closeDocument(discardRecovery: true) }
        store.open(url)
        try #require(store.fileFormat.encoding == .gbk)
        let editor = "周报🚀"
        store.text = editor
        try #require(try await waitForDocumentState { store.encodingConversionRequest != nil })
        #expect(try Data(contentsOf: url) == gbk)
        let disk = Data("External text".utf8)
        try disk.write(to: url)
        watcher.fire()
        try #require(try await waitForDocumentState { store.hasExternalConflict })
        let comparison = try #require(await store.externalConflictComparison())
        try #require(comparison.editorFormat.encoding == .gbk)
        if duringViewportCapture {
            try #require(await store.resolveExternalConflict(comparison, reloadingFromDisk: true))
        }

        // The outstanding encoding sheet can complete without changing a single code unit.
        store.resolveEncodingConversion(convertToUTF8: true)
        if duringViewportCapture {
            store.completeExternalReload(anchor: nil)
        } else {
            #expect(await !store.resolveExternalConflict(comparison, reloadingFromDisk: false))
        }
        #expect(store.hasExternalConflict && store.isDirty && store.text == editor)
        #expect(store.fileFormat.encoding == .utf8)
        #expect(try Data(contentsOf: url) == disk)
        let refreshed = try #require(await store.externalConflictComparison())
        #expect(refreshed.editorFormat.encoding == .utf8 && refreshed.editorText == editor)
    }

    @Test(arguments: [true, false])
    func reloadRejectsDiskChangeDuringViewportCapture(replacedWithIdenticalBytes: Bool) async throws {
        let url = try makeTempDocument("Base")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = makeStore(FakeFileWatcher())
        defer { store.closeDocument(discardRecovery: true) }
        store.open(url)
        store.text = "Editor draft"
        try Data("Disk version 1".utf8).write(to: url)
        #expect(!store.save())
        try await resolveDisplayedConflict(in: store, reloadingFromDisk: true)
        try #require(store.pendingExternalReload != nil && store.hasExternalConflict)
        #expect(!store.save())
        let latest = Data((replacedWithIdenticalBytes ? "Disk version 1" : "Disk version 2").utf8)
        try latest.write(to: url, options: replacedWithIdenticalBytes ? .atomic : [])
        store.completeExternalReload(anchor: nil)
        #expect(store.text == "Editor draft" && store.isDirty)
        #expect(store.hasExternalConflict && store.externalConflictRequest != nil)
        #expect(try Data(contentsOf: url) == latest)
    }

    @Test(arguments: [true, false])
    func aDisappearedConflictFileCanBeSavedElsewhere(deletedBeforeDeferral: Bool) async throws {
        let url = try makeTempDocument("Base")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let newURL = directory.appendingPathComponent("Recovered.md")
        var saveLocationRequests = 0
        let store = DocumentStore(saveLocationPicker: { _ in
            saveLocationRequests += 1
            return newURL
        }, fileWatcherFactory: { FakeFileWatcher() })
        defer { store.closeDocument(discardRecovery: true) }
        store.open(url)
        store.text = "Editor draft"
        try Data("Disk".utf8).write(to: url)
        #expect(!store.save())
        let comparison = try #require(await store.externalConflictComparison())
        if deletedBeforeDeferral {
            try FileManager.default.removeItem(at: url)
            #expect(await !store.resolveExternalConflict(comparison, reloadingFromDisk: false))
            #expect(await store.externalConflictComparison() == nil)
            store.deferExternalConflict()
        } else {
            store.deferExternalConflict()
            #expect(store.canReviewExternalConflict)
            try FileManager.default.removeItem(at: url)
            store.reviewExternalConflict()
            #expect(!store.canReviewExternalConflict)
            #expect(store.externalConflictRequest == nil)
            #expect(store.text == "Editor draft" && store.isDirty)
        }
        #expect(saveLocationRequests == 0)
        #expect(store.save())
        #expect(saveLocationRequests == 1)
        #expect(try Data(contentsOf: newURL) == Data("Editor draft".utf8))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func malformedDiskBytesCanBePreservedWithACopyOrExplicitlyReplaced() async throws {
        let url = try makeTempDocument("Base")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = makeStore(FakeFileWatcher())
        defer { store.closeDocument(discardRecovery: true) }
        store.open(url)
        store.text = "Editor draft"
        let invalid = Data([0xff, 0xfe, 0xff]) // An incomplete UTF-16 code unit after a BOM.
        try invalid.write(to: url)
        #expect(!store.save())
        let comparison = try #require(await store.externalConflictComparison())
        #expect(comparison.diskText == nil && comparison.diskFormat == nil)
        #expect(await !store.resolveExternalConflict(comparison, reloadingFromDisk: true))
        let receipt = try #require(await store.copyFlow.create(from: store, text: { L10n.text($0, language: .english) },
                                                               chooseName: { _ in "Copy.md" }))
        #expect(try Data(contentsOf: receipt.destinationURL) == Data("Editor draft".utf8))
        #expect(try Data(contentsOf: url) == invalid)
        #expect(await store.resolveExternalConflict(comparison, reloadingFromDisk: false))
        #expect(store.save())
        #expect(try Data(contentsOf: url) == Data("Editor draft".utf8))
    }

    @Test func writeAbortsOnUnseenExternalChange() async throws {
        let watcher = FakeFileWatcher()
        let store = makeStore(watcher)
        let url = try makeTempDocument("# Doc\n")
        store.open(url)
        store.text = "# Doc\n\nMy unsaved edit."

        // External change lands without any watcher event (the race the
        // write-time check closes).
        try "# Doc\n\nExternal edit.\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(!store.save())
        #expect(store.hasExternalConflict)
        #expect(try String(contentsOf: url, encoding: .utf8) == "# Doc\n\nExternal edit.\n")
    }

    @Test func keepingCleanEditorVersionMarksItUnsavedUntilAutosaveRestoresDisk() async throws {
        let url = try makeTempDocument("base")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recovery = DocumentRecoveryRepository(directory: directory.appendingPathComponent("Recovery"))
        let store = DocumentStore(fileWatcherFactory: { FakeFileWatcher() }, recoveryRepository: recovery,
                                  autosaveDelay: 0.5)
        defer { store.closeDocument(discardRecovery: true) }
        store.open(url)
        try #require(store.text == "base" && !store.isDirty)

        let theirs = Data("theirs".utf8)
        // Do not fire the watcher. Save must discover the external write first.
        try theirs.write(to: url, options: .atomic)
        #expect(!store.save())
        try #require(store.hasExternalConflict)
        try await resolveDisplayedConflict(in: store, reloadingFromDisk: false)

        #expect(!store.hasExternalConflict)
        #expect(store.text == "base")
        #expect(try Data(contentsOf: url) == theirs)
        #expect(store.isDirty)
        let snapshot = try #require(try recovery.load().first)
        #expect(snapshot.text == "base" && snapshot.isDirty)

        // Autosave shares the main actor with the rest of the parallel suite.
        try #require(await waitUntil(timeout: 30) { !store.isDirty })
        #expect(try Data(contentsOf: url) == Data("base".utf8))
        #expect(store.closeDocument(discardRecovery: true))
        let reopened = makeStore(FakeFileWatcher())
        defer { reopened.closeDocument(discardRecovery: true) }
        reopened.open(url)
        #expect(reopened.text == "base" && !reopened.isDirty)
    }

    @Test func keepingEditorVersionCancelsAnExternalReloadAwaitingItsViewport() async throws {
        let url = try makeTempDocument("base")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let watcher = FakeFileWatcher()
        let store = makeStore(watcher)
        defer { store.closeDocument(discardRecovery: true) }
        store.open(url)

        let theirs = Data("theirs".utf8)
        try theirs.write(to: url, options: .atomic)
        watcher.fire()
        try #require(await waitUntil { store.pendingExternalReload != nil })
        #expect(store.text == "base" && !store.isDirty)
        #expect(!store.save())
        try #require(store.hasExternalConflict)
        try await resolveDisplayedConflict(in: store, reloadingFromDisk: false)

        // A Read-mode viewport callback can arrive after the conflict is resolved.
        store.completeExternalReload(anchor: nil)
        #expect(store.pendingExternalReload == nil)
        #expect(!store.hasExternalConflict)
        #expect(store.text == "base" && store.isDirty)
        #expect(try Data(contentsOf: url) == theirs)
        #expect(store.save())
        #expect(!store.isDirty)
        #expect(try Data(contentsOf: url) == Data("base".utf8))
    }

    @Test func externalDeletionMarksDirtyAndExplicitSaveCanRecreate() async throws {
        let watcher = FakeFileWatcher()
        let url = try makeTempDocument("# Doc\n")
        let store = DocumentStore(saveLocationPicker: { _ in url }, fileWatcherFactory: { watcher })
        store.open(url)
        #expect(!store.isDirty)

        try FileManager.default.removeItem(at: url)
        watcher.fire()
        let marked = await waitUntil { store.isDirty }
        #expect(marked)
        #expect(store.text == "# Doc\n")

        #expect(store.save())
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try String(contentsOf: url, encoding: .utf8) == "# Doc\n")
        #expect(!store.isDirty)
    }

    @Test(arguments: [false, true])
    func manualSavePreservesUnverifiableReplacement(isFIFO: Bool) throws {
        let watcher = FakeFileWatcher()
        let url = try makeTempDocument("Original")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveredURL = directory.appendingPathComponent("recovered.md")
        let repository = DocumentRecoveryRepository(directory: directory.appendingPathComponent("recovery"))
        var destination = url
        let store = DocumentStore(saveLocationPicker: { _ in destination }, fileWatcherFactory: { watcher },
                                  recoveryRepository: repository)
        defer { store.closeDocument(discardRecovery: true) }
        store.open(url)
        store.text = "Keep my edits"

        try FileManager.default.removeItem(at: url)
        if isFIFO {
            try #require(mkfifo(url.path, 0o600) == 0)
        } else {
            try Data("External contents".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: url.path)
        }
        // No watcher notification has arrived. Even explicitly selecting the
        // original pathname must not replace an entry we cannot verify.
        #expect(!store.save())
        #expect(store.isDirty)
        #expect(store.alert != nil)
        #expect(try repository.load().first?.text == "Keep my edits")
        if isFIFO {
            var info = stat()
            #expect(lstat(url.path, &info) == 0)
            #expect(info.st_mode & S_IFMT == S_IFIFO)
        } else {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            #expect(try String(contentsOf: url, encoding: .utf8) == "External contents")
            try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: url.path)
        }
        destination = recoveredURL
        #expect(store.save())
        #expect(try String(contentsOf: recoveredURL, encoding: .utf8) == "Keep my edits")
    }

    @Test func recreatingMissingFilePreservesNewOccupantWithSameBytes() throws {
        let watcher = FakeFileWatcher()
        let url = try makeTempDocument("Original")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = DocumentStore(saveLocationPicker: { _ in
            // The absent pathname becomes occupied while the save panel is
            // running. An identical fingerprint does not authorize this write.
            try! Data("Original".utf8).write(to: url)
            return url
        }, fileWatcherFactory: { watcher })
        defer { store.closeDocument(discardRecovery: true) }
        store.open(url)
        try FileManager.default.removeItem(at: url)
        store.text = "Keep my edits"

        #expect(!store.save())
        #expect(try String(contentsOf: url, encoding: .utf8) == "Original")
        #expect(store.text == "Keep my edits")
        #expect(store.isDirty)
    }
}

@MainActor
struct DispatchSourceFileWatcherTests {
    @Test func firesOnWriteAndStopsCleanly() async throws {
        let url = try makeTempDocument("# Doc\n")
        let watcher = DispatchSourceFileWatcher()
        var events = 0
        watcher.onEvent = { events += 1 }
        watcher.watch(url: url)

        try "# Doc\n\nchanged\n".write(to: url, atomically: true, encoding: .utf8)
        let fired = await waitUntil(timeout: 4) { events > 0 }
        #expect(fired)

        watcher.stop()
        let baseline = events
        try "# Doc\n\nchanged again\n".write(to: url, atomically: true, encoding: .utf8)
        await settle(0.8)
        #expect(events == baseline)
    }

    @Test func survivesAtomicReplacementAndKeepsWatching() async throws {
        let url = try makeTempDocument("# Doc\n")
        let watcher = DispatchSourceFileWatcher()
        var events = 0
        watcher.onEvent = { events += 1 }
        watcher.watch(url: url)

        // Atomic write replaces the inode (delete+rename on the old one).
        try "# Doc v2\n".write(to: url, atomically: true, encoding: .utf8)
        let firstFired = await waitUntil(timeout: 4) { events > 0 }
        #expect(firstFired)

        // The watcher must have re-armed on the new inode.
        let baseline = events
        try "# Doc v3\n".write(to: url, atomically: true, encoding: .utf8)
        let secondFired = await waitUntil(timeout: 4) { events > baseline }
        #expect(secondFired)
        watcher.stop()
    }
}
