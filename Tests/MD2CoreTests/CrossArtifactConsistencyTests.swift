import Testing
import Foundation
@testable import MD2Core

/// Task 9.2 / `markdown-compatibility-matrix`: the matrix, baseline, dashboard,
/// and `Docs/` stay reconciled. A tier or behaviour change in the matrix that is
/// not reflected in the generated doc — or a baseline that contradicts the
/// matrix headline — fails here.
struct CrossArtifactConsistencyTests {
    @Test func generatedMatrixDocIsCommittedAndCurrent() throws {
        let matrix = try CompatibilityMatrix.load()
        let expected = CompatibilityMatrixDoc.render(matrix)

        if ProcessInfo.processInfo.environment["MD2_REGENERATE_DOCS"] != nil {
            try expected.data(using: .utf8)!.write(to: CompatibilityMatrixDoc.path)
            return
        }

        let committed = (try? String(contentsOf: CompatibilityMatrixDoc.path, encoding: .utf8)) ?? ""
        #expect(
            committed == expected,
            "Docs/CompatibilityMatrix.md is stale; regenerate with MD2_REGENERATE_DOCS=1 (tier drift caught)"
        )
    }

    @Test func dashboardCategoriesAreMatrixConstructs() throws {
        let matrix = try CompatibilityMatrix.load()
        let dashboard = ConformanceDashboard.build(results: try ConformanceRunner.run(), matrix: matrix)
        let matrixIDs = Set(matrix.entries.map(\.id))

        for construct in dashboard.constructs {
            #expect(matrixIDs.contains(construct.id), "dashboard construct \(construct.id) not in matrix")
        }
        for ext in dashboard.extensions {
            #expect(matrixIDs.contains(ext.id), "dashboard extension \(ext.id) not in matrix")
        }
    }

    @Test func matrixHeadlineRelationshipOccursInBaseline() throws {
        let matrix = try CompatibilityMatrix.load()
        let byConstruct = Dictionary(grouping: try ConformanceRunner.run(), by: \.constructID)

        for entry in matrix.entries where !entry.sections.isEmpty {
            let actual = Set((byConstruct[entry.id] ?? []).map { $0.relationship.rawValue })
            #expect(
                actual.contains(entry.baselineRelationship),
                "\(entry.id): matrix headline \(entry.baselineRelationship) absent from baseline \(actual.sorted())"
            )
        }
    }

    @Test func supportDocPointsAtTheMatrix() throws {
        let supportDoc = try String(
            contentsOf: Fixtures.url("../../Docs/MarkdownSupport.md"),
            encoding: .utf8
        )
        #expect(supportDoc.contains("CompatibilityMatrix.md"),
                "Docs/MarkdownSupport.md should reference the authoritative CompatibilityMatrix.md")
    }

    @Test func outOfScopeConstructsAreNotAdvertisedAsSupported() throws {
        for entry in try CompatibilityMatrix.load().entries where entry.tier == "Out-of-scope" {
            #expect(entry.docLabel != "Supported", "\(entry.id) is Out-of-scope but docLabel is Supported")
        }
    }
}
