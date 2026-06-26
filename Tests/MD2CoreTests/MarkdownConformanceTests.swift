import Testing
import Foundation
@testable import MD2Core

/// Task 4.3 / `markdown-conformance-suite`: the renderer's current behaviour on
/// the whole corpus is pinned against a checked-in baseline. Any boundary shift
/// — a `reference-match` that regresses, OR a divergence that starts matching —
/// fails this test until the baseline (and matrix) are updated.
struct MarkdownConformanceTests {
    @Test func baselinePinsCurrentBehaviour() throws {
        let results = try ConformanceRunner.run()
        let current = Dictionary(
            uniqueKeysWithValues: results.map { ($0.entry.id, $0.relationship.rawValue) }
        )

        // Regeneration entry point: rewrite the baseline from the current run.
        if ProcessInfo.processInfo.environment["MD2_REGENERATE_BASELINE"] != nil {
            try ConformanceBaseline.write(examples: current)
            return
        }

        let baseline = try ConformanceBaseline.load()

        // The baseline and corpus must describe the same set of examples.
        let currentIDs = Set(current.keys)
        let baselineIDs = Set(baseline.examples.keys)
        let missing = currentIDs.subtracting(baselineIDs)
        let extra = baselineIDs.subtracting(currentIDs)
        let missingList = missing.sorted().prefix(10).joined(separator: ", ")
        let extraList = extra.sorted().prefix(10).joined(separator: ", ")
        #expect(missing.isEmpty, "examples missing from baseline (regenerate): \(missingList)")
        #expect(extra.isEmpty, "stale baseline examples (regenerate): \(extraList)")

        // Catch both regressions and unexpected improvements.
        var drift: [String] = []
        for (id, relationship) in current where baseline.examples[id] != nil {
            if baseline.examples[id] != relationship {
                drift.append("\(id): baseline=\(baseline.examples[id]!) now=\(relationship)")
            }
        }
        let driftReport = drift.sorted().prefix(25).joined(separator: "\n")
        #expect(
            drift.isEmpty,
            "conformance drift (regenerate with MD2_REGENERATE_BASELINE=1):\n\(driftReport)"
        )
    }

    @Test func baselineUsesOnlyTheFourRelationshipValues() throws {
        let baseline = try ConformanceBaseline.load()
        let allowed = Set(["reference-match", "intentional-divergence", "known-incomplete", "unsupported"])
        for (id, relationship) in baseline.examples {
            #expect(allowed.contains(relationship), "\(id): illegal relationship \(relationship)")
        }
    }
}
