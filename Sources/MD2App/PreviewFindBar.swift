import Foundation
import SwiftUI

/// A minimal find-only bar shown over the preview. Drives search through the
/// bound `query`; navigation and dismissal are reported via callbacks. Replace
/// is intentionally absent because the rendered page is read-only.
struct PreviewFindBar: View {
    @Binding var query: String
    /// Changes whenever the containing view wants the query field focused.
    let focusToken: UUID
    /// Localized match status, e.g. "2 of 7", "No results", or empty.
    let statusText: String
    let settings: AppSettings
    let onSubmitQuery: () -> Void
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void
    var onFocusChange: (Bool) -> Void = { _ in }
    var findSession: FindSession? = nil

    var body: some View {
        EditorFindBar(
            query: $query, replacement: .constant(""), showsReplace: false,
            focusToken: focusToken, statusText: statusText, settings: settings,
            onSubmitQuery: onSubmitQuery, onNext: onNext, onPrevious: onPrevious,
            onReplace: {}, onReplaceAll: {}, onClose: onClose, onFocusChange: onFocusChange, findSession: findSession, isReadOnly: true
        )
    }
}
