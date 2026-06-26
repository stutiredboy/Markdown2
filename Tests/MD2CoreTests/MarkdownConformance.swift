import Foundation
@testable import MD2Core

/// An example's relationship to the upstream reference HTML. Distinct from the
/// construct's support *tier* (see `markdown-compatibility-matrix`).
enum ConformanceRelationship: String, Sendable {
    case referenceMatch = "reference-match"
    case intentionalDivergence = "intentional-divergence"
    case knownIncomplete = "known-incomplete"
    case unsupported = "unsupported"
}

/// One example rendered and compared against its reference.
struct ConformanceResult: Sendable {
    let entry: CorpusEntry
    let matches: Bool
    let relationship: ConformanceRelationship
    let rendered: String
    let reference: String
    /// The matrix construct id that classifies this example's section.
    let constructID: String
    let tier: String
}

enum ConformanceRunner {
    /// Renders every corpus example, normalises, compares to the reference, and
    /// derives each example's baseline relationship from the match result and
    /// the matrix's section-level relationship.
    static func run() throws -> [ConformanceResult] {
        let matrix = try CompatibilityMatrix.load()
        let bySection = matrix.entryBySection()
        let renderer = MarkdownRenderer()

        return try ConformanceCorpus.load().map { entry in
            let rendered = ConformanceHTML.normalize(renderer.render(entry.example.markdown).body)
            let reference = ConformanceHTML.normalize(entry.example.html)
            let matches = rendered == reference
            let matrixEntry = bySection[entry.section]
            let relationship = relationship(matches: matches, sectionRelationship: matrixEntry?.baselineRelationship)
            return ConformanceResult(
                entry: entry,
                matches: matches,
                relationship: relationship,
                rendered: rendered,
                reference: reference,
                constructID: matrixEntry?.id ?? "unclassified",
                tier: matrixEntry?.tier ?? "unclassified"
            )
        }
    }

    /// A matching example is `reference-match`. A diverging example takes the
    /// matrix's declared divergence kind for its section; a section the matrix
    /// expects to match (`reference-match`) but that diverges here is
    /// `known-incomplete`.
    static func relationship(matches: Bool, sectionRelationship: String?) -> ConformanceRelationship {
        if matches { return .referenceMatch }
        switch sectionRelationship {
        case "intentional-divergence": return .intentionalDivergence
        case "unsupported": return .unsupported
        default: return .knownIncomplete
        }
    }
}

/// The checked-in baseline: corpus example id → relationship. Read for the
/// pinning test; rewritten when regenerating.
struct ConformanceBaseline: Codable, Sendable {
    var description: String
    var examples: [String: String]

    static let path = Fixtures.url("Conformance/baseline.json")
    static let defaultDescription =
        "Conformance baseline for markdown-conformance-suite. Each corpus example id maps to its "
        + "relationship to the upstream reference: reference-match | intentional-divergence | "
        + "known-incomplete | unsupported. Generated from a renderer run; regenerate by setting "
        + "MD2_REGENERATE_BASELINE=1 when running MarkdownConformanceTests."

    static func load() throws -> ConformanceBaseline {
        try JSONDecoder().decode(ConformanceBaseline.self, from: Data(contentsOf: path))
    }

    static func write(examples: [String: String]) throws {
        let baseline = ConformanceBaseline(description: defaultDescription, examples: examples)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(baseline)
        data.append(0x0A)
        try data.write(to: path)
    }
}
