import AppKit
import SwiftUI

struct DocumentHistoryView: View {
    static let preferredContentSize = NSSize(width: 680, height: 540)

    @ObservedObject var flow: DocumentHistoryFlow
    @ObservedObject var settings: AppSettings
    let onRestore: (String) -> Void
    let onClose: () -> Void

    @State private var isNamingCopy = false
    @State private var copyName = ""
    @FocusState private var isFilenameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(settings.text(.historyTitle))
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: flow.sourceURL.lastPathComponent)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if flow.revisions.isEmpty {
                emptyHistory
            } else {
                HStack(spacing: 0) {
                    revisionList.frame(width: 215)
                    Divider()
                    excerptPane
                }
                .frame(minHeight: 180, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .disabled(flow.isRestoring)
            }

            if flow.unavailableCount > 0 {
                Text(settings.text(.historySomeUnavailable))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let message = flow.message, message != .historyEmpty {
                status(message)
            }
            if !flow.revisions.isEmpty {
                Text(settings.text(.historyAttachments))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isNamingCopy {
                HStack {
                    Text(settings.text(.copyFilename))
                    TextField(settings.text(.copyFilename), text: $copyName)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("historyCopyFilename")
                        .focused($isFilenameFocused)
                        .disabled(flow.isRestoring)
                }
                .onAppear { isFilenameFocused = true }
            }
            actions
        }
        .padding(22)
        .frame(width: Self.preferredContentSize.width, height: Self.preferredContentSize.height)
        .onChange(of: flow.selection?.id) { _, _ in isNamingCopy = false }
    }

    private var emptyHistory: some View {
        Group {
            if flow.isLoading {
                ProgressView(settings.text(.historyLoading))
            } else if flow.message == nil || flow.message == .historyEmpty {
                Text(settings.text(.historyEmpty))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var revisionList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(Array(flow.revisions.enumerated()), id: \.element.id) { index, revision in
                    revisionButton(revision, index: index)
                }
            }
            .padding(8)
        }
    }

    private func revisionButton(_ revision: DocumentHistoryRevision, index: Int) -> some View {
        let isSelected = flow.selection?.id == revision.id
        return Button {
            flow.select(revision)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(revision.date, format: dateFormat)
                    .fontWeight(isSelected ? .semibold : .regular)
                Text(settings.text(reasonKey(revision.reason)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("historyRevision-\(index)")
    }

    private var excerptPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(settings.text(.historyExcerpt))
                    .font(.callout.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let revision = flow.selection {
                    Text(verbatim: "\(revision.format.encodingLabel) · \(revision.format.lineEnding.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if flow.isLoading {
                ProgressView(settings.text(.historyLoading))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let excerpt = flow.excerpt {
                ScrollView {
                    if excerpt.isEmpty {
                        Text(settings.text(.historyEmptyExcerpt))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(verbatim: excerpt)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("historyRevisionExcerpt")
                    }
                }
                .id(flow.selection?.id)
            } else {
                if flow.message == nil {
                    Text(settings.text(.historySelectRevision))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func status(_ message: L10nKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if message == .historyCopyOpenFailed {
                Text(String(format: settings.text(message), flow.detail ?? ""))
            } else {
                Text(settings.text(message))
                if let detail = flow.detail {
                    Text(verbatim: detail).foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("historyStatus")
    }

    private var actions: some View {
        HStack {
            if flow.isRestoring {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text(settings.text(.historyRestoring)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(settings.text(.close), action: onClose)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("historyClose")
                .disabled(flow.isRestoring)
            if isNamingCopy {
                Button(settings.text(.historyRestoreAndOpen)) { onRestore(copyName) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("historyRestoreAndOpen")
                    .disabled(!canRestore || copyName.isEmpty)
            } else if !flow.revisions.isEmpty {
                Button(settings.text(.historyRestoreAsCopy)) { startNamingCopy() }
                    .accessibilityIdentifier("historyRestoreAsCopy")
                    .disabled(!canRestore)
            }
        }
    }

    private var canRestore: Bool {
        !flow.isLoading && !flow.isRestoring && flow.selection != nil && flow.excerpt != nil
    }

    private func startNamingCopy() {
        let source = flow.sourceURL
        let ext = source.pathExtension.lowercased() == "markdown" ? "markdown" : "md"
        copyName = source.deletingPathExtension().lastPathComponent + settings.text(.historyCopyNameSuffix) + "." + ext
        isNamingCopy = true
    }

    private var dateFormat: Date.FormatStyle {
        let identifier = settings.language.appleLanguagesOverride?.first
        let locale = identifier.map { Locale(identifier: $0) } ?? .current
        return .dateTime.year().month(.abbreviated).day().hour().minute().second().locale(locale)
    }

    private func reasonKey(_ reason: DocumentHistoryReason) -> L10nKey {
        switch reason {
        case .opened: .historyRevisionOpened
        case .saved: .historyRevisionSaved
        case .externalReload: .historyRevisionExternal
        }
    }
}
