import AppKit

enum DocumentFont: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, serif, monospaced
    var id: String { rawValue }
    var label: L10nKey {
        switch self {
        case .system: .fontSystem
        case .serif: .fontSerif
        case .monospaced: .fontMonospaced
        }
    }
    @MainActor func font(size: CGFloat) -> NSFont {
        switch self {
        case .system: return NSFont.systemFont(ofSize: size)
        case .serif:
            let base = NSFont.systemFont(ofSize: size)
            return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        case .monospaced: return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }
    var css: String {
        switch self {
        case .system: "-apple-system, BlinkMacSystemFont, sans-serif"
        case .serif: "ui-serif, Georgia, 'Songti SC', serif"
        case .monospaced: "ui-monospace, 'SF Mono', Menlo, monospace"
        }
    }
}

enum ReadingWidth: String, Codable, CaseIterable, Identifiable, Sendable {
    case narrow, comfortable, wide, full
    var id: String { rawValue }
    var label: L10nKey {
        switch self {
        case .narrow: .readingNarrow
        case .comfortable: .readingComfortable
        case .wide: .readingWide
        case .full: .readingFull
        }
    }
    var css: String {
        switch self {
        case .narrow: "40em"
        case .comfortable: "50em"
        case .wide: "68.75em"
        case .full: "none"
        }
    }
}

/// Display preferences only; they never change document content or exports.
struct TypographySettings: Codable, Equatable, Sendable {
    var editorFont: DocumentFont = .system
    var readingFont: DocumentFont = .system
    var fontSize: Double = 16
    var zoom: Double = 1
    var readingWidth: ReadingWidth = .comfortable

    var normalized: Self {
        var value = self
        value.fontSize = fontSize.isFinite ? min(32, max(12, fontSize)) : 16
        value.zoom = zoom.isFinite ? min(2, max(0.5, zoom)) : 1
        return value
    }
    var effectiveFontSize: CGFloat { normalized.fontSize * normalized.zoom }
    var zoomPercent: Int { Int((normalized.zoom * 100).rounded()) }

    /// Injected into the preview only. Root size scales heading rem units too.
    var previewCSS: String {
        """
        html { font-size: \(effectiveFontSize)px !important; }
        body { font-size: 1rem !important; font-family: \(readingFont.css) !important; }
        main { max-width: \(readingWidth.css) !important; }
        """
    }
}
