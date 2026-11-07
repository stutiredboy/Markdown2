import Foundation
import Testing
@testable import MD2App
@testable import MD2Core

@MainActor
private final class MutationBoundaryWatcher: DocumentFileWatching {
    var onEvent: (() -> Void)?
    func watch(url: URL) {}
    func stop() {}
}

@MainActor
struct DocumentMutationBoundaryTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("md2-mutation-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test(arguments: [
        ("# café", "# cafe\u{301}"),
        ("# cafe\u{301}", "# café"),
        ("# a\u{301}\u{327}", "# a\u{327}\u{301}")
    ])
    func normalizationOnlyEditsRemainRealDocumentChanges(before: String, after: String) async throws {
        #expect(before == after, "positive control: Swift canonical equality hides the byte change")
        #expect(Array(before.utf8) != Array(after.utf8))
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notes.md")
        try Data(before.utf8).write(to: file)
        let recovery = DocumentRecoveryRepository(directory: dir.appendingPathComponent("recovery"))
        let store = DocumentStore(fileWatcherFactory: { MutationBoundaryWatcher() }, recoveryRepository: recovery,
                                  autosaveDelay: 60, maximumAutosaveDelay: 60)
        defer { _ = store.closeDocument(discardRecovery: true) }
        store.open(file)
        await store.flushPendingRender()
        let revision = store.sourceLineRevision
        store.text = after
        #expect(store.isDirty)
        #expect(store.sourceLineRevision == revision + 1)
        await store.flushPendingRender()
        #expect(store.renderedSourceLineRevision == revision + 1)
        #expect(Array(store.rendered.body.utf8) == Array(MarkdownRenderer().render(after, assetMode: .appScheme).body.utf8))
        #expect(store.persistRecoveryNow())
        let snapshot = try #require(recovery.load().first)
        #expect(snapshot.isDirty)
        #expect(Array(snapshot.text.utf8) == Array(after.utf8))
        #expect(store.save())
        #expect(try Data(contentsOf: file) == Data(after.utf8))
        #expect(!store.isDirty)
    }

    @Test func normalizationOnlyEditSchedulesAutosave() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notes.md")
        try Data("café".utf8).write(to: file)
        let store = DocumentStore(fileWatcherFactory: { MutationBoundaryWatcher() },
                                  autosaveDelay: 0.02, maximumAutosaveDelay: 0.1)
        defer { _ = store.closeDocument(discardRecovery: true) }
        store.open(file)
        store.text = "cafe\u{301}"
        let expected = Data(store.text.utf8)
        // Establish that the edit's queued work has run before measuring the
        // save wait. Other MainActor tests can delay even the timer's start;
        // flushPendingRender never saves or creates missing autosave work.
        await store.flushPendingRender()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < deadline, (try Data(contentsOf: file)) != expected {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try Data(contentsOf: file) == expected)
        #expect(!store.isDirty)
    }

    @Test(arguments: [false, true])
    func reloadConsentDoesNotDiscardLaterTypingOrTaskClicks(taskClick: Bool) async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notes.md")
        try Data("# Original".utf8).write(to: file)
        let store = DocumentStore(fileWatcherFactory: { MutationBoundaryWatcher() },
                                  autosaveDelay: 60, maximumAutosaveDelay: 60)
        defer { _ = store.closeDocument(discardRecovery: true) }
        store.open(file)
        store.text = "- [ ] draft task"
        await store.flushPendingRender()
        let revision = store.sourceLineRevision
        let external = Data("# External version".utf8)
        try external.write(to: file)
        #expect(!store.save())
        try #require(store.hasExternalConflict)
        store.resolveExternalConflict(reloadingFromDisk: true)
        try #require(store.pendingExternalReload != nil)
        if taskClick {
            try #require(store.rendered.body.contains("data-md2-task-line=\"1\""))
            #expect(store.toggleTask(atLine: 1, to: true, renderedAt: revision))
            #expect(store.sourceLineRevision == revision, "task toggles intentionally keep source-line mapping valid")
        } else {
            store.text += "\nNew typing after confirmation"
        }
        let latest = Data(store.text.utf8)
        store.completeExternalReload(anchor: nil)
        #expect(Data(store.text.utf8) == latest)
        #expect(store.isDirty)
        #expect(store.hasExternalConflict)
        #expect(store.externalConflictRequest != nil)
        #expect(try Data(contentsOf: file) == external)
        // A fresh consent for this exact state still performs a legitimate reload.
        store.resolveExternalConflict(reloadingFromDisk: true)
        store.completeExternalReload(anchor: nil)
        #expect(Data(store.text.utf8) == external)
        #expect(!store.isDirty)
        #expect(!store.hasExternalConflict)
    }
}
