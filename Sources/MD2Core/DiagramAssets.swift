import Foundation

/// Loads the bundled, self-contained diagram engine scripts used to render
/// `mermaid`, `flow`, and `sequence` fenced blocks in the Read-mode preview.
///
/// Like ``MathAssets``, the JavaScript is the standard distribution of each
/// engine and is inlined directly into the generated preview HTML so it resolves
/// under the `loadFileURL` preview path without any network access.
///
/// Load order matters: shared dependencies (`underscore`, `raphael`) must be
/// emitted before the engines that consume them (`flowchart`, `sequence`).
/// `mermaid` is self-contained and can be emitted independently. See
/// `Resources/diagrams/VERSIONS.md` for the pinned versions.
enum DiagramAssets {
    /// Underscore — required by js-sequence-diagrams.
    static let underscore: String = load("underscore.min")

    /// Raphael — required by flowchart.js and the js-sequence-diagrams `simple` theme.
    static let raphael: String = load("raphael.min")

    /// flowchart.js (provides the global `flowchart`). Depends on `raphael`.
    static let flowchart: String = load("flowchart.min")

    /// js-sequence-diagrams (provides the global `Diagram`). Depends on
    /// `underscore` and `raphael`.
    static let sequence: String = load("sequence-diagram.min")

    /// Mermaid (provides the global `mermaid`). Self-contained.
    static let mermaid: String = load("mermaid.min")

    private static func load(_ name: String) -> String {
        guard let url = MD2CoreResources.bundle.url(
            forResource: name,
            withExtension: "js",
            subdirectory: "diagrams"
        ), let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return contents
    }
}
