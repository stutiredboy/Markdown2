import Testing
import Foundation
@testable import MD2Core

/// Tasks 5.1 / 5.2 / `markdown-conformance-suite`: the dashboard groups by matrix
/// construct + tier, excludes Markdown2 extensions from the upstream pass-rate,
/// records inspectable failures, and writes to a known artifact path.
struct MarkdownConformanceDashboardTests {
    @Test func dashboardGroupsByMatrixConstructAndTierAndWritesReport() throws {
        let matrix = try CompatibilityMatrix.load()
        let results = try ConformanceRunner.run()
        let dashboard = ConformanceDashboard.build(results: results, matrix: matrix)
        try dashboard.write()
        print(dashboard.summaryLine())

        #expect(!dashboard.constructs.isEmpty)
        for construct in dashboard.constructs {
            #expect(CompatibilityMatrix.supportTiers.contains(construct.tier))
            #expect(construct.passed <= construct.total)
            #expect(construct.total > 0)
            #expect(construct.passRatePercent >= 0 && construct.passRatePercent <= 100)
        }

        // Every corpus-backed matrix construct appears exactly once, by id.
        let corpusConstructIDs = Set(matrix.entries.filter { !$0.sections.isEmpty }.map(\.id))
        #expect(Set(dashboard.constructs.map(\.id)) == corpusConstructIDs)

        // Overall upstream pass-rate is present and internally consistent.
        #expect(dashboard.overall.total == results.count)
        #expect(dashboard.overall.referenceMatch == results.filter(\.matches).count)

        // Written to the known artifact paths.
        #expect(FileManager.default.fileExists(atPath: ConformanceDashboard.markdownPath.path))
        #expect(FileManager.default.fileExists(atPath: ConformanceDashboard.jsonPath.path))
    }

    @Test func extensionsAreExcludedFromUpstreamPassRate() throws {
        let matrix = try CompatibilityMatrix.load()
        let results = try ConformanceRunner.run()
        let dashboard = ConformanceDashboard.build(results: results, matrix: matrix)

        let extensionIDs = Set(
            matrix.entries.filter { $0.origin == CompatibilityMatrix.extensionOrigin }.map(\.id)
        )
        #expect(!dashboard.extensions.isEmpty)
        #expect(Set(dashboard.extensions.map(\.id)) == extensionIDs)
        // No extension id leaks into the corpus-backed rows or the pass-rate.
        #expect(Set(dashboard.constructs.map(\.id)).isDisjoint(with: extensionIDs))
        #expect(dashboard.overall.total == results.count)
    }

    @Test func everyFailureRecordsSourceExpectedAndActual() throws {
        let matrix = try CompatibilityMatrix.load()
        let results = try ConformanceRunner.run()
        let dashboard = ConformanceDashboard.build(results: results, matrix: matrix)

        #expect(dashboard.failures.count == results.filter { !$0.matches }.count)
        for failure in dashboard.failures {
            // A recorded failure carries its construct, section, and expected vs
            // actual HTML (which differ — that is why it is a failure).
            #expect(!failure.construct.isEmpty)
            #expect(!failure.section.isEmpty)
            #expect(failure.reference != failure.rendered)
        }
    }
}
