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

    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(settings.text(.findPlaceholder), text: $query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .frame(minWidth: 160)
                .onSubmit(onSubmitQuery)

            if !statusText.isEmpty {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Divider().frame(height: 16)

            Button(action: onPrevious) {
                Image(systemName: "chevron.up")
            }
            .accessibilityLabel(settings.text(.findPrevious))
            .help(settings.text(.findPrevious))
            .disabled(query.isEmpty)

            Button(action: onNext) {
                Image(systemName: "chevron.down")
            }
            .accessibilityLabel(settings.text(.findNext))
            .help(settings.text(.findNext))
            .disabled(query.isEmpty)

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel(settings.text(.closeFind))
            .help(settings.text(.closeFind))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .onExitCommand(perform: onClose)
        .onAppear { focusField() }
        .onChange(of: focusToken) { _, _ in focusField() }
    }

    private func focusField() {
        // Defer to the next runloop tick: when the bar first appears its text
        // field is not yet in the responder chain and the web view still holds
        // first responder, so a synchronous assignment is dropped.
        DispatchQueue.main.async {
            fieldFocused = true
        }
    }
}
