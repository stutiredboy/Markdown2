import AppKit
import CoreFoundation

/// Configure app-owned managers before any document command can register undo.
@MainActor
final class StructuredEditUndoManager: UndoManager {
    let structuredEditMode = RunLoop.Mode("MD2StructuredUndo-" + UUID().uuidString)

    override init() {
        super.init()
        runLoopModes.append(structuredEditMode)
    }
}

/// Finish automatic groups through Foundation's own event callback. Merely
/// closing them by hand leaves a pending callback; reopening an empty explicit
/// group creates a phantom Undo. A private mode avoids both problems without
/// processing ordinary UI events or changing the default typing policy.
@MainActor
final class StructuredEditUndo {
    private let manager: UndoManager
    private let mode: RunLoop.Mode
    private var hasOwnedEventBoundary: Bool

    init(manager: UndoManager) {
        self.manager = manager
        if let configured = manager as? StructuredEditUndoManager {
            mode = configured.structuredEditMode
            hasOwnedEventBoundary = true
        } else {
            mode = RunLoop.Mode("MD2StructuredUndo-" + UUID().uuidString)
            // Adding a mode cannot move an already-scheduled callback. Treat
            // an injected manager's existing group as caller-owned until a
            // closed boundary is observed; retain all of its prior history.
            hasOwnedEventBoundary = manager.groupingLevel == 0
            manager.runLoopModes.append(mode)
        }
    }

    @discardableResult
    func perform(isCurrent: () -> Bool, _ edit: () -> Void) -> Bool {
        if manager.groupingLevel == 0 { hasOwnedEventBoundary = true }
        guard manager.isUndoRegistrationEnabled, !manager.isUndoing, !manager.isRedoing else {
            guard isCurrent() else { return false }
            edit()
            return true
        }
        let ownsEventBoundary = hasOwnedEventBoundary && manager.groupsByEvent && manager.groupingLevel <= 1
        if ownsEventBoundary {
            if manager.groupingLevel == 1 { finishAutomaticGroup() }
            // Checkpoint/close notifications can run client observers. Validate
            // the captured command again before touching its source ranges.
            guard manager.groupingLevel == 0, isCurrent() else { return false }
            edit() // The real edit lazily opens its native automatic group.
            if manager.groupingLevel == 1 { finishAutomaticGroup() }
        } else {
            guard isCurrent() else { return false }
            manager.beginUndoGrouping()
            defer { manager.endUndoGrouping() }
            guard isCurrent() else { return false }
            edit()
        }
        return true
    }

    private func finishAutomaticGroup() {
        // The inert source makes this private mode runnable. Only this
        // manager's Foundation callback is scheduled in the unique mode.
        var context = CFRunLoopSourceContext(version: 0, info: nil, retain: nil,
            release: nil, copyDescription: nil, equal: nil, hash: nil,
            schedule: nil, cancel: nil, perform: { _ in })
        let source = CFRunLoopSourceCreate(nil, 0, &context)!
        let runLoop = CFRunLoopGetCurrent()
        let privateMode = CFRunLoopMode(mode.rawValue as CFString)
        CFRunLoopAddSource(runLoop, source, privateMode)
        defer {
            CFRunLoopRemoveSource(runLoop, source, privateMode)
            CFRunLoopSourceInvalidate(source)
        }
        CFRunLoopRunInMode(privateMode, 0, false)
    }
}

extension NSTextView {
    @MainActor
    @discardableResult
    func withStructuredEditUndo(isCurrent: () -> Bool = { true }, _ edit: () -> Void) -> Bool {
        breakUndoCoalescing()
        defer { breakUndoCoalescing() }
        if let session = delegate as? MarkdownEditorSession {
            return session.structuredEditUndo.perform(isCurrent: isCurrent, edit)
        }
        guard isCurrent() else { return false }
        if let manager = undoManager, manager.isUndoRegistrationEnabled,
           !manager.isUndoing, !manager.isRedoing {
            // External delegates keep the original explicit-group behavior;
            // their manager was not configured by a Markdown editor session.
            manager.beginUndoGrouping()
            defer { manager.endUndoGrouping() }
            guard isCurrent() else { return false }
            edit()
            return true
        }
        edit()
        return true
    }

    /// Preflight without AppKit's preliminary undo registration, matching the
    /// table path. Refused edits never open a command group.
    @MainActor
    @discardableResult
    func insertStructuredText(_ replacement: String, range: NSRange,
                              isCurrent: () -> Bool = { true }, didInsert: () -> Void = {}) -> Bool {
        let manager = undoManager
        manager?.disableUndoRegistration()
        let allowed = shouldChangeText(in: range, replacementString: replacement)
        manager?.enableUndoRegistration()
        guard allowed else { return false }
        return withStructuredEditUndo(isCurrent: isCurrent) {
            insertText(replacement, replacementRange: range)
            didInsert()
        }
    }
}
