import Testing
import Foundation
@testable import MD2Core

/// Task 8 / `markdown-compatibility-matrix`: out-of-scope, unterminated, or
/// malformed input degrades to readable content — never blanking the preview,
/// dropping authored text, or crashing.
struct GracefulDegradationTests {
    private let renderer = MarkdownRenderer()

    @Test func rendererNeverBlanksContentTheReferenceRenders() throws {
        var blanked: [String] = []
        for entry in try ConformanceCorpus.load() {
            let body = renderer.render(entry.example.markdown).body
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let referenceHasContent = !entry.example.html
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if referenceHasContent && body.isEmpty {
                blanked.append(entry.id)
            }
        }
        // Completing the loop also proves no example crashes or hangs the renderer.
        let report = blanked.prefix(20).joined(separator: ", ")
        #expect(blanked.isEmpty, "examples that blanked content the reference renders: \(report)")
    }

    @Test func unterminatedFencedCodeBlockKeepsContent() {
        let body = renderer.render("# Title\n\n```swift\nlet answer = 42\nstill here").body
        #expect(!body.isEmpty)
        #expect(body.contains("Title"))
        // Strip tags so syntax-highlighting spans don't break the text check.
        let text = body.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        #expect(text.contains("let answer = 42"))
        #expect(text.contains("still here"))
    }

    @Test func malformedPipeTableIsNotBlanked() {
        // A ragged table: the body row has fewer cells than the header.
        let body = renderer.render("| a | b |\n| --- | --- |\n| 1 |").body
        #expect(!body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(body.contains("a"))
        #expect(body.contains("1"))
    }

    @Test func unsafeRawHTMLIsRenderedInert() {
        let body = renderer.render("before <script>alert(1)</script> after").body
        #expect(body.contains("&lt;script&gt;"))
        #expect(!body.contains("<script>"))
        #expect(body.contains("before"))
        #expect(body.contains("after"))
    }

    @Test func outOfScopeConstructDegradesToText() {
        // Reference-style links are out of scope; their text must still appear.
        let body = renderer.render("See [the link][ref] for details.\n\n[ref]: https://example.com").body
        #expect(body.contains("the link"))
        #expect(body.contains("details"))
    }
}
