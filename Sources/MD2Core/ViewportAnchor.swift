import Foundation

/// The viewport context captured from the surface the user is leaving on a
/// Write↔Read mode switch, applied to the surface they are entering.
///
/// Unlike the heading-only ``ModeSwitchAnchor`` cases, a viewport anchor
/// carries the source-line span of the block nearest the top of the outgoing
/// viewport plus the position *inside* that block, so long sections, code
/// fences, and sparse-heading documents land on the content the user was
/// actually reading rather than on the preceding section heading. The heading
/// id and proportional scroll fraction remain as fallbacks for content whose
/// block metadata cannot be resolved.
public struct ViewportAnchor: Equatable, Sendable {
    /// The UTF-16 start of a visual source row and the viewport's offset from
    /// that row. Available only when the anchor came from the native editor.
    public struct EditorPosition: Equatable, Sendable {
        public let characterIndex: Int
        public let verticalOffset: Double

        public init(characterIndex: Int, verticalOffset: Double) {
            self.characterIndex = characterIndex
            self.verticalOffset = verticalOffset
        }
    }

    /// 1-based first source line of the anchored block (or the exact top
    /// visible editor line). `nil` when no source-line anchor is available and
    /// only the fallbacks apply.
    public var sourceLine: Int?
    /// 1-based last source line of the anchored block, when the renderer knows
    /// the span. `nil` means the span is just `sourceLine`.
    public var sourceEndLine: Int?
    /// How far into the anchored block the viewport top sat, 0...1.
    public var intraBlockProgress: Double
    /// Distance in points from the viewport top to the anchored content's top
    /// when captured, kept so destinations can preserve a little breathing room
    /// instead of pinning content flush against the edge.
    public var viewportTopInset: Double
    /// Proportional scroll position (0...1) of the outgoing viewport; the last
    /// fallback when neither block nor heading anchors resolve.
    public var scrollFraction: Double
    /// The section heading id at/above the captured position, used when block
    /// metadata is unavailable on the destination.
    public var fallbackHeadingID: String?
    public var editorPosition: EditorPosition?

    public init(
        sourceLine: Int? = nil,
        sourceEndLine: Int? = nil,
        intraBlockProgress: Double = 0,
        viewportTopInset: Double = 0,
        scrollFraction: Double = 0,
        fallbackHeadingID: String? = nil,
        editorPosition: EditorPosition? = nil
    ) {
        self.sourceLine = sourceLine
        self.sourceEndLine = sourceEndLine
        self.intraBlockProgress = clampedUnitProgress(intraBlockProgress)
        self.viewportTopInset = viewportTopInset.isFinite ? max(0, viewportTopInset) : 0
        self.scrollFraction = clampedUnitProgress(scrollFraction)
        self.fallbackHeadingID = fallbackHeadingID
        self.editorPosition = editorPosition
    }

    /// The single source line this anchor targets on the destination: the
    /// block's start line advanced by the intra-block progress across the
    /// span. `nil` when the anchor has no source line at all.
    public var targetSourceLine: Int? {
        sourceLine.map {
            resolvedSourceLine(start: $0, end: sourceEndLine, progress: intraBlockProgress)
        }
    }
}

/// Clamps an intra-block progress (or scroll fraction) to 0...1, mapping
/// non-finite input to 0 so a bad measurement can never poison a scroll target.
public func clampedUnitProgress(_ progress: Double) -> Double {
    guard progress.isFinite else { return 0 }
    return min(max(progress, 0), 1)
}

/// Resolves the target source line inside a block span: the 1-based `start`
/// line advanced by `progress` (0...1) across `start...end`. A missing or
/// malformed end (`end <= start`) collapses to the start line, and the result
/// is always clamped inside the span so a stale progress value cannot escape
/// the block.
public func resolvedSourceLine(start: Int, end: Int?, progress: Double) -> Int {
    let first = max(1, start)
    guard let end, end > first else { return first }
    let clamped = clampedUnitProgress(progress)
    let advanced = first + Int((clamped * Double(end - first)).rounded())
    return min(max(advanced, first), end)
}
