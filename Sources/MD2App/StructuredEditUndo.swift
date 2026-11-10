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

    /// Pasting and table mutations share one inverse including selection.
    /// Register it only after the native write. Automatic-group notifications
    /// can then change the editor without a pending old insertion overwriting
    /// their newer state. A unique target lets us discard only this inverse if
    /// a registration/closing observer invalidates it.
    @MainActor
    @discardableResult
    func insertStructuredText(_ replacement: String, range: NSRange, selection: NSRange? = nil,
                              isCurrent additionalValidation: () -> Bool = { true }) -> Bool {
        let manager = undoManager
        let source = string, oldSelection = selectedRange(), originalDelegate = delegate
        let originalWindow = window, originalResponder = window?.firstResponder, wasKey = window?.isKeyWindow
        let session = delegate as? MarkdownEditorSession
        let generation = session?.pasteContextGeneration, host = session?.pasteHostGeneration
        let unchangedContext = {
            self.isEditable && !self.hasMarkedText() && self.selectedRanges.count == 1 &&
            self.delegate === originalDelegate && self.window === originalWindow &&
            self.window?.firstResponder === originalResponder && self.window?.isKeyWindow == wasKey &&
            session?.pasteHostGeneration == host
        }
        func isCurrent() -> Bool {
            additionalValidation() && unchangedContext() && self.selectedRange() == oldSelection &&
            session?.pasteContextGeneration == generation && (self.string as NSString).isEqual(to: source)
        }
        let sourceLength = (source as NSString).length
        guard range.location >= 0, range.location <= sourceLength, range.length >= 0,
              range.length <= sourceLength - range.location, isCurrent() else { return false }
        manager?.disableUndoRegistration()
        let allowed = shouldChangeText(in: range, replacementString: replacement)
        manager?.enableUndoRegistration()
        guard allowed, isCurrent() else { return false }
        let original = (source as NSString).substring(with: range)
        let expected = (source as NSString).replacingCharacters(in: range, with: replacement)
        let inverseRange = NSRange(location: range.location, length: replacement.utf16.count)
        let nativeSelection = NSRange(location: NSMaxRange(inverseRange), length: 0)
        let inverse = StructuredTextUndo(editor: self, range: inverseRange,
            expected: replacement, replacement: original, selection: oldSelection)
        var inserted = false
        withStructuredEditUndo(isCurrent: isCurrent) {
            manager?.disableUndoRegistration()
            insertText(replacement, replacementRange: range)
            manager?.enableUndoRegistration()
            inserted = (self.string as NSString).isEqual(to: expected)
            guard inserted else { return }
            // Selection is part of the edit, before Undo group notifications.
            // A later registration/close observer retains its own selection.
            if unchangedContext() {
                self.setSelectedRange(selection ?? nativeSelection)
                self.scrollRangeToVisible(selection ?? nativeSelection)
            }
            manager?.registerUndo(withTarget: inverse) { [inverse] _ in
                MainActor.assumeIsolated { inverse.apply() }
            }
        }
        guard inserted else { return false }
        if !(string as NSString).isEqual(to: expected) {
            // Remove after the helper closes its group: removing a marker from
            // an open automatic group would leave a phantom empty Undo step.
            manager?.removeAllActions(withTarget: inverse)
            return false
        }
        return true
    }
}

@MainActor
private final class StructuredTextUndo: NSObject {
    private weak var editor: NSTextView?
    private let range: NSRange
    private let expected: String
    private let replacement: String
    private let selection: NSRange

    init(editor: NSTextView, range: NSRange, expected: String, replacement: String, selection: NSRange) {
        self.editor = editor
        self.range = range
        self.expected = expected
        self.replacement = replacement
        self.selection = selection
    }

    func apply() {
        guard let editor else { return }
        let source = editor.string as NSString
        guard range.location <= source.length, range.length <= source.length - range.location,
              (source.substring(with: range) as NSString).isEqual(to: expected) else { return }
        editor.insertStructuredText(replacement, range: range, selection: selection)
    }
}
