import Foundation
import Testing
@testable import MD2App

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

        store.resolveExternalConflict(reloadingFromDisk: false)
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

        store.resolveExternalConflict(reloadingFromDisk: true)
        let requested = await waitUntil { store.pendingExternalReload != nil }
        #expect(requested)
        store.completeExternalReload(anchor: nil)

        #expect(store.text == "# Doc\n\nExternal edit.\n")
        #expect(!store.isDirty)
        #expect(!store.hasExternalConflict)
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

    @Test func externalDeletionMarksDirtyAndSaveRecreates() async throws {
        let watcher = FakeFileWatcher()
        let store = makeStore(watcher)
        let url = try makeTempDocument("# Doc\n")
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
