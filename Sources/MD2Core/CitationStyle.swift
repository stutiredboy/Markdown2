import Foundation

/// How the preview formats inline citations and orders the bibliography. Formal
/// CSL styling on export is delegated to Pandoc; this enum drives only the
/// lightweight in-preview rendering.
public enum CitationStyle: String, Sendable, Equatable, CaseIterable {
    /// `(Smith, 2023)` parenthetical / `Smith (2023)` in-text; bibliography
    /// ordered alphabetically by first author surname.
    case authorYear
    /// `[1]` bracketed numbers in first-citation order; bibliography ordered by
    /// that same citation order.
    case numeric
}
