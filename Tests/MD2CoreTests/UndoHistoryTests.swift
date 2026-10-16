import AppKit
import Foundation
import Testing
@testable import MD2App

/// Undo-history integrity at the model level: the document owns one undo
/// manager, its own edits land on it in order, and changes the history cannot
/// describe clear it. Runs headless (no window); the window/menu wiring and the
/// mode-switch lifecycle are covered by `UndoHistoryGUITests`.
struct TextReplacementTests {
    @Test func identicalTextsNeedNoReplacement() {
        #expect(TextReplacement(from: "same", to: "same") == nil)
        #expect(TextReplacement(from: "", to: "") == nil)
    }

    @Test func replacementCoversOnlyTheChangedRun() throws {
        let toggle = try #require(TextReplacement(from: "- [ ] Draft\n- [ ] Review", to: "- [x] Draft\n- [ ] Review"))
        #expect(toggle.range == NSRange(location: 3, length: 1))
        #expect(toggle.replacement == "x")

        let insertion = try #require(TextReplacement(from: "abc", to: "abXc"))
        #expect(insertion.range == NSRange(location: 2, length: 0))
        #expect(insertion.replacement == "X")

        let deletion = try #require(TextReplacement(from: "abXc", to: "abc"))
        #expect(deletion.range == NSRange(location: 2, length: 1))
        #expect(deletion.replacement == "")
    }

    @Test func boundariesNeverSplitASurrogatePair() throws {
        // U+1F600 and U+1F603 share their lead surrogate: a code-unit prefix
        // would end between the halves and leave a lone trail surrogate.
        let sharedLead = try #require(TextReplacement(from: "a\u{1F600}b", to: "a\u{1F603}b"))
        #expect(sharedLead.range == NSRange(location: 1, length: 2))
        #expect(sharedLead.replacement == "\u{1F603}")

        // U+1F600 and U+10600 share their trail surrogate: the suffix must not
        // start between the halves.
        let sharedTrail = try #require(TextReplacement(from: "a\u{1F600}", to: "a\u{10600}"))
        #expect(sharedTrail.range == NSRange(location: 1, length: 2))
        #expect(sharedTrail.replacement == "\u{10600}")
    }

    @Test func applyingTheReplacementYieldsTheNewText() throws {
        let pairs = [
            ("", "new"),
            ("old", ""),
            ("aaa", "aaaa"),
            ("line one\r\nline two", "line one\r\nline 2\r\nline three"),
            ("Teammate line one.\nTeammate line two.", "Teammate line one.\nInserted.\nTeammate line two."),
            ("x\u{1F600}y\u{1F600}z", "x\u{1F603}y\u{1F600}z")
        ]
        for (old, new) in pairs {
            let change = try #require(TextReplacement(from: old, to: new))
            let applied = (old as NSString).replacingCharacters(in: change.range, with: change.replacement)
            #expect(applied == new, "replacing \(change.range) of \(old.debugDescription)")
        }
    }
}

@MainActor
struct MarkdownEditorSessionTests {
    @Test func documentEditIsOneUndoStepAfterTyping() {
        let session = MarkdownEditorSession(undoManager: Self.stepwiseUndoManager())
        var published: [String] = []
        session.onUnmountedTextChange = { published.append($0) }
        let textView = session.loadTextView(text: "- [ ] Draft")

        Self.step(session.undoManager) {
            textView.insertText(" now", replacementRange: NSRange(location: 11, length: 0))
        }
        Self.step(session.undoManager) {
            #expect(session.applyUndoableEdit(changing: "- [ ] Draft now", to: "- [x] Draft now"))
        }
        #expect(textView.string == "- [x] Draft now")
        #expect(published.last == "- [x] Draft now", "an unmounted text view hands its text to the document")

        session.undoManager.undo()
        #expect(textView.string == "- [ ] Draft now", "Undo reverts the document's edit first")
        session.undoManager.undo()
        #expect(textView.string == "- [ ] Draft", "then the typing before it")
        #expect(published.last == "- [ ] Draft")
        session.undoManager.redo()
        session.undoManager.redo()
        #expect(textView.string == "- [x] Draft now")
    }

    @Test func documentEditIsRefusedWhenTheTextViewIsOutOfStep() {
        let session = MarkdownEditorSession(undoManager: Self.stepwiseUndoManager())
        _ = session.loadTextView(text: "- [ ] Draft")

        // The caller's text no longer matches the view: the edit's offsets would
        // land in the wrong place, so the caller must change the text itself.
        #expect(!session.applyUndoableEdit(changing: "- [ ] Other", to: "- [x] Other"))
        #expect(session.textView?.string == "- [ ] Draft")
        #expect(!session.undoManager.canUndo)
    }

    @Test func resetClearsTheHistoryItInvalidates() {
        let session = MarkdownEditorSession(undoManager: Self.stepwiseUndoManager())
        let textView = session.loadTextView(text: String(repeating: "Line of text.\n", count: 120))
        Self.step(session.undoManager) {
            let end = (textView.string as NSString).length
            textView.insertText("Typed at the end.", replacementRange: NSRange(location: end, length: 0))
        }
        #expect(session.undoManager.canUndo)

        // Shorter content: the typing action's range now lies past the end.
        #expect(session.resetText(to: "Short.\n"))
        #expect(textView.string == "Short.\n")
        #expect(!session.undoManager.canUndo, "an action addressing the replaced text would raise or corrupt it")
    }

    @Test func resetKeepsTheAttributesAroundTheChange() throws {
        let session = MarkdownEditorSession(undoManager: Self.stepwiseUndoManager())
        let textView = session.loadTextView(text: "# Heading\n\nBody one.\n")
        let storage = try #require(textView.textStorage)
        storage.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: 0, length: 9))

        #expect(session.resetText(to: "# Heading\n\nBody two.\n"))

        // A wholesale `string =` replaces every character, so no attribute run
        // survives where it was; the minimal replacement touches only the
        // changed word and leaves the heading's styling in place.
        let color = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == NSColor.systemRed)
        let bodyColor = storage.attribute(.foregroundColor, at: 11, effectiveRange: nil) as? NSColor
        #expect(bodyColor != NSColor.systemRed)
    }

    @Test func resetWaitsForAnActiveComposition() {
        // Marking text registers undo itself, so keep the default event grouping.
        let session = MarkdownEditorSession()
        let textView = session.loadTextView(text: "正文")
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.setMarkedText(
            "wubi",
            selectedRange: NSRange(location: 4, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        #expect(!session.resetText(to: "Reloaded"))
        #expect(textView.hasMarkedText(), "replacing the text would destroy the input method's buffer")
    }

    /// Undo grouping normally follows run-loop passes; these tests make every
    /// step an explicit group instead, standing in for one user event each.
    static func stepwiseUndoManager() -> UndoManager {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        return undoManager
    }

    static func step(_ undoManager: UndoManager, _ body: () -> Void) {
        undoManager.beginUndoGrouping()
        body()
        undoManager.endUndoGrouping()
    }
}

@MainActor
struct DocumentUndoHistoryTests {
    @Test func previewTaskToggleIsUndoable() {
        let store = DocumentStore()
        store.undoManager.groupsByEvent = false
        store.text = "# Tasks\n\n- [ ] Draft\n- [ ] Review"

        MarkdownEditorSessionTests.step(store.undoManager) {
            #expect(store.toggleTask(atLine: 3, to: true))
        }
        #expect(store.text == "# Tasks\n\n- [x] Draft\n- [ ] Review")
        #expect(store.isDirty)

        store.undoManager.undo()
        #expect(store.text == "# Tasks\n\n- [ ] Draft\n- [ ] Review")
        store.undoManager.redo()
        #expect(store.text == "# Tasks\n\n- [x] Draft\n- [ ] Review")
    }

    @Test func repeatedToggleLeavesNoEmptyUndoStep() {
        let store = DocumentStore()
        store.undoManager.groupsByEvent = false
        store.text = "- [x] Done"

        // No group is open, so registering anything here would raise.
        #expect(store.toggleTask(atLine: 1, to: true))
        #expect(store.text == "- [x] Done")
        #expect(!store.undoManager.canUndo)
    }

    @Test func togglesAndTypingUndoInReverseOrder() throws {
        let store = DocumentStore()
        store.undoManager.groupsByEvent = false
        store.text = "- [ ] One\n- [ ] Two"

        MarkdownEditorSessionTests.step(store.undoManager) {
            #expect(store.toggleTask(atLine: 1, to: true))
        }
        let textView = try #require(store.editorSession.textView)
        MarkdownEditorSessionTests.step(store.undoManager) {
            textView.insertText("\n- [ ] Three", replacementRange: NSRange(location: (textView.string as NSString).length, length: 0))
        }
        MarkdownEditorSessionTests.step(store.undoManager) {
            #expect(store.toggleTask(atLine: 2, to: true))
        }
        #expect(store.text == "- [x] One\n- [x] Two\n- [ ] Three")

        store.undoManager.undo()
        #expect(store.text == "- [x] One\n- [ ] Two\n- [ ] Three")
        store.undoManager.undo()
        #expect(store.text == "- [x] One\n- [ ] Two")
        store.undoManager.undo()
        #expect(store.text == "- [ ] One\n- [ ] Two")
        #expect(!store.undoManager.canUndo)
    }

    @Test func externalReloadClearsTheHistory() async throws {
        let watcher = ManualFileWatcher()
        let store = DocumentStore(fileWatcherFactory: { watcher })
        store.undoManager.groupsByEvent = false
        let url = try Self.makeTemporaryDocument("# Doc\n\n- [ ] Draft\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        store.open(url)
        MarkdownEditorSessionTests.step(store.undoManager) {
            #expect(store.toggleTask(atLine: 3, to: true))
        }
        #expect(store.save())
        #expect(store.undoManager.canUndo)

        let external = "Short.\n"
        try external.write(to: url, atomically: true, encoding: .utf8)
        watcher.fire()
        let requested = await Self.waitUntil { store.pendingExternalReload != nil }
        #expect(requested)
        store.completeExternalReload(anchor: nil)

        #expect(store.text == external)
        #expect(!store.isDirty)
        #expect(!store.undoManager.canUndo, "no recorded action may survive a reload")
        #expect(store.editorSession.textView?.string == external, "the editor's text view follows the reload")
    }

    @Test func openingAFileClearsTheHistory() throws {
        let store = DocumentStore()
        store.undoManager.groupsByEvent = false
        MarkdownEditorSessionTests.step(store.undoManager) {
            #expect(store.toggleTask(atLine: 5, to: true))
        }
        #expect(store.undoManager.canUndo)

        let url = try Self.makeTemporaryDocument("# Opened\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        store.open(url)

        #expect(store.text == "# Opened\n")
        #expect(!store.undoManager.canUndo)
        #expect(store.editorSession.textView?.string == "# Opened\n")
    }

    static func makeTemporaryDocument(_ content: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("md2-undo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("doc.md")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return condition()
    }
}

/// The store's injectable watcher, fired by hand.
@MainActor
private final class ManualFileWatcher: DocumentFileWatching {
    var onEvent: (() -> Void)?
    func watch(url: URL) {}
    func stop() {}
    func fire() { onEvent?() }
}
