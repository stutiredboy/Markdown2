import AppKit

/// Focus commands belong to the document view, not a disposable WebKit host.
/// A resource-policy replacement must not replay a token that host consumed.
@MainActor
final class PreviewFocusState {
    private(set) var lastConsumedToken: UUID?
    private weak var retiringWindow: NSWindow?
    private weak var retiringResponder: NSResponder?

    var hasPendingRestoration: Bool { retiringWindow != nil }

    func consume(_ token: UUID) -> Bool {
        guard lastConsumedToken != token else { return false }
        lastConsumedToken = token
        clearRestoration()
        return true
    }

    /// Only the retiring preview may transfer its own focus. An editor or
    /// native field that currently owns the window is never a preview request.
    func preserveFocus(from view: NSView) {
        clearRestoration()
        guard let window = view.window,
              let responder = window.firstResponder as? NSView,
              responder === view || responder.isDescendant(of: view) else { return }
        retiringWindow = window
        retiringResponder = responder
    }

    /// Recheck the current responder when the replacement is attached. Any
    /// intervening editor/find/filename-field focus defeats the old restoration.
    func consumeRestoration(in view: NSView) -> Bool {
        guard let window = view.window else { return false }
        defer { clearRestoration() }
        guard window === retiringWindow else { return false }
        let current = window.firstResponder
        return current == nil || current === retiringResponder
            || current === window || current === window.contentView
    }

    private func clearRestoration() {
        retiringWindow = nil
        retiringResponder = nil
    }
}
