import Foundation
import SwiftUI

struct EditorFindBar: View {
    @Binding var query: String
    @Binding var replacement: String
    let showsReplace: Bool
    let focusToken: UUID
    let statusText: String
    let settings: AppSettings
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onReplace: () -> Void
    let onReplaceAll: () -> Void
    let onClose: () -> Void

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case query
        case replacement
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField(settings.text(.findPlaceholder), text: $query)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .query)
                    .frame(minWidth: 170)
                    .onSubmit(onNext)

                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(minWidth: 72, alignment: .trailing)
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

                if showsReplace {
                    Divider().frame(height: 16)

                    TextField(settings.text(.replace), text: $replacement)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .replacement)
                        .frame(minWidth: 140)

                    Button(settings.text(.replace), action: onReplace)
                        .disabled(query.isEmpty)

                    Button(settings.text(.replaceAll), action: onReplaceAll)
                        .disabled(query.isEmpty)
                }

                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel(settings.text(.closeFind))
                .help(settings.text(.closeFind))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            Divider()
        }
        .background(.regularMaterial)
        .onExitCommand(perform: onClose)
        .onAppear { focusQuery() }
        .onChange(of: focusToken) { _, _ in focusQuery() }
    }

    private func focusQuery() {
        // Defer to the next runloop tick: when the bar first appears its text
        // field is not yet in the responder chain and the text view still holds
        // first responder, so a synchronous assignment is dropped.
        DispatchQueue.main.async {
            focusedField = .query
        }
    }
}
