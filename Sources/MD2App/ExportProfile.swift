import CoreGraphics
import Foundation

/// User-configurable page geometry and running-text settings for PDF export and
/// print. A pure value type (Foundation + CoreGraphics only) so geometry
/// resolution and token substitution are unit-testable without an offscreen
/// render. `AppSettings` persists it; `PDFExporter`/`PDFPaginator` derive their
/// page rect and margins from it. The `default` reproduces the app's previous
/// fixed output (A4 portrait, narrow margins, no page numbers or headers/footers),
/// so existing exports are unchanged unless the user opts in.
struct ExportProfile: Codable, Equatable, Sendable {
    var pageSize: PageSize
    var orientation: PageOrientation
    var margins: PageMargins
    /// Draw an automatic page number in the footer at `pageNumberAlignment`.
    var showsPageNumbers: Bool
    var pageNumberAlignment: PageZone
    /// Running header text per zone; an empty zone is not drawn.
    var header: RunningText
    /// Running footer text per zone; an empty zone is not drawn.
    var footer: RunningText
    /// Point size for header/footer/page-number text.
    var runningTextFontSize: CGFloat

    init(
        pageSize: PageSize = .a4,
        orientation: PageOrientation = .portrait,
        margins: PageMargins = .preset(.narrow),
        showsPageNumbers: Bool = false,
        pageNumberAlignment: PageZone = .center,
        header: RunningText = RunningText(),
        footer: RunningText = RunningText(),
        runningTextFontSize: CGFloat = 9
    ) {
        self.pageSize = pageSize
        self.orientation = orientation
        self.margins = margins
        self.showsPageNumbers = showsPageNumbers
        self.pageNumberAlignment = pageNumberAlignment
        self.header = header
        self.footer = footer
        self.runningTextFontSize = runningTextFontSize
    }

    /// The previous fixed export behavior: A4 portrait, narrow margins, no running
    /// text. Used as the first-launch default so output is unchanged by default.
    static let `default` = ExportProfile()

    /// Page rectangle size in points (PDF user space), accounting for orientation.
    var pageSizePoints: CGSize {
        let portrait = pageSize.portraitPoints
        switch orientation {
        case .portrait:
            return portrait
        case .landscape:
            return CGSize(width: portrait.height, height: portrait.width)
        }
    }

    /// Resolved per-side margins in points.
    var marginInsets: EdgeInsetsPoints {
        margins.insets
    }

    /// Whether any running text (a header/footer zone or the page number) is
    /// active, i.e. whether the exporter must reserve a margin band for it.
    var hasRunningText: Bool {
        showsPageNumbers || !header.isEmpty || !footer.isEmpty
    }
}

/// Page size presets, resolved to point dimensions at 72 dpi (PDF user-space
/// units). Portrait orientation; `ExportProfile` applies landscape by swapping.
enum PageSize: String, CaseIterable, Codable, Sendable, Identifiable {
    case a4
    case letter
    case legal

    var id: String { rawValue }

    /// Portrait size in points (width ≤ height).
    var portraitPoints: CGSize {
        switch self {
        case .a4:
            // 210 × 297 mm at 72 dpi.
            return CGSize(width: 595.28, height: 841.89)
        case .letter:
            // 8.5 × 11 in.
            return CGSize(width: 612, height: 792)
        case .legal:
            // 8.5 × 14 in.
            return CGSize(width: 612, height: 1008)
        }
    }
}

enum PageOrientation: String, CaseIterable, Codable, Sendable, Identifiable {
    case portrait
    case landscape

    var id: String { rawValue }
}

/// Per-side page margins in points, in PDF/CoreGraphics coordinate order.
struct EdgeInsetsPoints: Equatable, Sendable {
    var top: CGFloat
    var left: CGFloat
    var bottom: CGFloat
    var right: CGFloat
}

/// Page margins via a named preset or explicit per-side custom values.
enum PageMargins: Codable, Equatable, Sendable {
    case preset(MarginPreset)
    case custom(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat)

    /// Named uniform margin presets.
    enum MarginPreset: String, CaseIterable, Codable, Sendable, Identifiable {
        case none
        case narrow
        case normal
        case wide

        var id: String { rawValue }

        /// Uniform margin in points.
        var points: CGFloat {
            switch self {
            case .none: return 0
            case .narrow: return 36   // 0.5"
            case .normal: return 72   // 1"
            case .wide: return 108    // 1.5"
            }
        }
    }

    /// Resolved per-side insets in points. Custom values are clamped to be
    /// non-negative so a malformed profile can never produce inverted geometry.
    var insets: EdgeInsetsPoints {
        switch self {
        case let .preset(preset):
            let p = preset.points
            return EdgeInsetsPoints(top: p, left: p, bottom: p, right: p)
        case let .custom(top, left, bottom, right):
            return EdgeInsetsPoints(
                top: max(0, top),
                left: max(0, left),
                bottom: max(0, bottom),
                right: max(0, right)
            )
        }
    }
}

/// A horizontal placement zone within a running header/footer line.
enum PageZone: String, CaseIterable, Codable, Sendable, Identifiable {
    case left
    case center
    case right

    var id: String { rawValue }
}

/// Text for the three zones of a running header or footer line. Each zone may
/// contain substitution tokens (see `RunningTextToken`); an empty string means
/// that zone is not drawn.
struct RunningText: Codable, Equatable, Sendable {
    var left: String
    var center: String
    var right: String

    init(left: String = "", center: String = "", right: String = "") {
        self.left = left
        self.center = center
        self.right = right
    }

    var isEmpty: Bool {
        left.isEmpty && center.isEmpty && right.isEmpty
    }

    /// The template for a given zone.
    func text(for zone: PageZone) -> String {
        switch zone {
        case .left: return left
        case .center: return center
        case .right: return right
        }
    }
}

/// Concrete values substituted into header/footer templates for one page.
struct RunningTextContext: Equatable, Sendable {
    var title: String
    /// A pre-formatted, locale-aware date string supplied by the caller.
    var date: String
    var page: Int
    var pageCount: Int

    init(title: String, date: String, page: Int, pageCount: Int) {
        self.title = title
        self.date = date
        self.page = page
        self.pageCount = pageCount
    }
}

/// Pure substitution of `{title}`, `{date}`, `{page}`, and `{pageCount}` tokens in
/// a running-text template. Deterministic and side-effect-free so it is fully
/// unit-testable; the caller resolves the locale-aware date before calling.
enum RunningTextToken {
    static func resolve(_ template: String, with context: RunningTextContext) -> String {
        var result = template
        result = result.replacingOccurrences(of: "{title}", with: context.title)
        result = result.replacingOccurrences(of: "{date}", with: context.date)
        result = result.replacingOccurrences(of: "{page}", with: String(context.page))
        result = result.replacingOccurrences(of: "{pageCount}", with: String(context.pageCount))
        return result
    }
}
