import AppKit
import SwiftUI

/// Attach the comparison to the window that owns the paused autosave and draft.
@MainActor
enum ExternalConflictSheet {
    static func present(in window: NSWindow, store: DocumentStore, settings: AppSettings,
                        onDismiss: @escaping () -> Void) {
        let panel = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = settings.text(.externalChangeConflictTitle)
        panel.setAccessibilityIdentifier("externalConflictSheet")
        panel.contentViewController = NSHostingController(rootView: ExternalConflictView(
            store: store, settings: settings, close: { [weak window, weak panel] in
                guard let panel, let window, panel.sheetParent === window else { return }
                window.endSheet(panel)
            }
        ))
        panel.setContentSize(NSSize(width: min(760, max(640, window.frame.width - 36)),
                                    height: min(520, max(390, window.frame.height - 100))))
        window.beginSheet(panel) { _ in onDismiss() }
    }
}

private struct ExternalConflictView: View {
    @ObservedObject var store: DocumentStore
    @ObservedObject var settings: AppSettings
    let close: () -> Void

    @State private var comparison: ExternalConflictComparison?
    @State private var difference: ConflictPassageComparison?
    @State private var loading = true
    @State private var refreshID = UUID()
    @State private var busy = false
    @State private var message: String?
    @State private var copyName: String?
    @FocusState private var namingCopy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(settings.text(.externalChangeConflictTitle)).font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(verbatim: store.displayTitle).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Text(settings.text(.externalChangeConflictMessage))
                .fixedSize(horizontal: false, vertical: true)
            comparisonPane
            if let message {
                Text(verbatim: message).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("conflictStatus")
            }
            if copyName != nil {
                namingControls
            } else {
                actions
            }
        }
        .padding(20)
        .task(id: refreshID) { await loadComparison() }
        .onChange(of: store.documentIdentity) { close() }
        .onChange(of: store.hasExternalConflict) {
            if !store.hasExternalConflict { close() }
        }
    }

    private var comparisonPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 20) {
                versionHeader(.conflictEditorVersion, format: comparison?.editorFormat, id: "conflictEditorVersion")
                versionHeader(.conflictDiskVersion, format: comparison?.diskFormat, id: "conflictDiskVersion")
            }
            .padding(12)
            Divider()
            if loading {
                ProgressView(settings.text(.conflictLoading)).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let difference {
                if difference.passages.isEmpty {
                    Text(settings.text(.conflictMatchingText))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if difference.isCoarse {
                                Text(settings.text(.conflictCoarse)).font(.callout).padding(12)
                                Divider()
                            }
                            ForEach(difference.passages.indices, id: \.self) { index in
                                let passage = difference.passages[index]
                                HStack(alignment: .top, spacing: 20) {
                                    passageColumn(passage.editorText, lines: passage.editorLines, id: "conflictEditorText-\(index)")
                                    passageColumn(passage.diskText, lines: passage.diskLines, id: "conflictDiskText-\(index)")
                                }
                                .padding(12)
                                Divider()
                            }
                        }
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Text(settings.text(comparison == nil ? .conflictUnavailable : .conflictUndecodable))
                    Button(settings.text(.conflictRefresh)) { refresh() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.separator).allowsHitTesting(false) }
    }

    private func versionHeader(_ key: L10nKey, format: MarkdownFileFormat?, id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(settings.text(key)).font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(id)
            if let format {
                let ending = format.lineEnding == .mixed ? settings.text(.mixedLineEndings) : format.lineEnding.rawValue
                Text(verbatim: "\(format.encodingLabel) · \(ending)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func passageColumn(_ passage: String, lines: Range<Int>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if lines.isEmpty {
                Text(settings.text(.conflictNoPassage)).font(.callout).foregroundStyle(.secondary)
            } else {
                let location = lines.count == 1 ? String(format: settings.text(.conflictOneLine), lines.lowerBound)
                    : String(format: settings.text(.conflictLineRange), lines.lowerBound, lines.upperBound - 1)
                Text(verbatim: location).font(.caption).foregroundStyle(.secondary)
                if passage.isEmpty {
                    Text(settings.text(.conflictBlankLine)).font(.callout).italic()
                } else {
                    ConflictPassageText(source: passage, id: id, settings: settings)
                        .id(refreshID)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        HStack {
            Button(settings.text(.linkedSaveLater)) { deferAndClose() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("conflictLater")
            Spacer()
            Button(settings.text(.conflictSaveEditorCopy)) { beginCopyNaming() }
                .accessibilityIdentifier("conflictSaveEditorCopy")
            Button(settings.text(.reloadFromDisk)) { resolve(reload: true) }
                .disabled(difference == nil)
                .accessibilityIdentifier("conflictReload")
            Button(settings.text(.keepMyVersion)) { resolve(reload: false) }
                .disabled(comparison == nil)
                .accessibilityIdentifier("conflictKeep")
        }
        .disabled(busy)
    }

    private var namingControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let directory = store.fileURL?.deletingLastPathComponent() {
                Text(verbatim: String(format: settings.text(.conflictCopyLocation), directory.path))
                    .lineLimit(1).truncationMode(.middle).help(directory.path)
            }
            HStack {
                TextField(settings.text(.copyFilename), text: Binding(get: { copyName ?? "" }, set: { copyName = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("conflictCopyFilename")
                    .focused($namingCopy)
                Button(settings.text(.cancel)) { copyName = nil }
                    .keyboardShortcut(.cancelAction)
                Button(settings.text(.conflictConfirmCopy)) { saveCopy() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("conflictConfirmCopy")
                    .disabled(copyName?.isEmpty != false)
            }
        }
        .disabled(busy)
    }

    private func loadComparison() async {
        let snapshot = await store.externalConflictComparison()
        var passages: ConflictPassageComparison?
        if let snapshot, let disk = snapshot.diskText {
            let worker = Task.detached(priority: .userInitiated) { [editor = snapshot.editorText] in
                try ConflictPassageComparison.compare(editor: editor, disk: disk)
            }
            passages = await withTaskCancellationHandler { try? await worker.value } onCancel: { worker.cancel() }
        }
        guard !Task.isCancelled else { return }
        comparison = snapshot
        difference = passages
        loading = false
    }

    private func refresh() {
        comparison = nil
        difference = nil
        loading = true
        refreshID = UUID()
    }

    private func deferAndClose() {
        store.deferExternalConflict()
        close()
    }

    private func resolve(reload: Bool) {
        guard !busy, let comparison else { return }
        busy = true
        Task {
            if await store.resolveExternalConflict(comparison, reloadingFromDisk: reload) {
                close()
            } else if !store.hasExternalConflict || store.offersLinkedSaveRepair {
                close()
            } else {
                message = settings.text(.conflictReviewAgain)
                refresh()
            }
            busy = false
        }
    }

    private func beginCopyNaming() {
        guard !busy, let url = store.fileURL, let request = store.externalConflictRequest else { return }
        let documentID = store.documentIdentity
        busy = true
        Task {
            defer { busy = false }
            let eligibility = await Task.detached(priority: .userInitiated) {
                DocumentCopyWriter.sourceEligibility(at: url)
            }.value
            guard store.hasExternalConflict, store.externalConflictRequest == request,
                  store.documentIdentity == documentID, store.fileURL == url else { return }
            switch eligibility {
            case .regular:
                message = nil
                copyName = DocumentCopyFlow.suggestedName(for: url, text: settings.text)
                namingCopy = true
            case .symbolicLink:
                message = String(format: settings.text(.conflictCopySymbolicLink), url.lastPathComponent)
            case .unavailable:
                message = settings.text(.copySourceUnavailable)
            }
        }
    }

    private func saveCopy() {
        guard !busy, let name = copyName else { return }
        busy = true
        Task {
            if await store.copyFlow.create(from: store, text: settings.text, chooseName: { _ in name }) != nil {
                deferAndClose()
            } else {
                message = store.copyFlow.detail ?? settings.text(.copyFailed)
            }
            busy = false
        }
    }
}

/// Bound each selectable text layout, including a single very long line or a
/// coarse comparison of thousands of blank lines. Consume Unicode scalars so
/// even a pathological grapheme cluster cannot make a page unbounded.
struct ConflictPassagePage {
    let text: String
    let next: String.Index?

    init(source: String, start: String.Index) {
        let scalars = source.unicodeScalars
        var end = start
        var breaks = 0
        for _ in 0..<2048 {
            guard end < source.endIndex, breaks < 40 else { break }
            let scalar = scalars[end]
            if scalar == "\n" || scalar == "\r" { breaks += 1 }
            scalars.formIndex(after: &end)
        }
        text = String(scalars[start..<end])
        next = end < source.endIndex ? end : nil
    }
}

private struct ConflictPassageText: View {
    let source: String
    let id: String
    let settings: AppSettings
    @State private var pageStarts: [String.Index] = []

    var body: some View {
        let page = ConflictPassagePage(source: source, start: pageStarts.last ?? source.startIndex)
        VStack(alignment: .leading, spacing: 4) {
            if !pageStarts.isEmpty || page.next != nil {
                HStack {
                    Button {
                        pageStarts.removeLast()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(pageStarts.isEmpty)
                    .accessibilityLabel(settings.text(.conflictPreviousPage))
                    Text(verbatim: String(format: settings.text(.conflictPage), pageStarts.count + 1))
                    Button {
                        if let next = page.next { pageStarts.append(next) }
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(page.next == nil)
                    .accessibilityLabel(settings.text(.conflictNextPage))
                    .accessibilityIdentifier("\(id)-next")
                }
                .font(.caption)
                .controlSize(.small)
            }
            Text(verbatim: page.text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(id)
        }
    }
}
