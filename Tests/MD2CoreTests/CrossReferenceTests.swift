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

    @Test func undefinedLabelWithMarkdownPunctuationRendersLiteral() {
        // The literal is the authored text; emphasis must not reach inside it.
        let html = render("See \\ref{eq:a_b_c} and \\ref{*x*}.")
        #expect(html.contains("See \\ref{eq:a_b_c} and \\ref{*x*}."))
        #expect(!html.contains("<em>"))
    }

    @Test(arguments: [true, false])
    func referenceInsideLinkSyntaxActsAsAnAnchor(labelDefined: Bool) {
        // A `\ref{}` is parsed before its label is known, so link syntax treats
        // it as the anchor it may become, defined or not: a destination holding
        // one is unsafe, and links cannot nest.
        var markdown = """
        [text](https://example.com/\\ref{fig:a}) ![alt](\\ref{fig:a}.png) [r \\ref{fig:a}][ref] [see \\ref{fig:a}](https://example.com)

        [ref]: https://example.com/ref
        """
        if labelDefined { markdown += "\n\n![Fig](a.png){#fig:a}" }

        let html = render(markdown)
        #expect(html.contains("<p>text "))
        #expect(!html.contains("<img src=\"\\ref"))
        #expect(!html.contains(#"<a href="https://example.com/ref">r "#))
        #expect(html.contains(#"<a href="https://example.com">see "#))
    }

    // MARK: Containers and forward references

    /// Every `\ref{}` anchor in `html`, in order, as (label, shown number).
    private func references(in html: String) throws -> [(label: String, number: String)] {
        let anchor = try Regex(##"<a class="cross-ref" href="#([^"]+)">([^<]+)</a>"##, as: (Substring, Substring, Substring).self)
        return html.matches(of: anchor).map { (String($0.output.1), String($0.output.2)) }
    }

    /// The number each figure, table, and auto-numbered equation displays, keyed
    /// by its id.
    private func displayedNumbers(in html: String) throws -> [String: String] {
        let patterns = [
            #"<figure class="figure" id="([^"]+)">[\s\S]*?Figure (\d+):"#,
            #"<table id="([^"]+)">\n<caption class="tbl-caption">Table (\d+):"#,
            #"<div class="numbered-equation" id="([^"]+)">[\s\S]*?<span class="eq-number">\(([^)]+)\)</span>"#
        ]
        var numbers: [String: String] = [:]
        for pattern in patterns {
            for match in html.matches(of: try Regex(pattern, as: (Substring, Substring, Substring).self)) {
                numbers[String(match.output.1)] = String(match.output.2)
            }
        }
        return numbers
    }

    /// The invariant one numbering walk guarantees: every `\ref{}` site renders
    /// as an anchor showing the number its target displays.
    private func expectReferencesMatchTargets(
        _ html: String,
        sites: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let targets = try displayedNumbers(in: html)
        let anchors = try references(in: html)
        #expect(anchors.count == sites, sourceLocation: sourceLocation)
        for anchor in anchors {
            #expect(targets[anchor.label] == anchor.number, "\\ref{\(anchor.label)}", sourceLocation: sourceLocation)
        }
    }

    @Test func referencesMatchTargetsInEveryContainer() throws {
        // Elements are numbered in display order: blockquote and list content in
        // place, a table caption's figure before the body figure after it, and
        // footnote figures after the body.
        let html = render("""
        Forward: \\ref{eq:quoted}, \\ref{eq:item}, \\ref{eq:top}, \\ref{fig:caption}, \\ref{fig:body}, \\ref{fig:note}, \\ref{tbl:t}.[^n]

        > [!NOTE]
        > $$a = 1 \\label{eq:quoted}$$

        - outer
          - inner

            $$b = 2 \\label{eq:item}$$

        ## Results in \\ref{tbl:t}

        | A |
        | --- |
        | 1 |
        : Caption ![icon](i.png){#fig:caption} {#tbl:t}

        ![Body](b.png){#fig:body}

        $$c = 3 \\label{eq:top}$$

        [^n]: ![Note](n.png){#fig:note} After \\ref{eq:top}.

        Backward: \\ref{eq:quoted}, \\ref{eq:item}, \\ref{eq:top}, \\ref{fig:caption}, \\ref{fig:body}, \\ref{fig:note}, \\ref{tbl:t}.
        """)

        #expect(try displayedNumbers(in: html) == [
            "eq:quoted": "1", "eq:item": "2", "eq:top": "3",
            "fig:caption": "1", "fig:body": "2", "fig:note": "3",
            "tbl:t": "1"
        ])
        try expectReferencesMatchTargets(html, sites: 16)
        #expect(!html.contains("\\ref{"))
    }

    @Test func quotedEquationBeforeTopLevelEquationKeepsNumbersAligned() throws {
        let html = render("""
        See \\ref{eq:top}.

        > $$a = 1 \\label{eq:quoted}$$

        $$b = 2 \\label{eq:top}$$
        """)
        #expect(html.contains(#"<span class="eq-number">(2)</span>"#))
        #expect(html.contains(##"<a class="cross-ref" href="#eq:top">2</a>"##))
        try expectReferencesMatchTargets(html, sites: 1)
    }

    @Test func footnoteFigureIsNumberedAfterBodyFigures() throws {
        let html = render("""
        See \\ref{fig:body} and \\ref{fig:note}.[^n]

        [^n]: ![Note](n.png){#fig:note}

        ![Body](b.png){#fig:body}
        """)
        #expect(html.contains("Figure 1: Body"))
        #expect(html.contains("Figure 2: Note"))
        try expectReferencesMatchTargets(html, sites: 2)
    }

    @Test func figureInsideQuotedCodeFenceIsNotATarget() throws {
        let html = render("""
        > ```
        > ![Code](c.png){#fig:code}
        > ```

        ![Real](r.png){#fig:real}

        See \\ref{fig:real} and \\ref{fig:code}.
        """)
        #expect(html.contains("Figure 1: Real"))
        #expect(html.contains("\\ref{fig:code}"))
        try expectReferencesMatchTargets(html, sites: 1)
    }

    @Test func duplicateLabelResolvesEveryReferenceToLastDefinition() throws {
        let html = render("""
        Before \\ref{fig:x}.

        ![One](a.png){#fig:x}

        Between \\ref{fig:x}.

        ![Two](b.png){#fig:x}

        After \\ref{fig:x}.
        """)
        #expect(try references(in: html).map(\.number) == ["2", "2", "2"])
    }

    @Test(arguments: [true, false])
    func noPlaceholderSurvivesAnyInlinePosition(labelDefined: Bool) {
        // Attributes read the authored spelling, and a destination holding the
        // provisional anchor fails URL safety like the anchor itself, so a
        // placeholder only ever lands in HTML content, where it resolves.
        var markdown = """
        # Heading \\ref{fig:a}

        [text \\ref{fig:a}](https://example.com/\\ref{fig:a} "title \\ref{fig:a}") [r \\ref{fig:a}][ref]

        ![alt \\ref{fig:a}](\\ref{fig:a}.png "t \\ref{fig:a}") <span title="\\ref{fig:a}">raw \\ref{fig:a}</span>

        | \\ref{fig:a} |
        | --- |
        | cell \\ref{fig:a} |

        - [ ] task \\ref{fig:a}

        > [!TIP]
        > quoted \\ref{fig:a} https://example.com/\\ref{fig:a}

        Note.[^n]

        [^n]: footnote \\ref{fig:a}

        [ref]: https://example.com/\\ref{fig:a}
        """
        if labelDefined { markdown += "\n\n![Fig](a.png){#fig:a}" }

        let rendered = MarkdownRenderer().render(markdown)
        #expect(!rendered.body.contains("\u{E001}"))
        #expect(!rendered.html.contains("\u{E001}"))
        #expect(!rendered.body.contains(#"href="<a"#))
        #expect(!rendered.body.contains(#"src="<a"#))
        if labelDefined {
            #expect(rendered.body.contains(##"<a class="cross-ref" href="#fig:a">1</a>"##))
        } else {
            #expect(!rendered.body.contains("cross-ref"))
            #expect(rendered.body.contains("footnote \\ref{fig:a}"))
            #expect(rendered.body.contains("cell \\ref{fig:a}"))
        }
    }

    @Test(arguments: [
        "$$x \\label{eq:a}$$\n\nhttps://example.com\\ref{eq:a} www.example.com\\ref{eq:a}",
        "https://example.com\\ref{eq:a} www.example.com\\ref{eq:a}\n\n$$x \\label{eq:a}$$",
        "https://example.com\\ref{eq:a} www.example.com\\ref{eq:a}"
    ])
    func bareURLFusedWithReferenceStaysUnlinked(markdown: String) {
        // The reference's visible text continues the host (`example.com1`), and
        // the lookalike guard cannot know it before resolution, so it fails
        // closed whether the label is backward, forward, or undefined.
        let html = render(markdown)
        #expect(!html.contains(#"<a href="https://example.com">"#))
        #expect(!html.contains(#"<a href="http://www.example.com">"#))
    }

    @Test func authoredPrivateUseTextIsNeverAReference() {
        // Placeholders carry a per-render nonce, so authored private-use text
        // stays literal, and a combining mark after a reference cannot hide the
        // placeholder's closing sentinel inside a grapheme.
        let html = render("""
        $$x = 1 \\label{eq:x}$$

        See \\ref{eq:x}\u{301} and \u{E001}0\u{E001} and \u{E001}.
        """)
        #expect(html.contains(##"<a class="cross-ref" href="#eq:x">1</a>"## + "\u{301}"))
        #expect(html.contains("and \u{E001}0\u{E001} and \u{E001}."))
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
