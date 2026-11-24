import MD2Core
import SwiftUI

enum FloatingOutlineLayout {
    static let width: CGFloat = 188
    static let trailingInset: CGFloat = 24
    static let minimumMargin: CGFloat = width + trailingInset + 8

    static func showsLeftOutline(
        standaloneOutline: Bool,
        folderSection: FolderSidebarState.Section?,
        folderSidebarVisible: Bool
    ) -> Bool {
        if let folderSection {
            return folderSidebarVisible && folderSection == .outline
        }
        return standaloneOutline
    }

    static func isVisible(
        mode: EditorMode,
        hasHeadings: Bool,
        showsLeftOutline: Bool,
        previewWidth: CGFloat,
        typography: TypographySettings,
        measuredMargin: CGFloat?
    ) -> Bool {
        guard mode == .read, hasHeadings, !showsLeftOutline,
              let widthInEms = typography.readingWidth.maximumWidthInEms else { return false }
        // The preview's centered <main> is border-box, including its padding.
        let maximumMainWidth = widthInEms * typography.effectiveFontSize
        return (previewWidth - maximumMainWidth) / 2 >= minimumMargin
            && (measuredMargin ?? 0) >= minimumMargin
    }
}

struct FloatingOutline: View {
    let headings: [Heading]
    let selectedHeadingID: String?
    let settings: AppSettings
    let viewportHeight: CGFloat
    let onSelect: (Heading) -> Void
    private let rowHeight: CGFloat = 24
    private let rowSpacing: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(settings.text(.outline))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: rowSpacing) {
                        rows
                    }
                }
                .frame(height: min(rowsHeight, viewportHeight * 0.65, 440))
                .onChange(of: selectedHeadingID, initial: true) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
        .padding(8)
        .frame(width: FloatingOutlineLayout.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(settings.text(.outline))
        .accessibilityIdentifier("floating-outline")
    }

    private var rowsHeight: CGFloat {
        rowHeight * CGFloat(headings.count) + rowSpacing * CGFloat(max(0, headings.count - 1))
    }

    private var rows: some View {
        ForEach(headings) { heading in
            let selected = heading.id == selectedHeadingID
            Button { onSelect(heading) } label: {
                Text(heading.title)
                    .font(heading.level == 1 ? .callout.weight(.semibold) : .callout)
                    .lineLimit(1)
                    .padding(.leading, CGFloat(max(0, heading.level - 1)) * 9)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(selected ? .primary : .secondary)
            .background(Color.accentColor.opacity(selected ? 0.15 : 0), in: RoundedRectangle(cornerRadius: 4))
            .help(heading.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityHint(settings.text(.navigateToHeading))
            .id(heading.id)
        }
    }
}
