import MD2Core
import SwiftUI

struct SelectionStats: Sendable {
    let words: Int
    let characters: Int
}

struct DocumentStatusBar<RemoteImages: View>: View {
    let showsEditorPosition: Bool
    let editorSelection: EditorSelection?
    let stats: DocumentStats
    let selectionStats: SelectionStats?
    let url: URL?
    let format: MarkdownFileFormat
    let settings: AppSettings
    let convertingFormat: DocumentExportFormat?
    let conversionStoppedForSourceChange: Bool
    let cancelConversion: () -> Void
    let canReviewExternalConflict: Bool
    let reviewExternalConflict: () -> Void
    let remoteImages: RemoteImages

    @State private var showsInfo = false

    var body: some View {
        VStack(spacing: 0) {
            if conversionStoppedForSourceChange || canReviewExternalConflict {
                noticeRow
                Divider()
            }
            documentRow
        }
        .font(.caption)
        .monospacedDigit()
        .background(.bar)
    }

    private var documentRow: some View {
        HStack(spacing: 12) {
            if let convertingFormat {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(String(format: settings.text(.exportConversionProgress), convertingFormat.fileExtension.uppercased()))
                    .accessibilityIdentifier("document-export-progress")
                Button(settings.text(.cancel), action: cancelConversion)
                    .controlSize(.small)
                    .accessibilityIdentifier("cancel-export-conversion")
                Spacer(minLength: 0)
            } else {
                if showsEditorPosition {
                    Text(positionLabel)
                        .accessibilityIdentifier("document-caret-position")
                    if selectionStats != nil {
                        Text(selectionSummary)
                            .accessibilityIdentifier("document-selection-count")
                    } else {
                        Text(wordCount)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("document-word-count")
                    }
                } else {
                    Text(wordCount)
                        .accessibilityIdentifier("document-word-count")
                    Text("\(stats.readingMinutes) \(settings.text(.minRead))")
                        .accessibilityIdentifier("document-reading-time")
                }
                Spacer(minLength: 0)
                Button {
                    showsInfo.toggle()
                } label: {
                    Label(settings.text(.documentInfo), systemImage: "info.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("document-info")
                .popover(isPresented: $showsInfo, arrowEdge: .top) { info }
            }
            remoteImages
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    private var noticeRow: some View {
        HStack(spacing: 12) {
            if conversionStoppedForSourceChange {
                Text(settings.text(.alertConversionSourceChanged))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("document-export-interruption")
                Button(action: cancelConversion) {
                    Image(systemName: "xmark")
                        .frame(width: 22, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .help(settings.text(.close))
                .accessibilityLabel(settings.text(.close))
                .accessibilityIdentifier("dismiss-export-interruption")
            }
            Spacer(minLength: 0)
            if canReviewExternalConflict {
                Button(settings.text(.reviewExternalConflict), action: reviewExternalConflict)
                    .buttonStyle(.borderless)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("review-external-conflict")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(minHeight: 28)
    }

    private var positionLabel: String {
        if let count = editorSelection?.fragments.count, count > 1 {
            return String(format: settings.text(.statusSelectionRanges), count)
        }
        func label(_ position: EditorSourcePosition) -> String {
            String(format: settings.text(.statusPosition), position.line, position.column)
        }
        let start = editorSelection?.start ?? .start
        guard let end = editorSelection?.end, end != start else { return label(start) }
        return "\(label(start)) – \(label(end))"
    }

    private var wordCount: String {
        if let selectionStats {
            return "\(settings.text(.selectionStats)): \(selectionStats.words) / \(stats.words) \(settings.text(.words))"
        }
        return "\(stats.words) \(settings.text(.words))"
    }

    private var selectionSummary: String {
        guard let selectionStats else { return wordCount }
        return "\(wordCount) · \(selectionStats.characters) \(settings.text(.chars))"
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(settings.text(.documentInfo)).font(.headline)
            if let url {
                Text(settings.text(.documentPath)).foregroundStyle(.secondary)
                ScrollView {
                    Text(verbatim: url.path)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("document-info-path")
                }
                .frame(maxHeight: 110)
                .fixedSize(horizontal: false, vertical: true)
                Divider()
            }
            LabeledContent(settings.text(.documentEncoding)) {
                Text(format.encodingLabel).accessibilityIdentifier("document-info-encoding")
            }
            LabeledContent(settings.text(.documentLineEndings)) {
                Text(format.lineEnding == .mixed ? settings.text(.mixedLineEndings) : format.lineEnding.rawValue)
                    .accessibilityIdentifier("document-info-endings")
            }
            Divider()
            Text("\(stats.words) \(settings.text(.words)) · \(stats.characters) \(settings.text(.chars)) · \(stats.lines) \(settings.text(.lines))")
            Text("\(stats.readingMinutes) \(settings.text(.minRead))")
            LabeledContent(settings.text(.zoom), value: "\(settings.typography.zoomPercent)%")
        }
        .lineLimit(nil)
        .font(.callout)
        .padding(16)
        .frame(width: 348, alignment: .leading)
    }
}
