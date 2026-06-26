import Testing
import Foundation
@testable import MD2Core

/// Task 2.3 / `markdown-compatibility-matrix`: the matrix is a complete,
/// machine-checkable contract that is total over the corpus.
struct CompatibilityMatrixTests {
    @Test func everyEntryIsSchemaComplete() throws {
        let matrix = try CompatibilityMatrix.load()
        #expect(!matrix.matrixSchemaVersion.isEmpty)

        for entry in matrix.entries {
            #expect(!entry.id.isEmpty)
            #expect(!entry.origin.isEmpty)
            #expect(CompatibilityMatrix.supportTiers.contains(entry.tier), "bad tier for \(entry.id): \(entry.tier)")
            #expect(!entry.declaredBehavior.isEmpty, "missing declaredBehavior for \(entry.id)")
            #expect(!entry.boundary.isEmpty, "missing boundary for \(entry.id)")
            #expect(!entry.docLabel.isEmpty, "missing docLabel for \(entry.id)")

            if entry.origin == CompatibilityMatrix.extensionOrigin {
                #expect(entry.baselineRelationship == CompatibilityMatrix.extensionRelationship)
                #expect(entry.sections.isEmpty, "extension \(entry.id) should not claim corpus sections")
                #expect(!(entry.localTests ?? []).isEmpty, "extension \(entry.id) must reference local tests")
            } else {
                #expect(CompatibilityMatrix.corpusRelationships.contains(entry.baselineRelationship),
                        "bad relationship for \(entry.id): \(entry.baselineRelationship)")
                #expect(!entry.sections.isEmpty, "corpus entry \(entry.id) must cover at least one section")
            }
        }
    }

    @Test func entryIdsAreUnique() throws {
        let ids = try CompatibilityMatrix.load().entries.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func provenanceIsPinned() throws {
        let p = try CompatibilityMatrix.load().provenance
        for src in [p.commonMark, p.gfm] {
            #expect(src.source.hasPrefix("http"))
            #expect(!src.version.isEmpty)
            #expect(src.license.contains("CC-BY-SA"))
        }
    }

    @Test func matrixIsTotalOverCorpusSections() throws {
        let matrix = try CompatibilityMatrix.load()
        let bySection = matrix.entryBySection()
        let corpusSections = try Set(ConformanceCorpus.sections())

        // Totality: every corpus section is classified. A new/renamed corpus
        // section that is not in the matrix fails here (the intended signal).
        let unclassified = corpusSections.subtracting(bySection.keys)
        #expect(unclassified.isEmpty, "unclassified corpus sections: \(unclassified.sorted())")

        // No stale matrix entries pointing at sections absent from the corpus.
        let stale = Set(bySection.keys).subtracting(corpusSections)
        #expect(stale.isEmpty, "matrix references sections absent from corpus: \(stale.sorted())")
    }

    @Test func eachCorpusSectionMapsToExactlyOneEntry() throws {
        let matrix = try CompatibilityMatrix.load()
        var ownerCount: [String: Int] = [:]
        for entry in matrix.entries {
            for section in entry.sections { ownerCount[section, default: 0] += 1 }
        }
        for (section, count) in ownerCount {
            #expect(count == 1, "section '\(section)' classified by \(count) entries")
        }
    }

    @Test func advertisedMarkdown2ExtensionsAreClassified() throws {
        let extensionIds = Set(
            try CompatibilityMatrix.load().entries
                .filter { $0.origin == CompatibilityMatrix.extensionOrigin }
                .map(\.id)
        )
        // The extensions Docs/MarkdownSupport.md advertises beyond CommonMark/GFM.
        let required = ["front-matter", "toc", "tex-math", "diagrams",
                        "footnotes", "image-size-attributes", "image-attachments"]
        for id in required {
            #expect(extensionIds.contains(id), "missing Markdown2 extension entry: \(id)")
        }
    }

    @Test func tierAndRelationshipAreCoherent() throws {
        for entry in try CompatibilityMatrix.load().entries {
            if entry.baselineRelationship == "reference-match" {
                #expect(entry.tier == "Supported", "\(entry.id): reference-match but tier \(entry.tier)")
            }
            if entry.baselineRelationship == "unsupported" {
                #expect(entry.tier == "Out-of-scope", "\(entry.id): unsupported but tier \(entry.tier)")
            }
            if entry.tier == "Out-of-scope" {
                #expect(["unsupported", CompatibilityMatrix.extensionRelationship].contains(entry.baselineRelationship),
                        "\(entry.id): out-of-scope but relationship \(entry.baselineRelationship)")
            }
        }
    }
}
