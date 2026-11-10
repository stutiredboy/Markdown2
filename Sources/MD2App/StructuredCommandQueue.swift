import AppKit
import MD2Core

struct StructuredCommandEdit {
    let range: NSRange
    let replacement: String
    let selection: NSRange
}

@MainActor
final class StructuredCommandTicket {
    enum Result { case applied, cancelled, refused, superseded }
    let id = UUID()
    let source: String
    let selection: NSRange
    fileprivate var result: Result?
    fileprivate var authorizedGeneration: UInt64?
    fileprivate var authorizedRevision: UInt64?
    fileprivate(set) var cancelled = false
    private var waiters: [CheckedContinuation<Result, Never>] = []

    init(source: String, selection: NSRange) { self.source = source; self.selection = selection }
    func value() async -> Result {
        if let result { return result }
        return await withCheckedContinuation { waiters.append($0) }
    }
    fileprivate func finish(_ result: Result) {
        guard self.result == nil else { return }
        self.result = result
        let callbacks = waiters; waiters.removeAll()
        for callback in callbacks { callback.resume(returning: result) }
    }
}

/// Value snapshot plus weak native identities. A projected target is authorized
/// only by its exact predecessor's verified completion, never by a fresh read
/// of the current generation after an unrelated edit.
@MainActor
final class StructuredCommandTarget {
    let source: String
    let selection: NSRange
    fileprivate let predecessor: StructuredCommandTicket?
    fileprivate weak var editor: MarkdownSourceTextView?
    private weak var session: MarkdownEditorSession?
    private weak var window: NSWindow?
    private weak var responder: NSResponder?
    private let hadWindow: Bool
    private let hadResponder: Bool
    private let key: Bool?
    private let host: UInt64
    private let generation: UInt64
    private let revision: UInt64

    fileprivate init(editor: MarkdownSourceTextView, session: MarkdownEditorSession,
                     predecessor: StructuredCommandTicket?) {
        self.editor = editor; self.session = session; self.predecessor = predecessor
        source = predecessor?.source ?? editor.string
        selection = predecessor?.selection ?? editor.selectedRange()
        window = editor.window; responder = editor.window?.firstResponder
        hadWindow = editor.window != nil; hadResponder = responder != nil
        key = editor.window?.isKeyWindow
        host = session.pasteHostGeneration; generation = session.pasteContextGeneration
        revision = session.structuredSourceRevision
    }

    func waitForPredecessor() async {
        if let predecessor { _ = await predecessor.value() }
    }

    fileprivate func hasCurrentHost() -> Bool {
        guard let editor, let session, editor.delegate === session, session.isPasteTargetOpen,
              editor.isEditable, !editor.hasMarkedText(), editor.selectedRanges.count == 1,
              editor.window === window, (editor.window != nil) == hadWindow,
              editor.window?.firstResponder === responder, (responder != nil) == hadResponder,
              editor.window?.isKeyWindow == key, session.pasteHostGeneration == host else { return false }
        return true
    }

    func isCurrent() -> Bool {
        guard hasCurrentHost(), let editor, let session,
              editor.selectedRange() == selection, (editor.string as NSString).isEqual(to: source) else { return false }
        if let predecessor {
            return predecessor.result == .applied &&
                predecessor.authorizedGeneration == session.pasteContextGeneration &&
                predecessor.authorizedRevision == session.structuredSourceRevision
        }
        return generation == session.pasteContextGeneration && revision == session.structuredSourceRevision
    }
}

/// Observations of the one native replacement, including reentrant edits.
/// Character processing is observed independently of NSTextView's notification:
/// direct string/storage writes can otherwise change away and back unnoticed.
@MainActor
private final class StructuredWriteTrace {
    let source: String
    let nativeSelection: NSRange
    let selection: NSRange
    let changedRange: NSRange
    let lengthChange: Int
    let selectionOnly: Bool
    var characterEdits = 0
    var valid = true
    var reachedRequestedSelection = false

    init(target: StructuredCommandTarget, edit: StructuredCommandEdit) {
        source = (target.source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        changedRange = NSRange(location: edit.range.location, length: edit.replacement.utf16.count)
        lengthChange = edit.replacement.utf16.count - edit.range.length
        nativeSelection = NSRange(location: NSMaxRange(changedRange), length: 0)
        selection = edit.selection
        selectionOnly = edit.range.length == 0 && edit.replacement.isEmpty
    }
    func characters(_ editor: NSTextView, range: NSRange, delta: Int) {
        characterEdits += 1
        if characterEdits != 1 || range != changedRange || delta != lengthChange ||
            !(editor.string as NSString).isEqual(to: source) { valid = false }
    }
    func context(_ editor: NSTextView, selectionChanged: Bool) {
        guard (editor.string as NSString).isEqual(to: source) else { valid = false; return }
        if selectionChanged {
            let current = editor.selectedRange()
            if current == selection { reachedRequestedSelection = true }
            else if selectionOnly || current != nativeSelection || reachedRequestedSelection { valid = false }
        }
    }
}

/// One weak registry/monitor for our own application-defined events. It never
/// pumps a run loop or dispatches another input event on behalf of an editor.
@MainActor
private final class StructuredCommandDispatcher {
    static let shared = StructuredCommandDispatcher()
    private final class Destination {
        weak var queue: StructuredCommandQueue?
        init(_ queue: StructuredCommandQueue) { self.queue = queue }
    }
    private let tag = Int.random(in: 1...Int.max)
    private var nextID = 0
    private var destinations: [Int: Destination] = [:]
    private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, event.subtype.rawValue == 0x4D35, event.data1 == self.tag else { return false }
                self.destinations[event.data2]?.queue?.receive(event.data2)
                if self.destinations[event.data2]?.queue == nil { self.destinations[event.data2] = nil }
                return true
            }
            return consumed ? nil : event
        }
    }
    func register(_ queue: StructuredCommandQueue) -> Int {
        destinations = destinations.filter { $0.value.queue != nil }
        nextID &+= 1
        destinations[nextID] = Destination(queue)
        return nextID
    }
    func post(_ id: Int, atStart: Bool) {
        guard let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            subtype: 0x4D35, data1: tag, data2: id) else { return }
        NSApp.postEvent(event, atStart: atStart)
    }
    func retire(_ id: Int) { destinations[id] = nil }
}

private final class StructuredCloseObservation {
    let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

@MainActor
final class StructuredCommandQueue {
    enum Origin { case tableAction, pasteConversion }
    @MainActor private final class Command {
        let marker: Int
        let target: StructuredCommandTarget
        let edit: StructuredCommandEdit
        let ticket: StructuredCommandTicket
        let pasteRequest: UUID?
        let origin: Origin
        let validation: @MainActor () -> Bool
        var receipt: StructuredInsertionReceipt?
        var applying = false
        var cancelled = false
        var parked = false
        var posted = false
        var transitionValid = false

        init(marker: Int, target: StructuredCommandTarget, edit: StructuredCommandEdit,
             pasteRequest: UUID?, origin: Origin, validation: @escaping @MainActor () -> Bool) {
            self.marker = marker; self.target = target; self.edit = edit
            self.pasteRequest = pasteRequest; self.origin = origin; self.validation = validation
            ticket = StructuredCommandTicket(source: (target.source as NSString)
                .replacingCharacters(in: edit.range, with: edit.replacement), selection: edit.selection)
        }
    }

    private weak var session: MarkdownEditorSession?
    private var pending: [Command] = []
    private var active: Command?
    private var trace: StructuredWriteTrace?
    private var closeObservation: StructuredCloseObservation?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(session: MarkdownEditorSession) {
        self.session = session
        closeObservation = StructuredCloseObservation(NotificationCenter.default.addObserver(forName: .NSUndoManagerDidCloseUndoGroup,
            object: session.undoManager, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.wakeParkedCommands() }
            })
    }

    var hasPendingCommands: Bool { active != nil || !pending.isEmpty }
    var hasPendingTableActions: Bool {
        active?.origin == .tableAction || pending.contains { $0.origin == .tableAction }
    }

    func captureTarget(in editor: MarkdownSourceTextView, excludingUnstartedPastes: Bool = false) -> StructuredCommandTarget? {
        guard let session, editor.delegate === session else { return nil }
        let predecessor = pending.last { !excludingUnstartedPastes || $0.origin != .pasteConversion }?.ticket
        return StructuredCommandTarget(editor: editor, session: session,
            predecessor: predecessor ?? (active?.cancelled == false ? active?.ticket : nil))
    }

    @discardableResult
    func submit(edit: StructuredCommandEdit, target: StructuredCommandTarget, pasteRequest: UUID? = nil,
                origin: Origin = .tableAction,
                validation: @escaping @MainActor () -> Bool = { true }) -> StructuredCommandTicket? {
        guard let session, let editor = target.editor, editor.delegate === session,
              session.isPasteTargetOpen, session.structuredEditUndo.requiresApplicationEvent,
              edit.range.location >= 0, edit.range.length >= 0,
              edit.range.location <= target.source.utf16.count,
              edit.range.length <= target.source.utf16.count - edit.range.location else { return nil }
        let marker = StructuredCommandDispatcher.shared.register(self)
        let command = Command(marker: marker, target: target, edit: edit,
            pasteRequest: pasteRequest, origin: origin, validation: validation)
        pending.append(command)
        command.parked = true
        wakeParkedCommands()
        return command.ticket
    }

    func cancelUnstartedPasteConversions() {
        let cancelled = pending.filter { $0.origin == .pasteConversion }
        pending.removeAll { $0.origin == .pasteConversion }
        for command in cancelled { retire(command, result: .cancelled); invalidateDependents(of: command.ticket) }
        wakeParkedCommands(); notifyIfIdle()
    }

    func cancelPending(pasteRequest: UUID? = nil) {
        let cancelled = pending.filter { pasteRequest == nil || $0.pasteRequest == pasteRequest }
        pending.removeAll { command in cancelled.contains { $0 === command } }
        if let active, pasteRequest == nil || active.pasteRequest == pasteRequest {
            active.cancelled = true; active.ticket.cancelled = true
        }
        for command in cancelled { retire(command, result: .cancelled); invalidateDependents(of: command.ticket) }
        notifyIfIdle()
    }

    func waitForPendingCommands() async {
        guard hasPendingCommands else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    func observedContextChange(in editor: NSTextView, selectionChanged: Bool) {
        trace?.context(editor, selectionChanged: selectionChanged)
    }

    func observedCharacterChange(in editor: NSTextView, range: NSRange, delta: Int) {
        trace?.characters(editor, range: range, delta: delta)
    }

    fileprivate func receive(_ marker: Int) {
        if let active, active.marker == marker {
            active.posted = false
            guard !active.applying, let session, session.undoManager.groupingLevel == 0 else {
                active.parked = true; return
            }
            finalize(active)
            return
        }
        guard let command = pending.first(where: { $0.marker == marker }) else { return }
        command.posted = false
        guard active == nil, pending.first === command, let session,
              session.undoManager.groupingLevel == 0 else { command.parked = true; return }
        // Detach from the pending array and publish a stable active reference
        // before preflight/native callbacks can cancel or reenter this queue.
        pending.removeFirst(); active = command; command.applying = true
        guard session.structuredEditUndo.requiresApplicationEvent,
              command.target.isCurrent(), command.validation(), let editor = command.target.editor else {
            active = nil; retire(command, result: .cancelled)
            invalidateDependents(of: command.ticket); wakeParkedCommands(); notifyIfIdle(); return
        }
        if command.edit.range.length == 0, command.edit.replacement.isEmpty {
            let navigationTrace = StructuredWriteTrace(target: command.target, edit: command.edit)
            trace = navigationTrace
            if editor.selectedRange() != command.edit.selection { editor.setSelectedRange(command.edit.selection) }
            editor.scrollRangeToVisible(command.edit.selection)
            trace = nil
            let valid = navigationTrace.valid && navigationTrace.characterEdits == 0 &&
                command.target.hasCurrentHost() && editor.selectedRange() == command.edit.selection &&
                (editor.string as NSString).isEqual(to: command.ticket.source)
            if valid, !command.cancelled {
                command.ticket.authorizedGeneration = session.pasteContextGeneration
                command.ticket.authorizedRevision = session.structuredSourceRevision
            }
            active = nil
            retire(command, result: valid ? .applied : .cancelled)
            if !valid || command.cancelled { invalidateDependents(of: command.ticket) }
            wakeParkedCommands(); notifyIfIdle(); return
        }
        let writeTrace = StructuredWriteTrace(target: command.target, edit: command.edit)
        trace = writeTrace
        let receipt = editor.applyStructuredText(command.edit.replacement, range: command.edit.range,
            selection: command.edit.selection, atApplicationEventBoundary: true) { [weak command] in
                guard let command else { return false }
                return !command.cancelled && command.target.isCurrent() && command.validation()
            }
        trace = nil
        command.receipt = receipt
        command.transitionValid = writeTrace.valid && writeTrace.characterEdits == 1
        command.applying = false
        guard receipt != nil else {
            let current = !command.cancelled && command.target.isCurrent() && command.validation()
            active = nil; retire(command, result: current ? .refused : .cancelled)
            invalidateDependents(of: command.ticket); wakeParkedCommands(); notifyIfIdle(); return
        }
        post(command, acknowledgement: true)
    }

    private func finalize(_ command: Command) {
        guard active === command, let receipt = command.receipt else { return }
        // Remove the old active identity before removeAllActions/completion:
        // observers may submit a fresh command, which belongs to a new chain.
        active = nil
        let inserted = receipt.finalize()
        if inserted, let session, let editor = command.target.editor,
           !command.cancelled, command.transitionValid,
           command.target.hasCurrentHost(),
           receipt.generation == session.pasteContextGeneration,
           receipt.sourceRevision == session.structuredSourceRevision,
           editor.selectedRange() == command.ticket.selection {
            command.ticket.authorizedGeneration = session.pasteContextGeneration
            command.ticket.authorizedRevision = session.structuredSourceRevision
        }
        if command.ticket.authorizedGeneration == nil { invalidateDependents(of: command.ticket) }
        retire(command, result: inserted ? .applied : .superseded)
        wakeParkedCommands(); notifyIfIdle()
    }

    private func invalidateDependents(of ticket: StructuredCommandTicket) {
        let children = pending.filter { $0.target.predecessor === ticket }
        pending.removeAll { command in children.contains { $0 === command } }
        for child in children { retire(child, result: .cancelled); invalidateDependents(of: child.ticket) }
    }
    private func retire(_ command: Command, result: StructuredCommandTicket.Result) {
        StructuredCommandDispatcher.shared.retire(command.marker)
        command.ticket.finish(result)
    }
    private func post(_ command: Command, acknowledgement: Bool) {
        guard !command.posted else { return }
        command.posted = true; command.parked = false
        // A table action continues the native command already being handled:
        // a prequeued next key must see its new row/cell. Async paste results
        // instead remain behind already queued input and validate their capture.
        StructuredCommandDispatcher.shared.post(command.marker,
            atStart: acknowledgement || command.origin == .tableAction)
    }
    private func wakeParkedCommands() {
        if let active {
            if active.parked, !active.applying { post(active, acknowledgement: true) }
            return
        }
        if let command = pending.first, command.parked { post(command, acknowledgement: false) }
    }
    private func notifyIfIdle() {
        guard !hasPendingCommands else { return }
        let waiters = idleWaiters; idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
