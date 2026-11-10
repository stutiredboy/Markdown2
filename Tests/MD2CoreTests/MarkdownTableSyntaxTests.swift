import Foundation
import Testing
@testable import MD2Core

struct MarkdownTableSyntaxTests {
    @Test(arguments: [
        #"| a\|b | c |"#, #"| a\\| b |"#, #"| `a|b` | c |"#,
        "| &#124; &#92; &#96; | 中🙂é |", "a | b", "| a | b", "a | b |"
    ])
    func supportedColumnsAgreeWithRenderer(_ row: String) throws {
        let parsed = try #require(MarkdownTableSyntax.row(row))
        let source = row + "\n| - | - |\n" + row
        let body = MarkdownRenderer().render(source).body
        #expect(parsed.cells.count == 2)
        #expect(body.components(separatedBy: "<th").count - 2 == parsed.cells.count)
        #expect(body.components(separatedBy: "<td").count - 1 == parsed.cells.count)
        for range in parsed.contents { #expect(NSMaxRange(range) <= row.utf16.count) }
    }

    @Test(arguments: [#"a | b\|"#, #"| ``a|b`` | c |"#, #"| `a|b | c |"#])
    func ambiguousRendererEdgesAreRejected(_ row: String) {
        #expect(MarkdownTableSyntax.row(row) == nil)
    }
}
