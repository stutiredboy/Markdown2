import AppKit
import Combine
import MD2Core

/// User-visible status; the document publishes it in the source pane.
enum MarkdownPasteNotice: Equatable {
    case literalFallback, unavailable, limit, cancelled, unsafeContext
    var title: L10nKey {
        switch self {
        case .literalFallback: .pasteLiteralFallbackNotice
        case .unavailable: .pasteUnavailableNotice
        case .limit: .pasteLimitNotice
        case .cancelled: .pasteCancelledNotice
        case .unsafeContext: .pasteUnsafeContextNotice
        }
    }
}

/// Captures the exact focused source target before crossing an async boundary.
/// All adoption, including fallback, passes the same freshness check.
@MainActor
final class MarkdownPasteController {
    private weak var editor: MarkdownSourceTextView?
    private var requestID = UUID()
    private var task: Task<Void, Never>?
    private var keyWindowObservation: AnyCancellable?
    var capture: (MarkdownPaste.Kind) -> Result<MarkdownPaste.Payload, MarkdownPaste.Failure> = { kind in
        capturePasteboard(.general, kind: kind)
    }
    var convert: @Sendable (MarkdownPaste.Kind, MarkdownPaste.Payload) async -> Result<MarkdownPaste.Output, MarkdownPaste.Failure> = { kind, payload in
        let worker = Task.detached(priority: .userInitiated) { MarkdownPaste.convert(kind, payload: payload) }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }
    /// Production always requires a key window and first responder. Tests can
    /// inject a host predicate without opening a window or using shared pasteboard.
    var isFocusedSource: (MarkdownSourceTextView) -> Bool = {
        $0.window?.isKeyWindow == true && $0.window?.firstResponder === $0
    }
    var onNotice: (MarkdownPasteNotice?) -> Void = { _ in }

    init(editor: MarkdownSourceTextView) { self.editor = editor }

    var canPerform: Bool {
        guard let editor, editor.isEditable, !editor.hasMarkedText(), editor.selectedRanges.count == 1,
              let session = editor.delegate as? MarkdownEditorSession,
              session.isPasteTargetOpen, !session.revealSelectionOnNextHost, isFocusedSource(editor) else { return false }
        return true
    }

    @discardableResult
    func perform(_ kind: MarkdownPaste.Kind) -> Bool {
        // A second command invalidates old work even if its new input fails.
        cancel()
        guard canPerform, let editor, let session = editor.delegate as? MarkdownEditorSession else { return false }
        onNotice(nil)
        let id = requestID
        let source = editor.string
        let selection = editor.selectedRange()
        let generation = session.pasteContextGeneration
        let host = session.pasteHostGeneration
        let window = editor.window
        if let window {
            keyWindowObservation = NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: window)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.cancel() } }
        }
        let payload: MarkdownPaste.Payload
        switch capture(kind) {
        case .success(let value): payload = value
        case .failure(let failure): onNotice(failure == .limit ? .limit : .unavailable); return true
        }
        task = Task { [weak self, weak editor, weak session, weak window] in
            guard let self else { return }
            let result = await self.convert(kind, payload)
            guard self.requestID == id, !Task.isCancelled else { return }
            guard let editor, let session, self.canPerform, editor.delegate === session,
                  editor.window === window, session.pasteHostGeneration == host,
                  session.pasteContextGeneration == generation,
                  editor.selectedRanges.count == 1, editor.selectedRange() == selection,
                  (editor.string as NSString).isEqual(to: source) else {
                self.onNotice(.cancelled)
                return
            }
            switch result {
            case .failure(let failure):
                self.onNotice(failure == .limit ? .limit : failure == .cancelled ? .cancelled : .unavailable)
            case .success(let output):
                guard let edit = MarkdownPaste.edit(source, selection: selection, output: output) else {
                    self.onNotice(output.fallbackReason == nil ? .limit : .unsafeContext); return
                }
                // Explicit replacement bypasses auto-pairing and ordinary Cmd+V.
                // Native shouldChangeText decides whether mutation is permitted;
                // never force a selection after an editor delegate rejects it.
                let expected = (source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
                var stale = false
                editor.insertStructuredText(edit.replacement, range: edit.range, isCurrent: {
                    let current = self.requestID == id && self.canPerform && editor.delegate === session &&
                    editor.window === window && session.pasteHostGeneration == host &&
                    session.pasteContextGeneration == generation && editor.selectedRange() == selection &&
                    (editor.string as NSString).isEqual(to: source)
                    stale = !current
                    return current
                }, didInsert: {
                    guard (editor.string as NSString).isEqual(to: expected) else { return }
                    editor.setSelectedRange(edit.selection)
                    editor.scrollRangeToVisible(edit.selection)
                    if output.fallbackReason != nil { self.onNotice(.literalFallback) }
                })
                if stale { self.onNotice(.cancelled) }
            }
        }
        return true
    }
    func cancel() {
        requestID = UUID()
        task?.cancel()
        task = nil
        keyWindowObservation = nil
    }
    /// Awaitable completion is a test seam, not an alternate adoption path.
    func waitForPendingPaste() async { await task?.value }

    static func capturePasteboard(_ board: NSPasteboard, kind: MarkdownPaste.Kind) -> Result<MarkdownPaste.Payload, MarkdownPaste.Failure> {
        let change = board.changeCount
        // Multiple separate clipboard items cannot be safely called one complete
        // fallback string; ordinary native paste remains available for them.
        guard let items = board.pasteboardItems, items.count == 1, let item = items.first else { return .failure(.unavailable) }
        let limits = MarkdownPaste.Limits()
        let plain = item.string(forType: .string)
        if let plain, plain.utf8.count > limits.plainBytes { return .failure(.limit) }
        var payload = MarkdownPaste.Payload(plainText: plain)
        if kind == .markdown {
            if item.types.contains(.html) {
                guard let data = item.data(forType: .html) else { return .failure(.unavailable) }
                guard data.count <= limits.richBytes else { return .failure(.limit) }
                payload.html = data
            } else if item.types.contains(.rtf) {
                guard let data = item.data(forType: .rtf) else { return .failure(.unavailable) }
                guard data.count <= limits.richBytes else { return .failure(.limit) }
                payload.rtf = data
            }
        }
        guard board.changeCount == change else { return .failure(.cancelled) }
        return .success(payload)
    }
}
