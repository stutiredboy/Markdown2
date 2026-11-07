import Foundation
import Testing
@testable import MD2Core

@Suite(.serialized)
struct BlockRenderingPerformanceTests {
    /// A blank run before a valid list continuation used to rescan its entire
    /// remaining suffix from every blank line, once per structural pre-scan.
    /// Pin both scaling and the following heading/reference/source metadata.
    @Test func doublingBlankRunDoesNotQuadruple() throws {
        let renderer = MarkdownRenderer()
        let workload = BlockScalingWorkload.blankRun
        let small = workload.document(count: 1_000)
        let large = workload.document(count: 2_000)
        _ = renderer.render(workload.document(count: 16), assetMode: .appScheme)

        func elapsed(_ source: String) -> Double {
            let start = ContinuousClock.now
            _ = renderer.render(source, assetMode: .appScheme)
            let components = start.duration(to: .now).components
            return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
        }

        var smallMS = elapsed(small)
        // gstack-timing-ok: fail-fast ceiling bounds CI work if the scan regresses
        try #require(smallMS < 1_500, "1,000 blank lines took \(smallMS) ms")
        var largeMS = Double.infinity
        // Alternate sizes and repeat a failed window, as the inline guards do.
        for round in 0..<10 {
            if round == 5, largeMS < smallMS * 3 + 2 { break }
            if round > 0 { smallMS = min(smallMS, elapsed(small)) }
            largeMS = min(largeMS, elapsed(large))
        }
        // gstack-timing-ok: quadratic guard, not a machine-specific speed target
        #expect(largeMS < smallMS * 3 + 2,
                "blank-run scaling: 1,000=\(smallMS) ms, 2,000=\(largeMS) ms")
        // gstack-timing-ok: absolute ceiling bounds a persistent regression
        #expect(largeMS < 3_000)
        let result = renderer.render(large, assetMode: .appScheme)
        #expect(workload.matches(result.body, headingCount: result.outline.count, count: 2_000))
        #expect(!result.body.contains("data-md2-task-line"))
    }
}
