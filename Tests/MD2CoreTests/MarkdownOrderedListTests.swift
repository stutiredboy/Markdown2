import Foundation
import Testing
@testable import MD2App
@testable import MD2Core

struct MarkdownOrderedListTests {
    @Test(arguments: [("0. step", "0"), ("003) step", "3"), ("123456789. step", "123456789")])
    func firstMarkerSetsTheDisplayedNumber(_ example: (marker: String, start: String)) {
        let body = MarkdownRenderer().render(example.marker + "\n\n1. next").body
        #expect(body.withoutSourceLineMetadata == "<ol start=\"\(example.start)\">\n<li>step</li>\n<li>next</li>\n</ol>")
        #expect(body.contains("data-md2-source-line=\"1\" data-md2-source-end-line=\"3\""))
        #expect(body.contains("<li data-md2-source-line=\"3\">next</li>"))
    }

    @Test func nestedOrderedListKeepsItsOwnStartAndSourceSpans() {
        let source = "- Recover\n  10) Restore\n  11) Validate\n- Report"
        let body = MarkdownRenderer().render(source).body
        #expect(body.withoutSourceLineMetadata == "<ul>\n<li>Recover\n<ol start=\"10\">\n<li>Restore</li>\n<li>Validate</li>\n</ol></li>\n<li>Report</li>\n</ul>")
        #expect(body.contains("<li data-md2-source-line=\"1\" data-md2-source-end-line=\"3\">Recover"))
        #expect(body.contains("<li data-md2-source-line=\"2\">Restore</li>"))
    }

    @Test(arguments: ["1.\tFirst", "001) First"])
    func markerWithValueOneUsesTheDefaultStart(_ marker: String) {
        let body = MarkdownRenderer().render(marker).body.withoutSourceLineMetadata
        #expect(body == "<ol>\n<li>First</li>\n</ol>")
    }

    @Test(arguments: ["1234567890. invoice", "１２. 例子", "12.\u{00a0}number"])
    func onlyBoundedASCIIMarkersWithStructuralWhitespaceOpenLists(_ line: String) {
        let body = MarkdownRenderer().render(line).body.withoutSourceLineMetadata
        #expect(body == "<p>\(line)</p>")
    }

    @Test func joiningScalarAfterTheMarkerStaysInItemText() {
        let body = MarkdownRenderer().render("10. \u{0301}combined").body.withoutSourceLineMetadata
        #expect(body.utf8.elementsEqual("<ol start=\"10\">\n<li>\u{0301}combined</li>\n</ol>".utf8))
    }

    @Test func nativeMarkerStylingMatchesTheOrderedNumberGrammar() {
        let source = "10)\tRecover\n1234567890. invoice\n１２. 例子\n12.\u{00a0}number"
        let markers = MarkdownStylePlan(source).spans.filter { $0.kind == .marker }
        #expect(markers.map { (source as NSString).substring(with: $0.range) } == ["10)\t"])
    }
}
