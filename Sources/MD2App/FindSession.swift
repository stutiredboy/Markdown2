import AppKit
import MD2Core
import Observation

/// Search preferences and source bounds belong to a document, surviving an
/// editor host or Read mode. Invalid scope must never degrade to full text.
@Observable @MainActor
final class FindSession {
    enum Scope: Equatable {
        case document
        case selection(NSRange)
        case invalid
    }

    var options = TextSearch.Options()
    var scope: Scope = .document
    var replacementCount: Int?
    var replacementCancelled = false
    private(set) var identity = UUID()
    var previewUnavailable = false
    private var candidate: NSRange?

    var isSelectionOnly: Bool { scope != .document }
    var canReplace: Bool { scope != .invalid }
    var range: NSRange? {
        if case .selection(let range) = scope { return range }
        return nil
    }

    func rememberSelection(in textView: NSTextView?) {
        candidate = nil
        guard let textView, !textView.hasMarkedText(), textView.selectedRanges.count == 1,
              textView.selectedRange().length > 0 else { return }
        candidate = textView.selectedRange()
    }

    func useSelection(in textView: NSTextView?) {
        if let textView, textView.selectedRange().length > 0 { rememberSelection(in: textView) }
        if let range = candidate, let textView, range.location <= (textView.string as NSString).length,
           range.length <= (textView.string as NSString).length - range.location {
            scope = .selection(range)
        } else { scope = .invalid }
        candidate = nil
        replacementCount = nil
    }

    func invalidateSelection() {
        candidate = nil
        if isSelectionOnly { scope = .invalid }
        replacementCount = nil
    }

    func reset() {
        identity = UUID()
        replacementCancelled = false
        options = .init()
        scope = .document
        candidate = nil
        replacementCount = nil
        previewUnavailable = false
    }
}
