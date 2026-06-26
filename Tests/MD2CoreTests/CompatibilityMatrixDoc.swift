import Foundation

/// Renders the human-facing `Docs/CompatibilityMatrix.md` from the matrix data
/// artifact, so the published support contract cannot drift from the matrix that
/// the conformance suite enforces. The file is generated, not hand-edited.
enum CompatibilityMatrixDoc {
    static let path = Fixtures.url("../../Docs/CompatibilityMatrix.md")

    static func render(_ matrix: CompatibilityMatrix) -> String {
        var lines: [String] = []
        lines.append("# Markdown2 compatibility matrix")
        lines.append("")
        lines.append("> Generated from `Tests/MD2CoreTests/Matrix/compatibility-matrix.json` "
            + "(schema \(matrix.matrixSchemaVersion)). This is the source-of-truth support contract "
            + "for Markdown2's renderer; it is enforced by the conformance suite. **Do not edit by "
            + "hand** — regenerate with `MD2_REGENERATE_DOCS=1 swift test --filter CrossArtifactConsistencyTests`.")
        lines.append("")
        lines.append("Support tiers: **Supported** (intentionally interpreted, stable shape), "
            + "**Best-effort** (useful but with known incomplete edges), **Out-of-scope** "
            + "(not interpreted; authored text is preserved). Upstream reference match is tracked "
            + "separately by the conformance dashboard and is not a 100% target.")
        lines.append("")

        appendSection(&lines, title: "CommonMark", origin: "CommonMark", matrix: matrix)
        appendSection(&lines, title: "GFM extensions", origin: "GFM", matrix: matrix)
        appendSection(&lines, title: "Markdown2 extensions", origin: CompatibilityMatrix.extensionOrigin, matrix: matrix)

        lines.append("Corpus provenance: CommonMark \(matrix.provenance.commonMark.version) "
            + "(\(matrix.provenance.commonMark.license)); GFM \(matrix.provenance.gfm.version) "
            + "(\(matrix.provenance.gfm.license)).")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func appendSection(
        _ lines: inout [String],
        title: String,
        origin: String,
        matrix: CompatibilityMatrix
    ) {
        let entries = matrix.entries.filter { $0.origin == origin }
        guard !entries.isEmpty else { return }
        lines.append("## \(title)")
        lines.append("")
        lines.append("| Construct | Tier | Declared behaviour | Boundary |")
        lines.append("| --- | --- | --- | --- |")
        for entry in entries {
            lines.append("| \(entry.id) | \(entry.tier) | \(escape(entry.declaredBehavior)) | \(escape(entry.boundary)) |")
        }
        lines.append("")
    }

    /// Escapes pipes and newlines so cell content stays inside the table cell.
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
