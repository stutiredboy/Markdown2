import AppKit
import Foundation
import SwiftUI

struct EditorFindBar: View {
    @Binding var query: String
    @Binding var replacement: String
    let showsReplace: Bool
    let focusToken: UUID
    let statusText: String
    let settings: AppSettings
    let onSubmitQuery: () -> Void
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onReplace: () -> Void
    let onReplaceAll: () -> Void
    let onClose: () -> Void
    var onFocusChange: (Bool) -> Void = { _ in }
    var findSession: FindSession? = nil
    var isReadOnly = false
    var matchCount = 0
    var onUseSelection: () -> Void = {}

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case query
        case replacement
        case replace
        case replaceAll
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField(settings.text(.findPlaceholder), text: $query, onEditingChanged: { editing in
                        onFocusChange(editing)
                    })
                        .textFieldStyle(.plain)
                        .accessibilityLabel(settings.text(.findPlaceholder))
                        .focused($focusedField, equals: .query)
                        .frame(minWidth: 40, maxWidth: .infinity)
                        .onSubmit(onSubmitQuery)

                    if !statusText.isEmpty {
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .frame(maxWidth: 88, alignment: .trailing)
                    }

                    Divider().frame(height: 16)

                    Button(action: onPrevious) {
                        Image(systemName: "chevron.up")
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(settings.text(.findPrevious))
                    .help(settings.text(.findPrevious))
                    .disabled(query.isEmpty)

                    Button(action: onNext) {
                        Image(systemName: "chevron.down")
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(settings.text(.findNext))
                    .help(settings.text(.findNext))
                    .disabled(query.isEmpty)

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(settings.text(.closeFind))
                    .help(settings.text(.closeFind))
                }
                if let findSession {
                    FindOptionsRow(find: findSession, settings: settings, readOnly: isReadOnly,
                                   onUseSelection: onUseSelection)
                        .padding(.top, 7)
                }
                if showsReplace {
                    HStack(spacing: 8) {
                        TextField(settings.text(.replaceWith), text: $replacement, onEditingChanged: { editing in
                            onFocusChange(editing)
                        })
                            .textFieldStyle(.plain)
                            .accessibilityLabel(settings.text(.replaceWith))
                            .focused($focusedField, equals: .replacement)
                            .frame(minWidth: 40, maxWidth: .infinity)

                        Button(settings.text(.replace)) {
                            replace(from: .replace, action: onReplace)
                        }
                            .focused($focusedField, equals: .replace)
                            .fixedSize()
                            .disabled(query.isEmpty || (findSession != nil && matchCount == 0) || findSession?.canReplace == false)
                        Button(settings.text(.replaceAll)) {
                            replace(from: .replaceAll, action: onReplaceAll)
                        }
                            .focused($focusedField, equals: .replaceAll)
                            .fixedSize()
                            .disabled(query.isEmpty || (findSession != nil && matchCount == 0) || findSession?.canReplace == false)
                    }
                    .padding(.top, 8)
                    if let findSession, findSession.scope != .invalid {
                        Text(replacementStatus(findSession))
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                            .accessibilityIdentifier("findReplacementStatus")
                    }
                }
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

    private func replace(from button: Field, action: () -> Void) {
        // If this action removes the last match, it disables the focused
        // button. Keep Escape available in the bar, but allow repeated Space
        // on Replace while there are more matches.
        if focusedField == button, button == .replaceAll || matchCount == 1 {
            focusedField = .replacement
        }
        action()
    }

    private func replacementStatus(_ find: FindSession) -> String {
        if find.scope == .invalid { return settings.text(.findSelectionInvalid) }
        if find.replacementCancelled { return settings.text(.findReplacementCancelled) }
        let label = settings.text(find.isSelectionOnly ? .findSourceSelection : .findWholeDocument)
        if let count = find.replacementCount {
            return String(format: settings.text(.findReplacedCount), label, count)
        }
        return String(format: settings.text(.findScopeCount), label, matchCount)
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

/// Separate option/status rows keep both text fields usable at 360 pt.
private struct FindOptionsRow: View {
    @Bindable var find: FindSession
    let settings: AppSettings
    let readOnly: Bool
    let onUseSelection: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                FindOptionToggle(title: settings.text(.findMatchCase), isOn: $find.options.caseSensitive, identifier: "findMatchCase")
                FindOptionToggle(title: settings.text(.findWholeWord), isOn: $find.options.wholeWord, identifier: "findWholeWord")
                FindOptionToggle(title: settings.text(.findOnlySelection), isOn: Binding(
                    get: { find.isSelectionOnly },
                    set: { enabled in
                        if enabled { onUseSelection() }
                        else { find.scope = .document; find.replacementCount = nil }
                    }), identifier: "findOnlySelection")
                    .disabled(readOnly)
                    .help(settings.text(.findSourceOnlyHelp))
                    .accessibilityIdentifier("findOnlySelection")
            }
            .font(.caption)
            if readOnly {
                Text(settings.text(.findSourceOnlyHelp)).font(.caption).foregroundStyle(.secondary)
            } else if find.isSelectionOnly {
                HStack(alignment: .top) {
                    Text(settings.text(find.scope == .invalid ? .findSelectionInvalid : .findSelectionFrozen))
                        .font(.caption).foregroundStyle(find.scope == .invalid ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(settings.text(.findUseSelection), action: onUseSelection).font(.caption).fixedSize()
                        .accessibilityIdentifier("findUseSelection")
                }
            }
        }
        .onChange(of: find.options) { _, _ in find.replacementCount = nil }
    }
}

/// Native checkbox targets support keyboard activation and expose stable native
/// accessibility/control identity, just like the surrounding find buttons.
private struct FindOptionToggle: NSViewRepresentable {
    let title: String
    @Binding var isOn: Bool
    let identifier: String
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(binding: $isOn) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.setAccessibilityIdentifier(identifier)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.binding = $isOn
        button.title = title
        button.state = isOn ? .on : .off
        button.isEnabled = isEnabled
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
    @MainActor final class Coordinator: NSObject {
        var binding: Binding<Bool>
        init(binding: Binding<Bool>) { self.binding = binding }
        @objc func changed(_ sender: NSButton) { binding.wrappedValue = sender.state == .on }
    }
}
