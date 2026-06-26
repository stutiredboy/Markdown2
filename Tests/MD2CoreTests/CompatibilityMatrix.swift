import Foundation

/// Locates source-tree test fixtures (matrix, baseline, generated reports) that
/// are read — and in the baseline's case rewritten — by the conformance suite.
/// These live next to the test sources and are `exclude`d from the target in
/// `Package.swift`, so they are addressed by path rather than bundled.
enum Fixtures {
    static func url(_ relativePath: String, file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }
}

/// The checked-in, machine-checkable compatibility matrix: the support contract
/// for Markdown2's renderer. See `markdown-compatibility-matrix` spec.
struct CompatibilityMatrix: Codable, Sendable {
    let matrixSchemaVersion: String
    let provenance: Provenance
    let entries: [Entry]

    struct Provenance: Codable, Sendable {
        let commonMark: Source
        let gfm: Source
        struct Source: Codable, Sendable {
            let source: String
            let version: String
            let license: String
        }
    }

    struct Entry: Codable, Sendable {
        let id: String
        let origin: String
        let sections: [String]
        let tier: String
        let baselineRelationship: String
        let declaredBehavior: String
        let boundary: String
        let docLabel: String
        let localTests: [String]?
    }

    static let supportTiers: Set<String> = ["Supported", "Best-effort", "Out-of-scope"]
    static let corpusRelationships: Set<String> = [
        "reference-match", "intentional-divergence", "known-incomplete", "unsupported"
    ]
    static let extensionRelationship = "not-in-corpus"
    static let extensionOrigin = "Markdown2 extension"

    static func load() throws -> CompatibilityMatrix {
        let data = try Data(contentsOf: Fixtures.url("Matrix/compatibility-matrix.json"))
        return try JSONDecoder().decode(CompatibilityMatrix.self, from: data)
    }

    /// Maps each covered corpus `section` to the entry that classifies it.
    func entryBySection() -> [String: Entry] {
        var map: [String: Entry] = [:]
        for entry in entries {
            for section in entry.sections {
                map[section] = entry
            }
        }
        return map
    }
}
