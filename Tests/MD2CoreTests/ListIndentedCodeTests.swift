import Testing
@testable import MD2Core

struct ListIndentedCodeTests {
    @Test(arguments: ["- Foo\n      bar\n", "1. Foo\n       bar\n", "10. Foo\n        bar\n"])
    func codeIndentCannotInterruptTheInitialParagraph(markdown: String) {
        // Indented code requires a blank before it. A deeply indented line
        // directly after the item text is still a paragraph continuation.
        let body = MarkdownRenderer().render(markdown).body.withoutSourceLineMetadata

        #expect(!body.contains("<pre>"))
        #expect(body.contains("bar"))
    }

    @Test func codeCanFollowAnOrdinaryContinuationParagraph() {
        let markdown = "- Foo\n  continued\n\n      code"
        let body = MarkdownRenderer().render(markdown).body.withoutSourceLineMetadata

        #expect(body.contains("<p>continued</p>"))
        #expect(body.contains("<pre><code>code</code></pre>"))
    }

    @Test func codeOnlyContinuationKeepsCodeAndInternalBlankLines() {
        // CommonMark #264: the item prefix consumes two columns, leaving four
        // columns of code indentation. Blank lines remain inside one code block.
        let body = MarkdownRenderer().render("- Foo\n\n      bar\n\n\n      baz\n").body

        #expect(body.withoutSourceLineMetadata == "<ul>\n<li>Foo\n<pre><code>bar\n\n\nbaz</code></pre></li>\n</ul>")
        #expect(body.contains(#"<pre data-md2-source-line="3" data-md2-source-end-line="6">"#))
        #expect(body.contains(#"<li data-md2-source-line="1" data-md2-source-end-line="6">"#))
    }

    @Test(arguments: [("1. step", 7), ("10. step", 8), ("   - step", 9)])
    func codeIndentIsRelativeToTheMarker(item: String, indent: Int) {
        let markdown = item + "\n\n" + String(repeating: " ", count: indent) + "a < b"
        let body = MarkdownRenderer().render(markdown).body.withoutSourceLineMetadata

        #expect(body.contains("<pre><code>a &lt; b</code></pre>"))
        #expect(!body.contains("<p>a &lt; b</p>"))
    }

    @Test func nestedTaskCodeKeepsAbsoluteSourceLines() {
        let markdown = "# Title\n\n> - parent\n>   - [x] child\n>\n>         code\n> - sibling"
        let body = MarkdownRenderer().render(markdown).body

        #expect(body.contains(#"<input type="checkbox" data-md2-task-line="4" checked> child"#))
        #expect(body.contains(#"<pre data-md2-source-line="6"><code>code</code></pre>"#))
        #expect(body.contains(#"<li data-md2-source-line="4" data-md2-source-end-line="6">"#))
        #expect(body.contains(#"<li data-md2-source-line="7">sibling</li>"#))
    }

    @Test func referenceDefinitionInsideIndentedCodeStaysLiteral() {
        let markdown = "- Example\n\n      [ref]: https://example.com/\n\n[ref]"
        let body = MarkdownRenderer().render(markdown).body.withoutSourceLineMetadata

        #expect(body.contains("<pre><code>[ref]: https://example.com/</code></pre>"))
        #expect(body.contains("<p>[ref]</p>"))
        #expect(!body.contains("<a href="))
    }

    @Test func dedentedParagraphEndsCodeWithoutEndingTheItem() {
        let markdown = "- Example\n\n      code\n\n  paragraph\n- sibling"
        let body = MarkdownRenderer().render(markdown).body.withoutSourceLineMetadata

        #expect(body.contains("<li>Example\n<pre><code>code\n</code></pre>\n<p>paragraph</p></li>"))
        #expect(body.contains("<li>sibling</li>"))
    }

    @Test(arguments: [2, 3, 4, 5])
    func fewerThanFourContentColumnsRemainParagraphs(indent: Int) {
        let markdown = "- Example\n\n" + String(repeating: " ", count: indent) + "paragraph"
        let body = MarkdownRenderer().render(markdown).body.withoutSourceLineMetadata

        #expect(body.contains("<li>Example\n<p>paragraph</p></li>"))
        #expect(!body.contains("<pre>"))
    }
}
