import AppKit
import Combine
import Testing
@testable import MD2App

/// Deterministic publisher/worker coverage. Actual application-window routing is
/// covered separately by the isolated-bundle menu XCTest cases.
@MainActor
struct AttachmentCommandStateTests {
    @Test func currentDocumentAndBusySubscriptionsFollowFocusAndClose() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AttachmentCommands-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func store(_ name: String) throws -> DocumentStore {
            let url = root.appendingPathComponent(name + ".md")
            try "# \(name)\n".write(to: url, atomically: true, encoding: .utf8)
            let store = DocumentStore()
            store.open(url)
            return store
        }
        let first = try store("First"), second = try store("Second")
        defer {
            _ = first.closeDocument(discardRecovery: true)
            _ = second.closeDocument(discardRecovery: true)
        }
        let state = AttachmentCommandState()
        var focused: DocumentStore?
        state.observeCurrentDocument { focused }
        var published: [Bool] = []
        let observation = state.$canCollect.sink { published.append($0) }
        defer { observation.cancel() }
        #expect(state.document == nil && !state.canCollect)
        focused = first
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: nil)
        try await waitUntil { state.document === first && state.canCollect }
        let gate = CommandAttachmentGate()
        first.attachmentWorker = { job in
            await gate.pause()
            return await Task.detached { job.run() }.value
        }
        let task = Task { await first.collectLocalImages(folder: "assets") }
        try await waitUntil { first.isWorkingOnAttachments && !state.canCollect }
        focused = second
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: nil)
        try await waitUntil { state.document === second && state.canCollect }
        focused = first
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: nil)
        try await waitUntil { state.document === first && !state.canCollect }
        await gate.release()
        await task.value
        #expect(!first.isWorkingOnAttachments && state.document === first && state.canCollect)

        // An unrelated key window resolves to nil. Completing a previously
        // observed document must not re-enable that window's collection command.
        let inactiveGate = CommandAttachmentGate()
        first.attachmentWorker = { job in
            await inactiveGate.pause()
            return await Task.detached { job.run() }.value
        }
        let inactiveTask = Task { await first.collectLocalImages(folder: "assets") }
        try await waitUntil { first.isWorkingOnAttachments && !state.canCollect }
        focused = nil
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: nil)
        try await waitUntil { state.document == nil && !state.canCollect }
        await inactiveGate.release()
        await inactiveTask.value
        #expect(state.document == nil && !state.canCollect)
        focused = second
        state.refresh() // Registry append/remove also refresh without a notification.
        #expect(state.document === second && state.canCollect)
        focused = nil
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: nil)
        try await waitUntil { state.document == nil && !state.canCollect }
        #expect(published.contains(true))
        #expect(published.last == false)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(predicate())
    }
}

private actor CommandAttachmentGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func pause() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
