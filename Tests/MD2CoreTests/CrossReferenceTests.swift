import Testing
@testable import MD2Core

struct CrossReferenceTests {
    /// Asserts against the rendered body (not the full document) so negative
    /// checks for structural class names are not satisfied by the `<style>` block.
    private func render(_ markdown: String, numberAllEquations: Bool = false) -> String {
        let config = RenderConfig(numberAllEquations: numberAllEquations)
        return MarkdownRenderer().render(markdown, config: config).body.withoutSourceLineMetadata
    }

    // MARK: Equation references (resolution + numbering)

    @Test func equationReferenceResolvesToNumber() {
        let html = render("""
        $$E = mc^2 \\label{eq:euler}$$

        As shown in \\ref{eq:euler}.
        """)
        #expect(html.contains(##"<a class="cross-ref" href="#eq:euler">1</a>"##))
        #expect(!html.contains("\\ref{eq:euler}"))
    }

    @Test func labeledEquationIsNumberedAndLabelStripped() {
        let html = render("$$E = mc^2 \\label{eq:energy}$$")
        #expect(html.contains(#"<span class="eq-number">(1)</span>"#))
        #expect(html.contains(#"id="eq:energy""#))
        // The label command must not survive into the typeset TeX.
        #expect(!html.contains("\\label"))
    }

    @Test func unlabeledEquationNotNumberedByDefault() {
        let html = render("$$E = mc^2$$")
        #expect(!html.contains("eq-number"))
        #expect(!html.contains("numbered-equation"))
    }

    @Test func numberAllEquationsNumbersUnlabeled() {
        let html = render("$$E = mc^2$$", numberAllEquations: true)
        #expect(html.contains(#"<span class="eq-number">(1)</span>"#))
    }

    @Test func manualTagOverridesAutoNumber() {
        let html = render("$$a = b \\tag{3.1}$$")
        // KaTeX renders the tag itself; no separate Swift eq-number is added, and
        // the tag stays in the TeX handed to KaTeX.
        #expect(html.contains("\\tag{3.1}"))
        #expect(!html.contains("eq-number"))
    }

    @Test func multipleEquationsNumberedSequentially() {
        let html = render("""
        $$a = b \\label{eq:a}$$

        $$c = d \\label{eq:b}$$
        """)
        #expect(html.contains(#"id="eq:a""#))
        #expect(html.contains(#"id="eq:b""#))
        #expect(html.contains("(1)"))
        #expect(html.contains("(2)"))
    }

    // MARK: Figure references and numbering

    @Test func figureIsNumberedAndCaptioned() {
        let html = render("![Flow diagram](flow.png){#fig:flow}")
        #expect(html.contains("Figure 1: Flow diagram"))
        #expect(html.contains(#"<figure class="figure" id="fig:flow">"#))
    }

    @Test func figureReferenceResolves() {
        let html = render("""
        ![Flow diagram](flow.png){#fig:flow}

        See \\ref{fig:flow}.
        """)
        #expect(html.contains(##"<a class="cross-ref" href="#fig:flow">1</a>"##))
    }

    @Test func multipleFiguresNumberedSequentially() {
        let html = render("""
        ![First](a.png){#fig:a}

        ![Second](b.png){#fig:b}
        """)
        #expect(html.contains("Figure 1: First"))
        #expect(html.contains("Figure 2: Second"))
    }

    @Test func figureWithoutLabelIsNotNumbered() {
        let html = render("![Diagram](diagram.png)")
        #expect(!html.contains("Figure 1"))
        #expect(!html.contains("fig-caption"))
    }

    // MARK: Table references and numbering

    @Test func tableCaptionIsNumbered() {
        let html = render("""
        | A | B |
        | --- | --- |
        | 1 | 2 |
        : Results summary {#tbl:results}
        """)
        #expect(html.contains("Table 1: Results summary"))
        #expect(html.contains(#"<table id="tbl:results">"#))
    }

    @Test func tableReferenceResolves() {
        let html = render("""
        | A | B |
        | --- | --- |
        | 1 | 2 |
        : Results {#tbl:results}

        In \\ref{tbl:results}.
        """)
        #expect(html.contains(##"<a class="cross-ref" href="#tbl:results">1</a>"##))
    }

    @Test func tableWithoutCaptionIsNotNumbered() {
        let html = render("""
        | A | B |
        | --- | --- |
        | 1 | 2 |
        """)
        #expect(!html.contains("tbl-caption"))
        #expect(!html.contains("Table 1"))
    }

    @Test func captionLineIsConsumedNotRenderedAsParagraph() {
        let html = render("""
        | A | B |
        | --- | --- |
        | 1 | 2 |
        : My caption {#tbl:c}
        """)
        // The raw caption attribute syntax never leaks into the body as a paragraph.
        #expect(!html.contains("{#tbl:c}"))
        #expect(!html.contains("<p>: My caption"))
    }

    // MARK: Undefined / out-of-scope references

    @Test func undefinedLabelRendersLiteral() {
        // A document with at least one real label so the cross-ref pass is active.
        let html = render("""
        $$x = 1 \\label{eq:x}$$

        See \\ref{nonexistent}.
        """)
        #expect(html.contains("\\ref{nonexistent}"))
    }

    @Test func headingSlugReferenceIsNotResolved() {
        let html = render("""
        ## Methods

        See \\ref{methods}.
        """)
        #expect(html.contains("\\ref{methods}"))
        #expect(!html.contains("cross-ref"))
    }

    // MARK: Code / math precedence

    @Test func refInsideInlineCodeStaysLiteral() {
        let html = render("""
        $$x = 1 \\label{eq:x}$$

        Use `\\ref{eq:x}` to reference.
        """)
        #expect(html.contains("<code>\\ref{eq:x}</code>"))
    }

    @Test func refInsideInlineMathStaysLiteral() {
        let html = render("""
        $$x = 1 \\label{eq:x}$$

        Inline $\\ref{eq:x}$ here.
        """)
        // Inline math is protected before the cross-ref pass, so no anchor appears
        // for the ref inside the math span.
        #expect(html.contains(#"<span class="math math-inline">\ref{eq:x}</span>"#))
    }
}
