import AppKit
import SwiftUI
import Testing
@testable import MD2App

@MainActor
private final class SafetyBoundaryWatcher: DocumentFileWatching {
    var onEvent: (() -> Void)?
    func watch(url: URL) {}
    func stop() {}
    func fire() { onEvent?() }
}

@MainActor
struct DocumentSafetyBoundaryTests {
    @Test func externalReloadDuringCompositionCannotSilentlyOverwriteDiskOnCommit() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("md2-ime-reload-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.md")
        let original = "# Original\n中文正文\n"
        let external = "# External\nA teammate replaced the entire document.\n"
        try original.write(to: url, atomically: true, encoding: .utf8)
        let watcher = SafetyBoundaryWatcher()
        let store = DocumentStore(fileWatcherFactory: { watcher }, autosaveDelay: 0.02)
        defer { store.closeDocument(discardRecovery: true) }
        store.open(url)
        let session = store.editorSession
        let editor = session.loadTextView(text: store.text)
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(get: { store.text }, set: { store.text = $0 }), session: session)
        let scrollView = NSScrollView()
        session.host(in: scrollView, coordinator: coordinator)
        editor.setSelectedRange(NSRange(location: original.utf16.count, length: 0))
        editor.setMarkedText("wubi", selectedRange: NSRange(location: 4, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        #expect(!store.isDirty)
        #expect(store.text == original)
        try external.write(to: url, atomically: true, encoding: .utf8)
        watcher.fire()
        for _ in 0..<100 where store.pendingExternalReload == nil && !store.hasExternalConflict {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.pendingExternalReload != nil || store.hasExternalConflict)
        store.completeExternalReload(anchor: nil)
        #expect(store.text == original)
        #expect(editor.hasMarkedText(), "a refused reload must preserve the input method's buffer")
        editor.insertText("输入", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!editor.hasMarkedText())
        #expect(store.text == original + "输入")
        try await Task.sleep(for: .milliseconds(60))
        #expect(try String(contentsOf: url, encoding: .utf8) == external, "autosave must remain suspended")
        let saved = store.save()
        let disk = try String(contentsOf: url, encoding: .utf8)
        #expect(!saved)
        #expect(store.hasExternalConflict)
        #expect(disk == external)

        // A fresh explicit choice after composition still reloads normally.
        store.resolveExternalConflict(reloadingFromDisk: true)
        store.completeExternalReload(anchor: nil)
        #expect(store.text == external)
        #expect(editor.string == external)
        #expect(!store.isDirty)
        #expect(!store.hasExternalConflict)
        #expect(!store.undoManager.canUndo)
    }

    @Test(arguments: [false, true])
    func fileOpenDoesNotReuseAStarterWithAnActiveComposition(restoring: Bool) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("md2-composing-starter-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("existing.md")
        let diskText = "# Existing document\nNever replace this with the starter.\n"
        try diskText.write(to: url, atomically: true, encoding: .utf8)
        let store = DocumentStore(saveLocationPicker: { _ in nil }, autosaveDelay: 60)
        defer { store.closeDocument(discardRecovery: true) }
        let starter = store.text
        #expect(store.isReusableEmptyDocument)
        let editor = store.editorSession.loadTextView(text: starter)
        let coordinator = MarkdownEditorView.Coordinator(
            text: Binding(get: { store.text }, set: { store.text = $0 }), session: store.editorSession)
        let scrollView = NSScrollView()
        store.editorSession.host(in: scrollView, coordinator: coordinator)
        editor.setSelectedRange(NSRange(location: starter.utf16.count, length: 0))
        editor.setMarkedText("wubi", selectedRange: NSRange(location: 4, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        #expect(!store.isDirty)
        #expect(!store.isReusableEmptyDocument)
        // Both AppDelegate entry points use this predicate before reusing an
        // existing starter. Follow that branch without needing a window server.
        if store.isReusableEmptyDocument {
            if restoring {
                store.restore(DocumentRecoverySnapshot(
                    id: UUID(), text: "# Recovered unsaved work\n", fileURL: url,
                    identity: DocumentFileIdentity(url: url), format: .init(),
                    fingerprint: DocumentFileFingerprint.current(at: url), isDirty: true, windowFrame: nil))
            } else {
                store.open(url)
            }
        }
        editor.insertText("输入", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(store.text == starter + "输入")
        #expect(store.isDirty)
        #expect(!store.isReusableEmptyDocument)
        #expect(store.fileURL == nil)
        #expect(!store.save(), "the composing starter must still be an unsaved document")
        #expect(try String(contentsOf: url, encoding: .utf8) == diskText)
    }

    @Test func externalChangeDuringEncodingPromptIsNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("md2-encoding-boundary-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("gbk.md")
        try Data([0xd6, 0xdc, 0xb1, 0xa8]).write(to: url)
        let external = "# New external content\n"
        var prompts = 0
        let store = DocumentStore(confirmEncodingConversion: { _ in
            prompts += 1
            try! external.write(to: url, atomically: true, encoding: .utf8)
            return true
        })
        defer { store.closeDocument(discardRecovery: true) }
        store.open(url)
        store.text += "🚀"
        let saved = store.save()
        let disk = try String(contentsOf: url, encoding: .utf8)
        #expect(prompts == 1)
        #expect(!saved)
        #expect(store.hasExternalConflict)
        #expect(disk == external)
        #expect(store.fileFormat.encoding == .gbk)
        #expect(store.isDirty)
    }

    @Test(arguments: [false, true])
    func acceptedEncodingConversionPreservesDestinationIdentity(renameDuringPrompt: Bool) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("md2-encoding-rename-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let originalURL = dir.appendingPathComponent("gbk.md")
        let movedURL = dir.appendingPathComponent("renamed.md")
        try Data([0xd6, 0xdc, 0xb1, 0xa8]).write(to: originalURL)
        let unrelated = "Unrelated replacement at the old path."
        var prompts = 0
        let store = DocumentStore(confirmEncodingConversion: { _ in
            prompts += 1
            if renameDuringPrompt {
                try! FileManager.default.moveItem(at: originalURL, to: movedURL)
                try! unrelated.write(to: originalURL, atomically: true, encoding: .utf8)
            }
            return true
        })
        defer { store.closeDocument(discardRecovery: true) }
        store.open(originalURL)
        store.text += "🚀"
        #expect(store.save())
        #expect(prompts == 1)
        let destination = renameDuringPrompt ? movedURL : originalURL
        #expect(store.fileURL?.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath())
        #expect(store.fileFormat.encoding == .utf8)
        #expect(!store.isDirty)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "周报🚀")
        if renameDuringPrompt {
            #expect(try String(contentsOf: originalURL, encoding: .utf8) == unrelated)
        }
    }
}
