// Real native AppKit events exercise command acceptance and finalization.
// These new asynchronous-contract tests preserve the existing synchronous tests.
import AppKit
import SwiftUI
import XCTest
@testable import MD2App
@testable import MD2Core

final class AsyncStructuredNativeGUITests: XCTestCase {
    @MainActor private static var originalActivationPolicy: NSApplication.ActivationPolicy?

    override class func setUp() {
        super.setUp()
        guard ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1" else { return }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            originalActivationPolicy = app.activationPolicy()
            _ = app.setActivationPolicy(.regular)
            app.finishLaunching()
        }
    }

    override class func tearDown() {
        MainActor.assumeIsolated {
            if let originalActivationPolicy { _ = NSApp.setActivationPolicy(originalActivationPolicy) }
            originalActivationPolicy = nil
        }
        super.tearDown()
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Requires an exclusive, unlocked native GUI lease")
    }

    @MainActor func testTwoAcceptedTableIntentsFinishInOrderWithExactTwoStepHistory() throws {
        let h = try AsyncNativeHost(AsyncFixture.original)
        defer { h.close() }
        h.view.setSelectedRange(AsyncFixture.originalSelection)
        try AsyncNativeEvents.run([
            .async { next in
                h.requireNativePremise()
                XCTAssertTrue(h.view.performMarkdownAction(.tableEdit(.insertColumnAfter)))
                XCTAssertTrue(h.view.performMarkdownAction(.tableEdit(.deleteColumn)))
                // These are accepted intents, not synchronous mutations. No
                // yield or UI dispatch occurs between either action/assertion.
                h.assert(AsyncFixture.original, selection: AsyncFixture.originalSelection)
                XCTAssertEqual(h.textChanges.count, 0)
                XCTAssertFalse(h.manager.canUndo)
                h.finishCommands(next)
            },
            .sync {
                h.assert(AsyncFixture.original, selection: AsyncFixture.rightCell)
                XCTAssertEqual(h.textChanges.map { Array($0.utf16) },
                               [AsyncFixture.widened, AsyncFixture.original].map { Array($0.utf16) })
                XCTAssertEqual(h.manager.undoCount, 2)
                XCTAssertEqual(h.manager.redoCount, 0)
                XCTAssertEqual(h.manager.groupingLevel, 0)
                h.history(undo: [(AsyncFixture.widened, AsyncFixture.emptyColumn),
                                 (AsyncFixture.original, AsyncFixture.originalSelection)],
                          redo: [(AsyncFixture.widened, AsyncFixture.emptyColumn),
                                 (AsyncFixture.original, AsyncFixture.rightCell)])
            }
        ])
    }

    @MainActor func testLastCellTabThenTabAppendsOneRowAndNavigatesProjectedRow() throws {
        let source = "| A | B |\r\n| - | - |\r\n| x | y |"
        let appended = source + "\r\n|  |  |"
        let y = (source as NSString).range(of: "y")
        let secondNewCell = NSRange(location: source.utf16.count + 2 + 5, length: 0)
        let h = try AsyncNativeHost(source)
        defer { h.close() }
        h.view.setSelectedRange(y)
        try AsyncNativeEvents.run([
            .async { next in
                XCTAssertTrue(h.view.performMarkdownAction(.indent))
                XCTAssertTrue(h.view.performMarkdownAction(.indent))
                h.assert(source, selection: y)
                h.finishCommands(next)
            },
            .sync {
                h.assert(appended, selection: secondNewCell)
                XCTAssertEqual(h.textChanges.map { Array($0.utf16) }, [Array(appended.utf16)])
                XCTAssertEqual(h.manager.undoCount, 1, "navigation must not add a second inverse")
                h.history(undo: [(source, y)], redo: [(appended, secondNewCell)])
            }
        ])
    }

    @MainActor func testStartupQueuedLastCellTabPrecedesQueuedNativeCharacter() throws {
        let source = "| A | B |\r\n| - | - |\r\n| x | y |"
        let appended = source + "\r\n|  |  |"
        let typed = source + "\r\n| x |  |"
        let y = (source as NSString).range(of: "y")
        let firstNewCell = NSRange(location: source.utf16.count + 2 + 2, length: 0)
        let typedCaret = NSRange(location: firstNewCell.location + 1, length: 0)
        let h = try AsyncNativeHost(source)
        defer { h.close() }
        h.view.setSelectedRange(y)
        // The helper posts ALL of these keyDown markers, plus its final marker,
        // once at running/active/key readiness. The x marker already exists in
        // NSApplication's queue before Tab acceptance; it is never posted by
        // Tab completion. Bodies use the production native-command handler
        // and ordinary native insertText path. No await or idle is interposed.
        try StructuredCommandEventRunner.run([
            { idle, next in
                h.requireNativePremise()
                h.batchIdleEntries = idle
                XCTAssertTrue(h.view.handleMarkdownCommand(#selector(NSResponder.insertTab(_:))))
                next()
            },
            { idle, next in
                XCTAssertEqual(idle, h.batchIdleEntries, "no idle inserted between startup-queued Tab and x")
                // Table continuation/ack must finish before the already-queued
                // next user input, so x lands in the new row, not the old y cell.
                h.assert(appended, selection: firstNewCell)
                XCTAssertEqual(h.manager.groupingLevel, 0)
                h.view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
                h.assert(typed, selection: typedCaret)
                next()
            },
            { idle, next in
                XCTAssertEqual(idle, h.batchIdleEntries)
                h.assert(typed, selection: typedCaret)
                XCTAssertEqual(h.manager.undoCount, 2)
                h.history(undo: [(appended, firstNewCell), (source, y)],
                          redo: [(appended, firstNewCell), (typed, typedCaret)])
                next()
            }
        ], alreadyQueued: true)
    }

    @MainActor func testRealPrequeuedTabAndCharacterUseHostedCoordinatorAndKeepTwoUndoSteps() throws {
        let source = "| A | B |\r\n| - | - |\r\n| x | y |"
        let appended = source + "\r\n|  |  |"
        let typed = source + "\r\n| x |  |"
        let originalSelection = (source as NSString).range(of: "y")
        let firstCell = NSRange(location: source.utf16.count + 4, length: 0)
        let caret = NSRange(location: firstCell.location + 1, length: 0)
        let h = try AsyncNativeHost(source, hostCoordinator: true)
        defer { h.close() }
        h.view.setSelectedRange(originalSelection)
        h.window.startupNativeKeys = [("\t", 48), ("x", 7)]
        h.window.beforeNativeKey = { code in
            if code == 7 {
                h.assert(appended, selection: firstCell)
                XCTAssertEqual(h.manager.groupingLevel, 0)
            }
        }
        try StructuredCommandEventRunner.run([
            { idle, next in h.requireNativePremise(); h.batchIdleEntries = idle; next() },
            { idle, next in
                XCTAssertEqual(idle, h.batchIdleEntries, "the prequeued native keys have no inserted idle")
                XCTAssertEqual(h.window.deliveredNativeKeys, [48, 7])
                h.assert(typed, selection: caret)
                XCTAssertEqual(h.boundText, typed, "the actual Coordinator receives the native text change")
                XCTAssertEqual(h.manager.undoCount, 2)
                h.history(undo: [(appended, firstCell), (source, originalSelection)],
                          redo: [(appended, firstCell), (typed, caret)])
                next()
            }
        ], alreadyQueued: true)
    }

    @MainActor func testTypingBeforeAndAfterCommandKeepsThreeExactHistorySteps() throws {
        let original = AsyncFixture.original + "\r\n\r\nbody "
        let beforeCommand = original + "ab"
        let afterCommand = AsyncFixture.widened + "\r\n\r\nbody ab"
        let afterTyping = afterCommand + "cd"
        let h = try AsyncNativeHost(original)
        defer { h.close() }
        try AsyncNativeEvents.run([
            .async { next in
                h.view.setSelectedRange(NSRange(location: original.utf16.count, length: 0))
                h.type("ab")
                h.view.setSelectedRange(AsyncFixture.originalSelection)
                XCTAssertTrue(h.view.performMarkdownAction(.tableEdit(.insertColumnAfter)))
                h.assert(beforeCommand, selection: AsyncFixture.originalSelection)
                h.finishCommands(next)
            },
            .sync {
                h.assert(afterCommand, selection: AsyncFixture.emptyColumn)
                let afterCommandCaret = NSRange(location: afterCommand.utf16.count, length: 0)
                h.view.setSelectedRange(afterCommandCaret)
                h.type("cd")
                h.assert(afterTyping, selection: NSRange(location: afterTyping.utf16.count, length: 0))
                // Native typing's undo restores the caret immediately before
                // that typing; the structured inverse restores its own cell.
                h.manager.undo(); h.assert(afterCommand, selection: afterCommandCaret)
                h.manager.undo(); h.assert(beforeCommand, selection: AsyncFixture.originalSelection)
                h.manager.undo()
                XCTAssertEqual(Array(h.view.string.utf16), Array(original.utf16))
                XCTAssertFalse(h.manager.canUndo)
                h.manager.redo()
                XCTAssertEqual(Array(h.view.string.utf16), Array(beforeCommand.utf16))
                h.manager.redo(); h.assert(afterCommand, selection: afterCommandCaret)
                h.manager.redo()
                h.assert(afterTyping, selection: NSRange(location: afterTyping.utf16.count, length: 0))
                XCTAssertFalse(h.manager.canRedo)
            }
        ])
    }

    @MainActor func testDidOpenCancellationKeepsActiveReceiptAndFreshSuccessor() throws {
        let h = try AsyncNativeHost(AsyncFixture.original)
        defer { h.close() }
        h.view.setSelectedRange(AsyncFixture.originalSelection)
        let appended = AsyncFixture.widened + "\r\n|  |  |  |"
        let appendedSelection = NSRange(location: AsyncFixture.widened.utf16.count + 2 + 2, length: 0)
        h.observe(.NSUndoManagerDidOpenUndoGroup, object: h.manager) {
            guard h.observerCalls == 0, h.view.string == AsyncFixture.widened else { return }
            h.observerCalls += 1
            // registerUndo is on the stack here. The first receipt must remain
            // alive; its old pending successor is canceled, and this fresh
            // command must not be removed by the old finalization path.
            QueueAPI.cancelPending(h.session)
            h.freshAccepted = h.view.performMarkdownAction(.tableEdit(.insertRowBelow))
        }
        try AsyncNativeEvents.run([
            .async { next in
                XCTAssertTrue(h.view.performMarkdownAction(.tableEdit(.insertColumnAfter)))
                XCTAssertTrue(h.view.performMarkdownAction(.tableEdit(.deleteColumn)))
                h.finishCommands(next)
            },
            .sync {
                XCTAssertEqual(h.observerCalls, 1)
                XCTAssertTrue(h.freshAccepted)
                h.assert(appended, selection: appendedSelection)
                XCTAssertEqual(h.manager.undoCount, 2)
                h.history(undo: [(AsyncFixture.widened, AsyncFixture.emptyColumn),
                                 (AsyncFixture.original, AsyncFixture.originalSelection)],
                          redo: [(AsyncFixture.widened, AsyncFixture.emptyColumn),
                                 (appended, appendedSelection)])
            }
        ])
    }

    @MainActor func testCancellationAfterWriteStillRemovesOnlyInvalidInverse() throws {
        for notification in [Notification.Name.NSUndoManagerDidOpenUndoGroup,
                             .NSUndoManagerWillCloseUndoGroup, .NSUndoManagerDidCloseUndoGroup] {
            let h = try AsyncNativeHost(AsyncFixture.original)
            defer { h.close() }
            h.view.setSelectedRange(AsyncFixture.originalSelection)
            h.observe(notification, object: h.manager) {
                guard h.observerCalls == 0, h.view.string == AsyncFixture.widened else { return }
                h.observerCalls += 1
                QueueAPI.cancelPending(h.session)
                h.view.string = "observer source"
                h.view.setSelectedRange(NSRange(location: 1, length: 2))
            }
            try AsyncNativeEvents.run([
                .async { next in
                    XCTAssertTrue(h.view.performMarkdownAction(.tableEdit(.insertColumnAfter)))
                    XCTAssertTrue(h.view.performMarkdownAction(.tableEdit(.deleteColumn)))
                    h.finishCommands(next)
                },
                .sync {
                    XCTAssertEqual(h.observerCalls, 1, notification.rawValue)
                    h.assert("observer source", selection: NSRange(location: 1, length: 2))
                    XCTAssertFalse(h.manager.canUndo, "invalid applied inverse must still be cleaned after cancel")
                    XCTAssertFalse(h.manager.canRedo)
                    XCTAssertEqual(h.manager.groupingLevel, 0)
                }
            ])
        }
    }

    @MainActor func testObserverAwayAndBackDoesNotAuthorizePendingSuccessor() throws {
        // Six registration/closing combinations plus one observer reentry
        // inside the native write. Final bytes/range match the intended first
        // command, so a plain end-state comparison cannot pass these cases.
        let cases: [(Notification.Name, AsyncMutation)] = [
            (.NSUndoManagerDidOpenUndoGroup, .string),
            (.NSUndoManagerWillCloseUndoGroup, .string),
            (.NSUndoManagerDidCloseUndoGroup, .string),
            (.NSUndoManagerDidOpenUndoGroup, .selection),
            (.NSUndoManagerWillCloseUndoGroup, .selection),
            (.NSUndoManagerDidCloseUndoGroup, .selection),
            (NSText.didChangeNotification, .storage)
        ]
        for (notification, mutation) in cases {
            let h = try AsyncNativeHost(AsyncFixture.original)
            defer { h.close() }
            h.view.setSelectedRange(AsyncFixture.originalSelection)
            let object: Any = notification == NSText.didChangeNotification ? h.view : h.manager
            h.observe(notification, object: object) {
                guard h.observerCalls == 0, h.view.string == AsyncFixture.widened else { return }
                h.observerCalls += 1 // latch before recursively notifying TextKit
                let saved = h.view.string, range = h.view.selectedRange()
                switch mutation {
                case .string:
                    h.view.string = "away"
                    h.view.string = saved
                    h.view.setSelectedRange(range)
                case .storage:
                    let storage = h.view.textStorage!
                    storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "away")
                    h.view.didChangeText()
                    storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: saved)
                    h.view.didChangeText()
                    h.view.setSelectedRange(range)
                case .selection:
                    h.view.setSelectedRange(NSRange(location: 0, length: 0))
                    h.view.setSelectedRange(range)
                }
            }
            try AsyncNativeEvents.run([
                .async { next in
                    XCTAssertTrue(h.view.performMarkdownAction(.tableEdit(.insertColumnAfter)))
                    XCTAssertTrue(h.view.performMarkdownAction(.tableEdit(.deleteColumn)))
                    h.finishCommands(next)
                },
                .sync {
                    XCTAssertEqual(h.observerCalls, 1, "\(notification.rawValue)/\(mutation)")
                    h.assert(AsyncFixture.widened, selection: AsyncFixture.emptyColumn)
                    XCTAssertEqual(h.manager.undoCount, 1, "successor must not adopt after away-and-back")
                    h.history(undo: [(AsyncFixture.original, AsyncFixture.originalSelection)],
                              redo: [(AsyncFixture.widened, AsyncFixture.emptyColumn)])
                }
            ])
        }
    }

    @MainActor func testPendingTableThenPasteUsesProjectedSelectionAndTwoHistorySteps() throws {
        let h = try AsyncNativeHost(AsyncFixture.original)
        defer { h.close() }
        h.view.setSelectedRange(AsyncFixture.originalSelection)
        let pasted = "| A |  | B |\r\n| --- | --- | --- |\r\n| 中🙂 | P | é |"
        let caret = NSRange(location: (pasted as NSString).range(of: "P").location + 1, length: 0)
        h.view.markdownPasteController.capture = { _ in .success(.init(plainText: "P")) }
        h.view.markdownPasteController.convert = { kind, payload in MarkdownPaste.convert(kind, payload: payload) }
        try AsyncNativeEvents.run([
            .async { next in
                XCTAssertTrue(h.view.performMarkdownAction(.tableEdit(.insertColumnAfter)))
                XCTAssertTrue(h.view.markdownPasteController.perform(.plainText))
                h.assert(AsyncFixture.original, selection: AsyncFixture.originalSelection)
                Task { @MainActor in
                    await h.view.markdownPasteController.waitForPendingPaste()
                    await QueueAPI.wait(h.session)
                    next()
                }
            },
            .sync {
                h.assert(pasted, selection: caret)
                XCTAssertEqual(h.manager.undoCount, 2)
                XCTAssertFalse(h.notices.contains { $0 == .cancelled })
                h.history(undo: [(AsyncFixture.widened, AsyncFixture.emptyColumn),
                                 (AsyncFixture.original, AsyncFixture.originalSelection)],
                          redo: [(AsyncFixture.widened, AsyncFixture.emptyColumn), (pasted, caret)])
            }
        ])
    }

    @MainActor func testPendingPasteThenTableInvalidatesConversionWithCancelledNotice() throws {
        let h = try AsyncNativeHost(AsyncFixture.original), gate = AsyncConversionGate()
        defer { h.close() }
        h.view.setSelectedRange(AsyncFixture.originalSelection)
        h.view.markdownPasteController.capture = { _ in .success(.init(plainText: "LATE")) }
        h.view.markdownPasteController.convert = { _, _ in await gate.wait() }
        try AsyncNativeEvents.run([
            .async { next in
                XCTAssertTrue(h.view.markdownPasteController.perform(.plainText))
                Task { @MainActor in await gate.whenReady(); next() }
            },
            .async { next in
                h.assert(AsyncFixture.original, selection: AsyncFixture.originalSelection)
                XCTAssertTrue(h.view.performMarkdownAction(.tableEdit(.insertColumnAfter)))
                Task { @MainActor in
                    await gate.resolve("LATE")
                    await h.view.markdownPasteController.waitForPendingPaste()
                    await QueueAPI.wait(h.session)
                    next()
                }
            },
            .sync {
                h.assert(AsyncFixture.widened, selection: AsyncFixture.emptyColumn)
                XCTAssertEqual(h.notices.last!, .cancelled, "ordinary staleness must not become silent explicit cancellation")
                XCTAssertEqual(h.manager.undoCount, 1)
                h.history(undo: [(AsyncFixture.original, AsyncFixture.originalSelection)],
                          redo: [(AsyncFixture.widened, AsyncFixture.emptyColumn)])
            }
        ])
    }

    @MainActor func testRefusedOrNoOpTableActionDoesNotCancelPendingPaste() throws {
        for action in [MarkdownEditing.Action.tableEdit(.deleteRow), .outdent] {
            let h = try AsyncNativeHost(AsyncFixture.original), gate = AsyncConversionGate()
            defer { h.close() }
            let selected = (AsyncFixture.original as NSString).range(of: "A")
            let pasted = "| NEW | B |\r\n| --- | --- |\r\n| 中🙂 | é |"
            let caret = NSRange(location: 5, length: 0)
            h.view.setSelectedRange(selected)
            h.view.markdownPasteController.capture = { _ in .success(.init(plainText: "NEW")) }
            h.view.markdownPasteController.convert = { _, _ in await gate.wait() }
            try AsyncNativeEvents.run([
                .async { next in
                    XCTAssertTrue(h.view.markdownPasteController.perform(.plainText))
                    Task { @MainActor in await gate.whenReady(); next() }
                },
                .async { next in
                    XCTAssertEqual(h.view.performMarkdownAction(action), action == .outdent)
                    h.assert(AsyncFixture.original, selection: selected)
                    XCTAssertFalse(h.manager.canUndo)
                    Task { @MainActor in
                        await gate.resolve("NEW")
                        await h.view.markdownPasteController.waitForPendingPaste()
                        await QueueAPI.wait(h.session)
                        next()
                    }
                },
                .sync {
                    h.assert(pasted, selection: caret)
                    XCTAssertFalse(h.notices.contains { $0 == .cancelled })
                    XCTAssertEqual(h.manager.undoCount, 1)
                    h.history(undo: [(AsyncFixture.original, selected)], redo: [(pasted, caret)])
                }
            ])
        }
    }

    @MainActor func testManualCallerAndDisabledPathsRemainSynchronousInRunningApp() throws {
        for mode in ["manual", "caller", "disabled"] {
            let h = try AsyncNativeHost(AsyncFixture.original)
            defer { h.close() }
            h.view.setSelectedRange(AsyncFixture.originalSelection)
            if mode == "manual" { h.manager.groupsByEvent = false }
            try AsyncNativeEvents.run([
                .sync {
                    h.requireNativePremise()
                    if mode == "caller" { h.manager.beginUndoGrouping() }
                    if mode == "disabled" { h.manager.disableUndoRegistration() }
                    let originalLevel = h.manager.groupingLevel
                    XCTAssertEqual(originalLevel, mode == "caller" ? 2 : 0)
                    XCTAssertTrue(h.view.performMarkdownAction(.tableEdit(.insertColumnAfter)))
                    // Intentionally no await: these retained contracts are
                    // synchronous even though NSApplication is running.
                    h.assert(AsyncFixture.widened, selection: AsyncFixture.emptyColumn)
                    XCTAssertEqual(h.manager.groupingLevel, originalLevel)
                    if mode == "caller" { h.manager.endUndoGrouping() }
                    if mode == "disabled" {
                        XCTAssertFalse(h.manager.isUndoRegistrationEnabled)
                        XCTAssertFalse(h.manager.canUndo); XCTAssertFalse(h.manager.canRedo)
                        h.manager.enableUndoRegistration()
                    } else {
                        h.history(undo: [(AsyncFixture.original, AsyncFixture.originalSelection)],
                                  redo: [(AsyncFixture.widened, AsyncFixture.emptyColumn)])
                    }
                }
            ])
        }
    }

    @MainActor func testNativeFieldUndoRedoExecutesInverseSynchronously() throws {
        let h = try AsyncNativeHost(AsyncFixture.original)
        defer { h.close() }
        h.view.setSelectedRange(AsyncFixture.originalSelection)
        try AsyncNativeEvents.run([
            .async { next in
                XCTAssertTrue(h.view.performMarkdownAction(.tableEdit(.insertColumnAfter)))
                h.finishCommands(next)
            },
            .sync {
                h.assert(AsyncFixture.widened, selection: AsyncFixture.emptyColumn)
                XCTAssertTrue(h.window.makeFirstResponder(h.field))
                XCTAssertTrue(h.window.firstResponder === h.field.currentEditor())
                XCTAssertTrue(NSApp.sendAction(Selector(("undo:")), to: nil, from: nil))
                h.assert(AsyncFixture.original, selection: AsyncFixture.originalSelection)
                XCTAssertFalse(h.manager.canUndo)
                XCTAssertTrue(NSApp.sendAction(Selector(("redo:")), to: nil, from: nil))
                h.assert(AsyncFixture.widened, selection: AsyncFixture.emptyColumn)
                XCTAssertFalse(h.manager.canRedo)
            }
        ])
    }
}

@MainActor private enum QueueAPI {
    // Names confirmed by the product author; these await the real production
    // dispatch path and never invoke insertion/acknowledgement directly.
    static func wait(_ session: MarkdownEditorSession) async {
        await session.structuredCommands.waitForPendingCommands()
    }
    static func cancelPending(_ session: MarkdownEditorSession) {
        session.structuredCommands.cancelPending()
    }
}

private enum AsyncMutation { case string, storage, selection }
private enum AsyncFixture {
    static let original = "| A | B |\r\n| --- | --- |\r\n| 中🙂 | é |"
    static let widened = "| A |  | B |\r\n| --- | --- | --- |\r\n| 中🙂 |  | é |"
    static let originalSelection = (original as NSString).range(of: "中🙂")
    static let rightCell = (original as NSString).range(of: "é")
    static let emptyColumn = NSRange(location: (widened as NSString).range(of: "|  |", options: .backwards).location + 2, length: 0)
}

@MainActor private final class AsyncNativeWindow: StructuredCommandEventWindow {
    var suppliedUndo: UndoManager?
    var startupNativeKeys: [(String, UInt16)] = []
    var deliveredNativeKeys: [UInt16] = []
    var beforeNativeKey: ((UInt16) -> Void)?
    override var undoManager: UndoManager? { suppliedUndo }

    override func enqueueProbeStep(_ step: Int) throws {
        try super.enqueueProbeStep(step)
        guard step == 0 else { return }
        for (characters, code) in startupNativeKeys {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            NSApp.postEvent(event, atStart: false)
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, startupNativeKeys.contains(where: { $0.1 == event.keyCode }) {
            deliveredNativeKeys.append(event.keyCode)
            beforeNativeKey?(event.keyCode)
        }
        super.sendEvent(event)
    }
}

@MainActor private final class AsyncNativeHost {
    let session = MarkdownEditorSession()
    let view: MarkdownSourceTextView
    let window: AsyncNativeWindow
    let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 180, height: 24))
    let previousPolicy: NSApplication.ActivationPolicy
    var manager: UndoManager { session.undoManager }
    var textChanges: [String] = []
    var notices: [MarkdownPasteNotice?] = []
    var observerCalls = 0
    var freshAccepted = false
    var batchIdleEntries = -1
    var boundText = ""
    private var coordinator: MarkdownEditorView.Coordinator?
    private var sourceScrollView: NSScrollView?
    private var observations: [NSObjectProtocol] = []

    init(_ source: String, hostCoordinator: Bool = false) throws {
        _ = NSApplication.shared
        previousPolicy = NSApp.activationPolicy()
        _ = NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        view = try XCTUnwrap(session.loadTextView(text: source) as? MarkdownSourceTextView)
        window = AsyncNativeWindow(contentRect: NSRect(x: 120, y: 120, width: 520, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.suppliedUndo = session.undoManager
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
        view.frame = NSRect(x: 0, y: 45, width: 520, height: 270)
        if hostCoordinator {
            boundText = source
            let scrollView = NSScrollView(frame: view.frame)
            let coordinator = MarkdownEditorView.Coordinator(text: Binding(get: { [weak self] in
                self?.boundText ?? source
            }, set: { [weak self] text in self?.boundText = text; self?.textChanges.append(text) }), session: session)
            self.coordinator = coordinator; sourceScrollView = scrollView
            session.host(in: scrollView, coordinator: coordinator)
            root.addSubview(scrollView)
        } else { root.addSubview(view) }
        root.addSubview(field); window.contentView = root
        session.onUnmountedTextChange = { [weak self] text in self?.textChanges.append(text) }
        view.markdownPasteController.onNotice = { [weak self] notice in self?.notices.append(notice) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(view))
    }

    func requireNativePremise(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(NSApp.isRunning, file: file, line: line)
        XCTAssertTrue(NSApp.isActive, file: file, line: line)
        XCTAssertTrue(window.isKeyWindow, file: file, line: line)
        XCTAssertTrue(window.firstResponder === view, file: file, line: line)
    }
    func assert(_ source: String, selection: NSRange, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Array(view.string.utf16), Array(source.utf16), file: file, line: line)
        XCTAssertEqual(view.selectedRange(), selection, file: file, line: line)
    }
    func history(undo: [(String, NSRange)], redo: [(String, NSRange)], file: StaticString = #filePath, line: UInt = #line) {
        for (source, selection) in undo { manager.undo(); assert(source, selection: selection, file: file, line: line) }
        XCTAssertFalse(manager.canUndo, file: file, line: line)
        for (source, selection) in redo { manager.redo(); assert(source, selection: selection, file: file, line: line) }
        XCTAssertFalse(manager.canRedo, file: file, line: line)
    }
    func finishCommands(_ next: @escaping @MainActor () -> Void) {
        Task { @MainActor in await QueueAPI.wait(session); next() }
    }
    func type(_ text: String) {
        for character in text {
            view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }
    func observe(_ name: Notification.Name, object: Any, _ body: @escaping @MainActor () -> Void) {
        observations.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { _ in
            MainActor.assumeIsolated { body() }
        })
    }
    func close() {
        for observer in observations { NotificationCenter.default.removeObserver(observer) }
        observations.removeAll()
        session.invalidatePasteContext(isOpen: false)
        QueueAPI.cancelPending(session)
        manager.removeAllActions()
        window.beforeNativeKey = nil
        if let sourceScrollView, let coordinator { session.unhost(from: sourceScrollView, coordinator: coordinator) }
        coordinator = nil; sourceScrollView = nil
        window.orderOut(nil); window.contentView = nil; window.close()
        _ = NSApp.setActivationPolicy(previousPolicy)
    }
}

@MainActor private enum AsyncNativeEvents {
    enum Step {
        case sync(@MainActor () throws -> Void)
        case async(@MainActor (@escaping @MainActor () -> Void) throws -> Void)
    }
    static func run(_ steps: [Step]) throws {
        try StructuredCommandEventRunner.run(steps.map { step in
            { _, next in
                switch step {
                case .sync(let body): try body(); next()
                case .async(let body): try body(next)
                }
            }
        })
    }
}

private actor AsyncConversionGate {
    private var continuation: CheckedContinuation<Result<MarkdownPaste.Output, MarkdownPaste.Failure>, Never>?
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async -> Result<MarkdownPaste.Output, MarkdownPaste.Failure> {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let waiters = readyWaiters; readyWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }
    func whenReady() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { readyWaiters.append($0) }
    }
    func resolve(_ text: String) {
        let pending = continuation; continuation = nil
        pending?.resume(returning: MarkdownPaste.convert(.plainText, payload: .init(plainText: text)))
    }
}
