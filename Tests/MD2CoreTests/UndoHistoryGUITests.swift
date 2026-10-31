import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

/// GUI-gated regression guards for undo-history integrity across the editor's
/// lifecycle. Plain `swift test` skips these (`MD2_RUN_GUI_TESTS` unset) and
/// CI's `gui-tests` job runs them; run locally with
/// `MD2_RUN_GUI_TESTS=1 swift test --filter UndoHistoryGUITests`.
///
/// Each test hosts the real `ContentView` in a window whose delegate answers
/// with the document's undo manager, as `MD2AppDelegate` does, and drives it the
/// way the app does: typing through the editor's text view, mode switches
/// through the store, Edit ▸ Undo as an `undo:` action sent down the responder
/// chain to the window. The guarded failures need the full SwiftUI lifecycle to
/// appear: Undo after Write → Read → Write messaged a text view freed by the
/// switch (a crash), and Undo after a reload from disk replayed ranges of the
/// replaced text (an exception, or a silent rewrite that autosave persisted).
///
/// The round-trip tests assert that the remounted editor *is* the text view the
/// typing went into — the property the fix rests on — instead of waiting for a
/// replaced view to be freed: under XCTest, SwiftUI keeps a dismantled editor's
/// host alive, so the old crash does not reproduce here even without the fix,
/// while a rebuilt text view always fails the identity check.
final class UndoHistoryGUITests: XCTestCase {
    // MARK: - Mode switches keep the history

    @MainActor
    func testUndoAfterReadModeRoundTripRestoresTypedText() throws {
        try skipUnlessGUITestsEnabled()
        try assertUndoSurvivesRoundTrip(through: .read)
    }

    @MainActor
    func testUndoAfterSideBySideRoundTripRestoresTypedText() throws {
        try skipUnlessGUITestsEnabled()
        try assertUndoSurvivesRoundTrip(through: .split)
    }

    @MainActor
    func testUndoInReadModeEditsTheDocument() throws {
        try skipUnlessGUITestsEnabled()
        let harness = try DocumentWindowHarness()
        defer { harness.close() }
        let editor = try XCTUnwrap(harness.waitForEditor(), "the editor never mounted")
        let original = harness.store.text

        harness.type(" typed")
        try harness.switchMode(to: .read)
        XCTAssertNil(harness.mountedEditor, "Read mode shows no editor")

        // The history belongs to the document, not to the editor on screen.
        XCTAssertEqual(harness.window.undoManager?.canUndo, true, "Edit ▸ Undo must stay available in Read mode")
        XCTAssertTrue(harness.performUndo(), "nothing in the responder chain handled Undo")
        XCTAssertEqual(harness.store.text, original)
        XCTAssertTrue(harness.performRedo())
        XCTAssertEqual(harness.store.text, original + " typed")
        XCTAssertTrue(harness.performUndo())

        // Back in the editor, the text and the remaining history agree.
        try harness.switchMode(to: .write)
        XCTAssertTrue(harness.mountedEditor === editor)
        XCTAssertEqual(editor.string, original)
        XCTAssertTrue(harness.performRedo())
        XCTAssertEqual(harness.store.text, original + " typed")
        XCTAssertEqual(editor.string, original + " typed")
    }

    // MARK: - Reloads from disk invalidate the history

    @MainActor
    func testUndoAfterExternalReloadOfShorterFileDoesNotRaise() throws {
        try skipUnlessGUITestsEnabled()
        // Typing at the end of a long file, then a much shorter external
        // version: the typing action's range lies far past the new end.
        try assertReloadClearsHistory(external: "Short.\n")
    }

    @MainActor
    func testUndoAfterExternalReloadOfLongerFileNeverRewritesIt() throws {
        try skipUnlessGUITestsEnabled()
        // A longer external version: a stale action would land inside the
        // teammate's text and silently delete part of it, mark the document
        // dirty, and let autosave write the damage.
        let external = "Teammate line one.\nTeammate line two.\n" + Self.longDocument + "Teammate tail.\n"
        try assertReloadClearsHistory(external: external)
    }

    @MainActor
    func testTypingAfterAReloadUndoesBackToTheReloadedText() throws {
        try skipUnlessGUITestsEnabled()
        let url = try Self.makeTemporaryDocument(Self.longDocument)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = DocumentStore()
        store.open(url)
        let harness = try DocumentWindowHarness(store: store)
        defer { harness.close() }
        XCTAssertNotNil(harness.waitForEditor(), "the editor never mounted")

        harness.type("\nBefore the reload.")
        XCTAssertTrue(store.save())
        let external = "# Rewritten elsewhere\n"
        try external.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(harness.spin(until: { store.text == external }, timeout: 10), "the clean document never reloaded")

        harness.type(" — and after it.")
        XCTAssertTrue(harness.performUndo())
        XCTAssertEqual(store.text, external, "the new typing is its own step, not merged into history from before the reload")
        XCTAssertEqual(harness.window.undoManager?.canUndo, false)
    }

    // MARK: - Preview checkbox toggles are undoable

    @MainActor
    func testPreviewTaskToggleIsAnUndoStepInSideBySide() throws {
        try skipUnlessGUITestsEnabled()
        let store = DocumentStore()
        store.text = "# Tasks\n\n- [ ] Draft\n- [ ] Review"
        let harness = try DocumentWindowHarness(store: store)
        defer { harness.close() }
        XCTAssertNotNil(harness.waitForEditor(), "the editor never mounted")
        try harness.switchMode(to: .split)

        harness.type("\n- [ ] Ship")
        XCTAssertTrue(store.toggleTask(atLine: 3, to: true))
        harness.spin(for: 0.1)
        XCTAssertEqual(store.text, "# Tasks\n\n- [x] Draft\n- [ ] Review\n- [ ] Ship")
        XCTAssertEqual(harness.mountedEditor?.string, store.text, "the toggle must reach the editor")

        XCTAssertTrue(harness.performUndo())
        XCTAssertEqual(store.text, "# Tasks\n\n- [ ] Draft\n- [ ] Review\n- [ ] Ship", "Undo reverts the toggle first")
        XCTAssertTrue(harness.performUndo())
        XCTAssertEqual(store.text, "# Tasks\n\n- [ ] Draft\n- [ ] Review", "then the typing before it")
        XCTAssertEqual(harness.mountedEditor?.string, store.text)
    }

    @MainActor
    func testPreviewTaskToggleIsUndoableBeforeTheEditorWasEverShown() throws {
        try skipUnlessGUITestsEnabled()
        let store = DocumentStore()
        let original = "# Tasks\n\n- [ ] Draft"
        store.text = original
        let harness = try DocumentWindowHarness(store: store, mode: .read)
        defer { harness.close() }
        XCTAssertTrue(harness.spin(until: { harness.showsPreview }), "the preview never mounted")
        XCTAssertNil(store.editorSession.textView, "Read mode alone builds no editor")

        XCTAssertTrue(store.toggleTask(atLine: 3, to: true))
        harness.spin(for: 0.1)
        XCTAssertEqual(store.text, "# Tasks\n\n- [x] Draft")
        XCTAssertTrue(harness.performUndo())
        XCTAssertEqual(store.text, original)

        try harness.switchMode(to: .write)
        XCTAssertEqual(harness.mountedEditor?.string, original)
        XCTAssertTrue(harness.performRedo())
        XCTAssertEqual(store.text, "# Tasks\n\n- [x] Draft")
    }

    // MARK: - App wiring

    @MainActor
    func testAppDelegateGivesEachDocumentWindowItsDocumentsUndoManager() throws {
        try skipUnlessGUITestsEnabled()
        _ = NSApplication.shared
        let appDelegate = MD2AppDelegate()
        let first = appDelegate.newDocument()
        let second = appDelegate.newDocument()
        defer {
            // Let the opening animations finish before closing: tearing a window
            // down mid-animation crashes the next window-hosted suite (TODOS.md).
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            for window in [first, second] {
                window.animationBehavior = .none
                window.close()
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        let firstStore = try XCTUnwrap(appDelegate.documentStore(for: first))
        let secondStore = try XCTUnwrap(appDelegate.documentStore(for: second))

        XCTAssertTrue(first.undoManager === firstStore.undoManager)
        XCTAssertTrue(second.undoManager === secondStore.undoManager)
        XCTAssertFalse(first.undoManager === second.undoManager, "documents must not share a history")
    }

    // MARK: - Scenarios

    @MainActor
    private func assertUndoSurvivesRoundTrip(
        through intermediate: EditorMode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let harness = try DocumentWindowHarness()
        defer { harness.close() }
        let editor = try XCTUnwrap(harness.waitForEditor(), "the editor never mounted", file: file, line: line)
        let original = harness.store.text

        harness.type(" typed")
        XCTAssertEqual(harness.store.text, original + " typed", file: file, line: line)

        try harness.switchMode(to: intermediate)
        try harness.switchMode(to: .write)

        let remounted = try XCTUnwrap(harness.mountedEditor, "the editor never remounted", file: file, line: line)
        XCTAssertTrue(
            remounted === editor,
            "the mode round trip must re-host the document's text view, whose undo actions target it",
            file: file, line: line
        )
        XCTAssertEqual(
            remounted.frame.width,
            remounted.enclosingScrollView?.contentSize.width ?? -1,
            accuracy: 1,
            "a re-hosted text view must span its new scroll view",
            file: file, line: line
        )
        XCTAssertTrue(harness.window.undoManager === harness.store.undoManager, file: file, line: line)
        XCTAssertTrue(remounted.undoManager === harness.store.undoManager, file: file, line: line)

        XCTAssertTrue(harness.performUndo(), "nothing in the responder chain handled Undo", file: file, line: line)
        XCTAssertEqual(harness.store.text, original, file: file, line: line)
        XCTAssertEqual(remounted.string, original, file: file, line: line)
        XCTAssertTrue(harness.performRedo(), file: file, line: line)
        XCTAssertEqual(harness.store.text, original + " typed", file: file, line: line)
    }

    @MainActor
    private func assertReloadClearsHistory(
        external: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let url = try Self.makeTemporaryDocument(Self.longDocument)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = DocumentStore()
        store.open(url)
        let harness = try DocumentWindowHarness(store: store)
        defer { harness.close() }
        XCTAssertNotNil(harness.waitForEditor(), "the editor never mounted", file: file, line: line)

        harness.type("\nTyped before saving.")
        XCTAssertTrue(store.save(), file: file, line: line)
        XCTAssertFalse(store.isDirty, file: file, line: line)
        XCTAssertEqual(harness.window.undoManager?.canUndo, true, file: file, line: line)

        try external.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(
            harness.spin(until: { store.text == external }, timeout: 10),
            "the clean document never reloaded the external change",
            file: file, line: line
        )
        XCTAssertFalse(store.isDirty, "text equal to the disk is not dirty", file: file, line: line)
        XCTAssertEqual(harness.mountedEditor?.string, external, "the editor shows the reloaded text", file: file, line: line)
        XCTAssertEqual(
            harness.window.undoManager?.canUndo,
            false,
            "a reload is a revert: no action recorded against the old text may survive it",
            file: file, line: line
        )

        // Edit ▸ Undo is disabled now; send it anyway, as a stale menu would.
        _ = harness.performUndo()
        XCTAssertEqual(store.text, external, file: file, line: line)
        XCTAssertFalse(store.isDirty, file: file, line: line)
        harness.spin(for: 0.3)
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8),
            external,
            "nothing may write over the external change",
            file: file, line: line
        )
    }

    // MARK: - Fixtures

    /// About 1.8 KB, so typing at its end sits far past the end of a short
    /// external version.
    private static let longDocument = (1...40)
        .map { "Line \($0) of a document long enough to matter.\n" }
        .joined()

    private static func makeTemporaryDocument(_ content: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("md2-undo-gui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("doc.md")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func skipUnlessGUITestsEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this undo-history GUI test."
        )
    }
}

/// A document window as the app builds one: `ContentView` in an
/// `NSHostingView`, settings from a private defaults suite, and a window
/// delegate that answers with the document's undo manager.
@MainActor
private final class DocumentWindowHarness: NSObject, NSWindowDelegate {
    let store: DocumentStore
    let settings: AppSettings
    let window: NSWindow
    private let defaultsSuiteName: String

    init(store: DocumentStore = DocumentStore(), mode: EditorMode = .write) throws {
        _ = NSApplication.shared
        defaultsSuiteName = "UndoHistoryGUITests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            throw XCTSkip("could not create a private defaults suite")
        }
        settings = AppSettings(defaults: defaults)
        settings.defaultMode = mode
        settings.newDocumentMode = mode
        settings.showsOutlineByDefault = false
        self.store = store
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.isReleasedWhenClosed = false
        // Ordering animations torn down mid-flight crash the next window-hosted
        // suite (see TODOS.md); these windows never animate.
        window.animationBehavior = .none
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: ContentView(document: store, settings: settings, onOpen: {})
        )
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        store.undoManager
    }

    func close() {
        autoreleasepool {
            window.orderOut(nil)
            window.contentView = nil
            window.delegate = nil
        }
        spin(for: 0.2)
        UserDefaults(suiteName: defaultsSuiteName)?.removePersistentDomain(forName: defaultsSuiteName)
    }

    // MARK: Surfaces

    var mountedEditor: MarkdownSourceTextView? {
        window.contentView.flatMap { Self.firstDescendant(of: $0, as: MarkdownSourceTextView.self) }
    }

    var showsPreview: Bool {
        window.contentView.flatMap { Self.firstDescendant(of: $0, as: WKWebView.self) } != nil
    }

    func waitForEditor() -> MarkdownSourceTextView? {
        spin(until: { self.mountedEditor?.window != nil })
        // Let the mount's deferred first-responder and styling passes land.
        spin(for: 0.3)
        return mountedEditor
    }

    /// Switches through the store, as the Mode menu does, and waits until the
    /// surfaces of `mode` (and only those) are mounted.
    func switchMode(to mode: EditorMode) throws {
        autoreleasepool {
            store.requestMode(mode)
        }
        let settled = spin(until: {
            let editor = self.mountedEditor?.window != nil
            let preview = self.showsPreview
            switch mode {
            case .write: return editor && !preview
            case .split: return editor && preview
            case .read: return !editor && preview
            }
        })
        guard settled else { throw HarnessFailure("the window never settled in \(mode) mode") }
        spin(for: 0.3)
    }

    // MARK: Editing

    /// Types at the end of the mounted editor's text, then lets the run loop
    /// turn so the typing closes its own undo group, as a keystroke would.
    func type(_ string: String) {
        guard let editor = mountedEditor else {
            XCTFail("no editor to type into")
            return
        }
        autoreleasepool {
            let end = (editor.string as NSString).length
            editor.insertText(string, replacementRange: NSRange(location: end, length: 0))
        }
        spin(for: 0.1)
    }

    /// Edit ▸ Undo: the menu sends `undo:` down the responder chain from the
    /// first responder, and the window answers it with `window.undoManager`.
    @discardableResult
    func performUndo() -> Bool {
        send(Selector(("undo:")))
    }

    @discardableResult
    func performRedo() -> Bool {
        send(Selector(("redo:")))
    }

    private func send(_ action: Selector) -> Bool {
        var handled = false
        autoreleasepool {
            handled = (window.firstResponder ?? window).tryToPerform(action, with: nil)
        }
        spin(for: 0.1)
        return handled
    }

    // MARK: Run loop

    @discardableResult
    func spin(until condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            autoreleasepool {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        }
        return true
    }

    func spin(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            autoreleasepool {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        }
    }

    private static func firstDescendant<View: NSView>(of root: NSView, as type: View.Type) -> View? {
        if let match = root as? View { return match }
        for subview in root.subviews {
            if let match = firstDescendant(of: subview, as: type) { return match }
        }
        return nil
    }
}

private struct HarnessFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
