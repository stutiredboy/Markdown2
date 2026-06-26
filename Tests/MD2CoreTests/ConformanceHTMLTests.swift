import Testing
@testable import MD2Core

/// Task 3.2: the conformance HTML normaliser removes only invisible differences
/// and keeps intentional product divergences visible.
struct ConformanceHTMLTests {
    @Test func stripsInjectedMetadataAndAutoIds() {
        let input = #"<h1 id="title" data-md2-source-line="1">Title</h1>"#
        #expect(ConformanceHTML.normalize(input) == "<h1>Title</h1>")
    }

    @Test func normalisesVoidElementSelfClosing() {
        #expect(ConformanceHTML.normalize("<hr />") == "<hr>")
        #expect(ConformanceHTML.normalize("<p>a<br />b</p>") == "<p>a<br>b</p>")
        #expect(ConformanceHTML.normalize(#"<img src="x.png" alt="x" />"#) == #"<img src="x.png" alt="x">"#)
    }

    @Test func collapsesInterTagWhitespaceButPreservesPre() {
        let list = "<ul>\n  <li>a</li>\n  <li>b</li>\n</ul>"
        #expect(ConformanceHTML.normalize(list) == "<ul><li>a</li><li>b</li></ul>")

        // Whitespace inside <pre> is significant and must survive untouched.
        let pre = "<pre><code>a\n  b\n</code></pre>"
        #expect(ConformanceHTML.normalize(pre) == "<pre><code>a\n  b\n</code></pre>")
    }

    @Test func matchingPairNormalisesEqual() {
        // Reference XHTML vs Markdown2 HTML5 for the same thematic break.
        #expect(ConformanceHTML.normalize("<hr />\n") == ConformanceHTML.normalize("<hr>"))
    }

    @Test func intentionalDivergenceIsNotNormalisedAway() {
        // soft break: reference newline vs Markdown2 <br> must stay distinct.
        let reference = ConformanceHTML.normalize("<p>a\nb</p>")
        let rendered = ConformanceHTML.normalize("<p>a<br>b</p>")
        #expect(reference != rendered)
    }
}
