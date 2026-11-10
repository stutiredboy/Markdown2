import AppKit
import Testing
@testable import MD2App
@testable import MD2Core

// Regression for separate commands sharing Foundation's automatic event group.
// No AX, shared pasteboard or sleeps. The focus case uses an unshown window.
@Suite(.serialized)
@MainActor
struct StructuredEditUndoTests {
    private let table = "| A | B |\r\n| --- | --- |\r\n| 中🙂 | é |"

    private func editor(_ source: String) throws -> (MarkdownEditorSession, MarkdownSourceTextView) {
        let session = MarkdownEditorSession()
        let view = try #require(session.loadTextView(text: source) as? MarkdownSourceTextView)
        view.markdownPasteController.isFocusedSource = { _ in true }
        return (session, view)
    }

    private func type(_ text: String, into view: NSTextView) {
        // NSNotFound is the real ordinary-typing path, including AppKit's
        // coalescing. Do not supply an explicit replacement range or group.
        for character in text {
            view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    @Test(arguments: [false, true])
    func typingAroundTableMutationKeepsThreeUndoStepsAndSelections(_ eventExit: Bool) throws {
        let original = table + "\r\n\r\nbody "
        let (session, view) = try editor(original)
        let manager = session.undoManager
        view.setSelectedRange(NSRange(location: original.utf16.count, length: 0))
        type("ab", into: view)
        let beforeCommand = view.string
        let originalSelection = (view.string as NSString).range(of: "中🙂")
        view.setSelectedRange(originalSelection)
        #expect(view.performMarkdownAction(.tableEdit(.insertColumnAfter)))
        let afterCommand = view.string
        if eventExit { CFRunLoopRunInMode(.defaultMode, 0, false) }
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        type("cd", into: view)
        let afterTyping = view.string
        manager.undo()
        #expect(view.string == afterCommand, "ordinary typing after the command stays coalesced")
        let selectionAfterUndoTyping = view.selectedRange()
        manager.undo()
        #expect(view.string == beforeCommand)
        #expect(view.selectedRange() == originalSelection)
        manager.undo()
        #expect(view.string == original, "ordinary typing before the command stays coalesced")
        #expect(!manager.canUndo)
        manager.redo()
        #expect(view.string == beforeCommand)
        manager.redo()
        #expect(view.string == afterCommand)
        #expect(view.selectedRange() == selectionAfterUndoTyping)
        manager.redo()
        #expect(view.string == afterTyping)
        #expect(!manager.canRedo)
        #expect(manager.groupsByEvent)
        CFRunLoopRunInMode(.defaultMode, 0, false)
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        type("ef", into: view)
        manager.undo()
        #expect(view.string == afterTyping)
    }

    @MainActor private final class Sentinels {
        var editor: NSTextView?
        var window: NSWindow?
        var field: NSTextField?
        var observedSource: String?
        var defaultCallback = 0
        var mainQueueCallback = 0
        var commonModeCallback = 0
    }

    @Test func commandBoundaryDoesNotDrainOtherDocumentsOrUIWork() throws {
        let (session, view) = try editor(table + "\n\nbody ")
        let (otherSession, otherView) = try editor("other ")
        let manager = session.undoManager, otherManager = otherSession.undoManager
        defer { manager.removeAllActions(); otherManager.removeAllActions() }
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        type("ab", into: view)
        otherView.setSelectedRange(NSRange(location: otherView.string.utf16.count, length: 0))
        type("cd", into: otherView)
        #expect(manager.groupingLevel == 1 && otherManager.groupingLevel == 1)
        let modes = manager.runLoopModes, otherModes = otherManager.runLoopModes
        #expect(modes.contains(.default))
        #expect(!modes.contains(.common))
        #expect(Set(modes).subtracting([.default]).isDisjoint(with: Set(otherModes)))
        let sentinels = Sentinels()
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated { sentinels.defaultCallback += 1 }
        }
        DispatchQueue.main.async { sentinels.mainQueueCallback += 1 }
        let observer = try #require(CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.exit.rawValue, false, 0) { _, _ in
            MainActor.assumeIsolated { sentinels.commonModeCallback += 1 }
        })
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        view.setSelectedRange((view.string as NSString).range(of: "中🙂"))
        #expect(view.performMarkdownAction(.tableEdit(.insertColumnAfter)))
        #expect(sentinels.defaultCallback == 0)
        #expect(sentinels.mainQueueCallback == 0)
        #expect(sentinels.commonModeCallback == 0)
        #expect(otherManager.groupingLevel == 1)
        #expect(otherView.string == "other cd")
        #expect(manager.runLoopModes == modes && otherManager.runLoopModes == otherModes)
        CFRunLoopRunInMode(.defaultMode, 0, false)
        #expect(sentinels.defaultCallback == 1)
        #expect(sentinels.commonModeCallback == 1)
    }

    @Test(arguments: [false, true])
    func checkpointChangesAreNotOverwritten(_ afterMutation: Bool) throws {
        let (session, view) = try editor(table + "\n\nbody ")
        let manager = session.undoManager
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        type("ab", into: view)
        let original = view.string
        let sentinel = Sentinels()
        sentinel.editor = view
        let observer = NotificationCenter.default.addObserver(forName: .NSUndoManagerWillCloseUndoGroup,
            object: manager, queue: nil) { _ in
                MainActor.assumeIsolated {
                    guard let editor = sentinel.editor, sentinel.defaultCallback == 0,
                          !afterMutation || editor.string != original else { return }
                    sentinel.defaultCallback += 1
                    editor.string = editor.string.replacingOccurrences(of: "body", with: "BODY")
                    editor.setSelectedRange(NSRange(location: 0, length: 0))
                }
            }
        defer { NotificationCenter.default.removeObserver(observer); manager.removeAllActions() }
        view.setSelectedRange((view.string as NSString).range(of: "中🙂"))
        #expect(view.performMarkdownAction(.tableEdit(.insertColumnAfter)))
        #expect(sentinel.defaultCallback == 1)
        #expect(view.selectedRange() == NSRange(location: 0, length: 0))
        #expect(view.string.contains("BODY ab"))
        #expect(view.string.contains("| A |  | B |") == afterMutation)
        #expect(manager.undoCount == 1, "only prior typing remains; the observer invalidates this command's inverse")
        #expect(manager.groupsByEvent)
    }

    @Test(arguments: ["source", "selection", "short-source"])
    func openingObserversKeepNewerStateWithoutInvalidHistory(_ change: String) async throws {
        let (session, view) = try editor("TARGET!")
        let manager = session.undoManager
        if change != "short-source" {
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
            type("q", into: view)
        }
        let suffix = change == "short-source" ? "!" : "!q"
        let trace = Sentinels()
        trace.editor = view
        let observer = NotificationCenter.default.addObserver(forName: .NSUndoManagerDidOpenUndoGroup,
            object: manager, queue: nil) { _ in MainActor.assumeIsolated {
                guard let editor = trace.editor, trace.defaultCallback == 0 else { return }
                trace.defaultCallback += 1
                trace.observedSource = editor.string
                if change == "source" { editor.string = "ZARGET" + suffix }
                if change == "short-source" { editor.string = "Z" }
                editor.setSelectedRange(NSRange(location: change == "selection" ? 0 : editor.string.utf16.count, length: 0))
            } }
        defer { NotificationCenter.default.removeObserver(observer); manager.removeAllActions() }
        view.setSelectedRange(NSRange(location: 0, length: 6))
        view.markdownPasteController.capture = { _ in .success(.init(plainText: "NATIVE")) }
        #expect(view.markdownPasteController.perform(.plainText))
        await view.markdownPasteController.waitForPendingPaste()
        #expect(trace.defaultCallback == 1)
        #expect(trace.observedSource == "NATIVE" + suffix, "the real native write precedes inverse registration")
        if change == "short-source" {
            #expect(view.string == "Z" && view.selectedRange() == NSRange(location: 1, length: 0))
            #expect(!manager.canUndo && !manager.canRedo, "no out-of-bounds inverse or phantom step")
        } else if change == "source" {
            #expect(view.string == "ZARGET!q" && view.selectedRange() == NSRange(location: 8, length: 0))
            #expect(manager.undoCount == 1, "discard only the invalidated paste inverse")
            manager.undo()
            #expect(view.string == "ZARGET!" && !manager.canUndo)
            manager.redo()
            #expect(view.string == "ZARGET!q" && !manager.canRedo)
        } else {
            #expect(view.string == "NATIVE!q" && view.selectedRange() == NSRange(location: 0, length: 0))
            manager.undo()
            #expect(view.string == "TARGET!q" && view.selectedRange() == NSRange(location: 0, length: 6))
            manager.undo()
            #expect(view.string == "TARGET!" && !manager.canUndo)
            manager.redo()
            manager.redo()
            #expect(view.string == "NATIVE!q" && view.selectedRange() == NSRange(location: 0, length: 0))
            #expect(!manager.canRedo)
        }
    }

    @Test func stalePasteBeforeWritingPreservesUndoAndRedo() async throws {
        let (session, view) = try editor("TARGET!")
        let manager = session.undoManager
        #expect(view.insertStructuredText("1", range: NSRange(location: 7, length: 0)))
        #expect(view.insertStructuredText("2", range: NSRange(location: 8, length: 0)))
        manager.undo()
        #expect(view.string == "TARGET!1" && manager.undoCount == 1 && manager.redoCount == 1)
        let trace = Sentinels()
        trace.editor = view
        view.setSelectedRange(NSRange(location: 0, length: 6))
        view.markdownPasteController.capture = { _ in .success(.init(plainText: "NATIVE")) }
        view.markdownPasteController.convert = { kind, payload in
            await MainActor.run {
                trace.editor?.setSelectedRange(NSRange(location: 8, length: 0))
                return MarkdownPaste.convert(kind, payload: payload)
            }
        }
        #expect(view.markdownPasteController.perform(.plainText))
        await view.markdownPasteController.waitForPendingPaste()
        #expect(view.string == "TARGET!1" && manager.undoCount == 1 && manager.redoCount == 1)
        manager.redo()
        #expect(view.string == "TARGET!12")
        manager.undo()
        manager.undo()
        #expect(view.string == "TARGET!" && !manager.canUndo)
    }

    @Test func focusChangeCancelsTableCommandWhileHistoryWorksFromOtherFields() throws {
        _ = NSApplication.shared
        let original = table + "\n\nbody "
        let (session, view) = try editor(original)
        let manager = session.undoManager
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        window.contentView = container
        view.frame = NSRect(x: 0, y: 40, width: 400, height: 200)
        container.addSubview(view)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        container.addSubview(field)
        defer { manager.removeAllActions(); window.close() }
        #expect(window.makeFirstResponder(view))
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        type("q", into: view)
        let before = view.string
        view.setSelectedRange((before as NSString).range(of: "中🙂"))
        let trace = Sentinels()
        trace.window = window
        trace.field = field
        let observer = NotificationCenter.default.addObserver(forName: .NSUndoManagerWillCloseUndoGroup,
            object: manager, queue: nil) { _ in MainActor.assumeIsolated {
                guard trace.defaultCallback == 0 else { return }
                trace.defaultCallback += 1
                _ = trace.window?.makeFirstResponder(trace.field)
            } }
        #expect(view.performMarkdownAction(.tableEdit(.insertColumnAfter)))
        NotificationCenter.default.removeObserver(observer)
        #expect(trace.defaultCallback == 1 && window.firstResponder !== view)
        #expect(view.string == before && manager.undoCount == 1)
        manager.undo()
        #expect(view.string == original)
        view.setSelectedRange((table as NSString).range(of: "中🙂"))
        #expect(view.performMarkdownAction(.tableEdit(.insertColumnAfter)))
        #expect(view.string != original)
        manager.undo()
        #expect(view.string == original, "history need not start with source focus")
    }

    @MainActor private final class EarlierCommand {
        var value = 0
        func set(_ value: Int, manager: UndoManager) {
            let old = self.value
            manager.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated { target.set(old, manager: manager) }
            }
            self.value = value
        }
    }

    @Test func documentManagerIsConfiguredBeforeItsLazySessionExists() throws {
        let store = DocumentStore()
        let manager = store.undoManager
        let earlier = EarlierCommand()
        earlier.set(1, manager: manager)
        #expect(manager.groupingLevel == 1)
        let session = store.editorSession
        let view = try #require(session.loadTextView(text: table) as? MarkdownSourceTextView)
        defer { manager.removeAllActions() }
        view.setSelectedRange((table as NSString).range(of: "中🙂"))
        #expect(view.performMarkdownAction(.tableEdit(.insertColumnAfter)))
        #expect(store.isDirty)
        #expect(store.text == view.string)
        manager.undo()
        #expect(view.string == table)
        #expect(earlier.value == 1)
        manager.undo()
        #expect(earlier.value == 0)
        #expect(!manager.canUndo)
        manager.redo()
        manager.redo()
        #expect(store.text == view.string && view.string != table)
    }

    @Test func injectedOpenGroupRetainsTheCallersHistory() throws {
        let manager = UndoManager(), earlier = EarlierCommand()
        earlier.set(1, manager: manager)
        let session = MarkdownEditorSession(undoManager: manager)
        let view = try #require(session.loadTextView(text: table) as? MarkdownSourceTextView)
        defer { manager.removeAllActions() }
        view.setSelectedRange((table as NSString).range(of: "中🙂"))
        #expect(view.performMarkdownAction(.tableEdit(.insertColumnAfter)))
        #expect(manager.groupingLevel == 1, "the preexisting group remains caller-owned")
        manager.undo()
        #expect(view.string == table)
        #expect(earlier.value == 0)
        #expect(!manager.canUndo)
        // Once the caller has closed its old event, new commands are isolated.
        #expect(view.performMarkdownAction(.tableEdit(.insertColumnAfter)))
        manager.undo()
        #expect(view.string == table)
        #expect(!manager.canUndo)
    }

    @Test(arguments: [true, false])
    func callerOwnedGroupCombinesNativeInsertionAndTableCommands(_ automatic: Bool) throws {
        let (session, view) = try editor("TARGET")
        let manager = session.undoManager
        manager.groupsByEvent = automatic
        manager.beginUndoGrouping()
        let callerLevel = manager.groupingLevel
        #expect(callerLevel == (automatic ? 2 : 1))
        view.setSelectedRange(NSRange(location: 0, length: 6))
        // A caller's explicit group is synchronous: keeping one open over an
        // async conversion would let Foundation's run-loop callback close it.
        // Exercise the same native insertion and shared boundary as adoption.
        view.withStructuredEditUndo { view.insertText(table, replacementRange: view.selectedRange()) }
        #expect(manager.groupingLevel == callerLevel)
        view.setSelectedRange((view.string as NSString).range(of: "中🙂"))
        #expect(view.performMarkdownAction(.tableEdit(.insertColumnAfter)))
        let changed = view.string, selection = view.selectedRange()
        #expect(manager.groupingLevel == callerLevel)
        manager.endUndoGrouping()
        manager.undo()
        #expect(view.string == "TARGET")
        #expect(!manager.canUndo)
        manager.redo()
        #expect(view.string == changed)
        #expect(view.selectedRange() == selection)
        #expect(!manager.canRedo)
        #expect(manager.groupsByEvent == automatic)
    }

    @Test(arguments: [true, false])
    func disabledRegistrationStaysDisabledAndCreatesNoUndo(_ automatic: Bool) async throws {
        let (session, view) = try editor("TARGET")
        let manager = session.undoManager
        manager.groupsByEvent = automatic
        manager.disableUndoRegistration()
        view.setSelectedRange(NSRange(location: 0, length: 6))
        view.markdownPasteController.capture = { _ in .success(.init(plainText: "A\tB\nx\ty")) }
        #expect(view.markdownPasteController.perform(.table))
        await view.markdownPasteController.waitForPendingPaste()
        view.setSelectedRange((view.string as NSString).range(of: "x"))
        #expect(view.performMarkdownAction(.tableEdit(.insertColumnAfter)))
        #expect(!manager.isUndoRegistrationEnabled)
        #expect(manager.groupingLevel == 0)
        #expect(!manager.canUndo)
        manager.enableUndoRegistration()
        #expect(manager.isUndoRegistrationEnabled)
        #expect(manager.groupsByEvent == automatic)
    }

    @Test func navigationAndRefusalLeaveTypingHistoryAlone() async throws {
        let (session, view) = try editor(table + "\r\n\r\nbody ")
        let manager = session.undoManager, original = view.string
        view.setSelectedRange(NSRange(location: original.utf16.count, length: 0))
        type("ab", into: view)
        let typed = view.string
        view.setSelectedRange(NSRange(location: 2, length: 1))
        #expect(view.performMarkdownAction(.indent)) // Cell navigation, no mutation.
        #expect(!view.performMarkdownAction(.tableEdit(.deleteRow))) // Header refusal.
        view.markdownPasteController.capture = { _ in .success(.init(plainText: "")) }
        #expect(view.markdownPasteController.perform(.plainText))
        await view.markdownPasteController.waitForPendingPaste()
        #expect(view.string == typed)
        manager.undo()
        #expect(view.string == original)
        #expect(!manager.canUndo)
    }

    @MainActor private final class RejectingDelegate: NSObject, NSTextViewDelegate {
        let manager = UndoManager()
        func undoManager(for view: NSTextView) -> UndoManager? { manager }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool { false }
    }

    @Test func delegateRejectionPreservesSourceSelectionAndHistory() {
        let delegate = RejectingDelegate()
        let view = MarkdownSourceTextView(frame: .zero)
        view.delegate = delegate
        view.allowsUndo = true
        view.string = table
        let selection = (table as NSString).range(of: "中🙂")
        view.setSelectedRange(selection)
        // Table preflight and the native insertion used by explicit paste.
        #expect(view.performMarkdownAction(.tableEdit(.insertColumnAfter)))
        #expect(!view.insertStructuredText("denied", range: selection))
        #expect(view.string == table)
        #expect(view.selectedRange() == selection)
        #expect(!delegate.manager.canUndo)
        #expect(delegate.manager.groupingLevel == 0)
        #expect(delegate.manager.isUndoRegistrationEnabled)
    }
    @MainActor private final class Trace {
        var undoNotifications = 0
        var redoNotifications = 0
    }
    @Test(arguments: ["automatic-shared-event", "boundary-after-T1", "boundary-after-each"])
    func explicitPasteAndTableCommandsOwnIndependentUndoSteps(_ boundary: String) async throws {
        let original = "BEFORE\r\nTARGET\r\nAFTER 中文😀"
        let pasted = "BEFORE\r\n\r\n| A | B |\r\n| --- | --- |\r\n| x | y |\r\n\r\nAFTER 中文😀"
        let widened = "BEFORE\r\n\r\n| A |  | B |\r\n| --- | --- | --- |\r\n| x |  | y |\r\n\r\nAFTER 中文😀"
        let manager = UndoManager() // Keep production default groupsByEvent=true.
        #expect(manager.groupsByEvent)
        let session = MarkdownEditorSession(undoManager: manager)
        let view = try #require(session.loadTextView(text: original) as? MarkdownSourceTextView)
        view.markdownPasteController.isFocusedSource = { _ in true }
        view.markdownPasteController.capture = { _ in .success(.init(plainText: "A\tB\nx\ty")) }
        let trace = Trace()
        let observer = NotificationCenter.default.addObserver(forName: .NSUndoManagerDidUndoChange,
            object: manager, queue: nil) { _ in MainActor.assumeIsolated { trace.undoNotifications += 1 } }
        let redoObserver = NotificationCenter.default.addObserver(forName: .NSUndoManagerDidRedoChange,
            object: manager, queue: nil) { _ in MainActor.assumeIsolated { trace.redoNotifications += 1 } }
        defer {
            NotificationCenter.default.removeObserver(observer)
            NotificationCenter.default.removeObserver(redoObserver)
            manager.removeAllActions()
        }
        func endAutomaticEventGroup() throws {
            // Deliberately model only a run-loop boundary, never an edit or an
            // explicit outer transaction. The group must already be implicit.
            try #require(manager.groupsByEvent && manager.groupingLevel <= 1)
            if manager.groupingLevel == 1 { manager.endUndoGrouping() }
            #expect(manager.groupingLevel == 0)
        }
        view.setSelectedRange((original as NSString).range(of: "TARGET"))
        #expect(view.markdownPasteController.perform(.table))
        await view.markdownPasteController.waitForPendingPaste()
        try #require(Array(view.string.utf16) == Array(pasted.utf16))
        if boundary == "boundary-after-each" { try endAutomaticEventGroup() }
        view.setSelectedRange((view.string as NSString).range(of: "x"))
        #expect(view.performMarkdownAction(.tableEdit(.insertColumnAfter)))
        try #require(Array(view.string.utf16) == Array(widened.utf16))
        if boundary != "automatic-shared-event" { try endAutomaticEventGroup() }
        #expect(view.performMarkdownAction(.tableEdit(.deleteColumn)))
        try #require(Array(view.string.utf16) == Array(pasted.utf16))
        if boundary == "boundary-after-each" { try endAutomaticEventGroup() }
        var undoCalls = 0
        for (label, expected) in [("undoT2", widened), ("undoT1", pasted), ("undoP", original)] {
            undoCalls += 1
            manager.undo() // Exactly one direct call: no AX or command dispatch.
            #expect(trace.undoNotifications == undoCalls)
            #expect(Array(view.string.utf16) == Array(expected.utf16), Comment(rawValue: boundary + ": " + label))
            if view.string != expected { break }
        }
        #expect(!manager.canUndo)
        for (index, expected) in [pasted, widened, pasted].enumerated() {
            manager.redo()
            #expect(trace.redoNotifications == index + 1)
            #expect(Array(view.string.utf16) == Array(expected.utf16))
        }
        #expect(!manager.canRedo)
        #expect(manager.groupsByEvent)
        withExtendedLifetime(session) {}
    }
}
