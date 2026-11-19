import Foundation
import Testing
import MD2Core
@testable import MD2App

@Suite(.serialized)
struct LiteralReplacementPerformanceTests {
    @Test func quadruplingSourceDoesNotMultiplyAssemblyTimeBySixteen() {
        let chunk = "a normal paragraph in a long markdown file with a few common words\n"
        let replacement = "delta"
        func fixture(_ count: Int) -> (original: String, matches: [NSRange]) {
            let original = String(repeating: chunk, count: count) + "a"
            return (original, TextSearch.matches(of: "a", in: original))
        }

        func elapsed(_ fixture: (original: String, matches: [NSRange])) -> Duration {
            let start = ContinuousClock.now
            let actual = MarkdownEditorView.Coordinator.assembleLiteralReplacement(
                fixture.original, matches: fixture.matches, replacement: replacement
            )
            let duration = start.duration(to: .now)
            #expect(actual.utf16.count == fixture.original.utf16.count + fixture.matches.count * 4)
            return duration
        }

        _ = elapsed(fixture(10))
        let small = fixture(4_000)
        let large = fixture(16_000)
        var smallBest = elapsed(small)
        var largeBest = elapsed(large)
        for _ in 0..<2 {
            smallBest = min(smallBest, elapsed(small))
            largeBest = min(largeBest, elapsed(large))
        }
        print("Literal replacement assembly for \(small.original.utf8.count) and \(large.original.utf8.count) bytes took \(smallBest) and \(largeBest)")
        // Allow headroom for runner noise while rejecting quadratic growth.
        #expect(largeBest < smallBest * 8 + .milliseconds(2),
                "Replacement assembly for \(small.original.utf8.count) and \(large.original.utf8.count) bytes took \(smallBest) and \(largeBest)")
    }
}
