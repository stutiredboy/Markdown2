import Testing
@testable import MD2Core

struct MathRenderingTests {
    // MARK: Inline math (4.1)

    @Test func rendersInlineMath() {
        let document = MarkdownRenderer().render("The mass is $E = mc^2$ today.")

        #expect(document.html.contains(#"<span class="math math-inline">E = mc^2</span>"#))
        // The surrounding prose is preserved around the math span.
        #expect(document.html.contains("The mass is <span"))
        #expect(document.html.contains("</span> today."))
    }

    @Test func inlineMathIsNotProcessedAsMarkdown() {
        let document = MarkdownRenderer().render("$a_*b_*c$")

        // Underscores/asterisks are kept as literal TeX, not turned into emphasis.
        #expect(document.html.contains(#"<span class="math math-inline">a_*b_*c</span>"#))
        #expect(!document.html.contains("<em>"))
        #expect(!document.html.contains("<strong>"))
    }

    @Test func inlineMathEscapesHTMLSensitiveCharacters() {
        let document = MarkdownRenderer().render("$a < b & c$")

        // TeX is HTML-escaped so the DOM text content stays valid.
        #expect(document.html.contains(#"<span class="math math-inline">a &lt; b &amp; c</span>"#))
    }

    // MARK: Block math (4.2)

    @Test func rendersSingleLineDisplayMath() {
        let html = MarkdownRenderer().render("$$a^2 + b^2 = c^2$$").html.withoutSourceLineMetadata

        #expect(html.contains(#"<div class="math math-display">a^2 + b^2 = c^2</div>"#))
    }

    @Test func rendersMultiLineDisplayMath() {
        let markdown = """
        $$
        \\int_0^1 x^2 \\, dx
        $$
        """

        let html = MarkdownRenderer().render(markdown).html.withoutSourceLineMetadata

        #expect(html.contains(#"<div class="math math-display">\int_0^1 x^2 \, dx</div>"#))
        // The `$$` delimiters are not shown as literal text.
        #expect(!html.contains("<p>$$"))
    }

    @Test func displayMathSeparatesFromSurroundingParagraphs() {
        let markdown = """
        Before the equation.
        $$x = 1$$
        After the equation.
        """

        let html = MarkdownRenderer().render(markdown).html.withoutSourceLineMetadata

        #expect(html.contains("<p>Before the equation.</p>"))
        #expect(html.contains(#"<div class="math math-display">x = 1</div>"#))
        #expect(html.contains("<p>After the equation.</p>"))
    }

    // MARK: False positives (4.3)

    @Test func currencyTextIsNotMath() {
        let document = MarkdownRenderer().render("It costs $5 today and $10 tomorrow.")

        #expect(!document.html.contains("class=\"math"))
        #expect(document.html.contains("$5 today and $10 tomorrow."))
    }

    @Test func escapedDollarIsLiteral() {
        let document = MarkdownRenderer().render(#"Price: \$x"#)

        #expect(!document.html.contains("class=\"math"))
        #expect(document.html.contains("Price: $x"))
    }

    @Test func loneUnmatchedDollarIsLiteral() {
        let document = MarkdownRenderer().render("A single $ sign here.")

        #expect(!document.html.contains("class=\"math"))
        #expect(document.html.contains("A single $ sign here."))
    }

    @Test func openingDollarFollowedBySpaceIsNotMath() {
        let document = MarkdownRenderer().render("Use $ x for the var $ end.")

        #expect(!document.html.contains("class=\"math"))
    }

    // MARK: Code precedence (4.4)

    @Test func inlineMathInsideInlineCodeStaysLiteral() {
        let document = MarkdownRenderer().render("use `$x$` here")

        #expect(!document.html.contains("class=\"math"))
        #expect(document.html.contains("<code>$x$</code>"))
    }

    @Test func displayMathInsideFencedCodeStaysLiteral() {
        let markdown = """
        ```
        $$x^2$$
        ```
        """

        let document = MarkdownRenderer().render(markdown)

        #expect(!document.html.contains("class=\"math"))
        #expect(document.html.contains("$$x^2$$"))
    }

    // MARK: Backslash TeX commands inside inline math (4.5)

    @Test func backslashTeXCommandsSurviveInsideInlineMath() {
        let document = MarkdownRenderer().render(#"单位年持有成本 $h = I \cdot C_\text{eff} = 0.25\,C_\text{eff}$ 计算如下。"#)

        // `\,` (thin space) reaches KaTeX verbatim instead of being eaten as a
        // Markdown backslash escape.
        #expect(document.html.contains(#"<span class="math math-inline">h = I \cdot C_\text{eff} = 0.25\,C_\text{eff}</span>"#))
        // The internal protection placeholder never leaks into the DOM.
        #expect(!document.html.contains("MD2-"))
    }

    @Test func escapedPercentSurvivesInsideInlineMath() {
        let document = MarkdownRenderer().render(#"服务水平 $z_{98\%}=2.05$ 对应的安全系数。"#)

        #expect(document.html.contains(#"<span class="math math-inline">z_{98\%}=2.05</span>"#))
        #expect(!document.html.contains("MD2-"))
    }

    @Test func escapedDollarInsideInlineMathDoesNotCloseSpan() {
        let document = MarkdownRenderer().render(#"库存占用资金 $\text{Inv\$} = AIL \cdot C_\text{eff}$ 如下。"#)

        // The interior `\$` is TeX source, not a closing delimiter: one span
        // spanning to the final unescaped `$`.
        #expect(document.html.contains(#"<span class="math math-inline">\text{Inv\$} = AIL \cdot C_\text{eff}</span>"#))
        #expect(!document.html.contains("MD2-"))
    }

    @Test func escapedDollarsDoNotPairIntoMath() {
        let document = MarkdownRenderer().render(#"循环库存 \$18 125 与安全库存 \$10 633"#)

        #expect(!document.html.contains("class=\"math"))
        #expect(document.html.contains("$18 125"))
        #expect(document.html.contains("$10 633"))
    }

    @Test func escapedDollarCoexistsWithRealMathOnOneLine() {
        let document = MarkdownRenderer().render(#"成本为 \$5，公式为 $x+1$"#)

        #expect(document.html.contains("$5"))
        #expect(document.html.contains(#"<span class="math math-inline">x+1</span>"#))
    }

    // MARK: Offline assets (5.x support)

    @Test func previewHTMLBundlesKaTeXAssetsForOfflineRendering() {
        let document = MarkdownRenderer().render("$x$")

        // KaTeX CSS (with embedded fonts) and JS are inlined — no network needed.
        #expect(document.html.contains(".katex"))
        #expect(document.html.contains("data:font/woff2;base64,"))
        #expect(document.html.contains("katex.render"))
    }

    @Test func previewHTMLBundlesMhchemExtension() {
        let document = MarkdownRenderer().render(#"$\ce{CH4 + 2 O2}$"#)

        // The mhchem extension is inlined so `\ce{...}` chemistry renders.
        #expect(document.html.contains("__mhchemParse") || document.html.contains("mhchem"))
        #expect(document.html.contains(#"<span class="math math-inline">\ce{CH4 + 2 O2}</span>"#))
    }

    // MARK: Equation numbering (6.x)

    @Test func labeledDisplayEquationIsNumbered() {
        let body = MarkdownRenderer().render(#"$$E = mc^2 \label{eq:energy}$$"#).body.withoutSourceLineMetadata

        #expect(body.contains(#"<span class="eq-number">(1)</span>"#))
        #expect(body.contains(#"id="eq:energy""#))
    }

    @Test func labelCommandIsStrippedFromTypesetTeX() {
        let body = MarkdownRenderer().render(#"$$E = mc^2 \label{eq:energy}$$"#).body

        // The label command must not reach KaTeX (0.16 would typeset it as an error).
        #expect(!body.contains(#"\label"#))
        #expect(body.contains("E = mc^2"))
    }

    @Test func unlabeledEquationIsUnnumberedByDefault() {
        let body = MarkdownRenderer().render("$$E = mc^2$$").body

        #expect(!body.contains("eq-number"))
    }

    @Test func numberAllEquationsSettingNumbersUnlabeled() {
        let config = RenderConfig(numberAllEquations: true)
        let body = MarkdownRenderer().render("$$E = mc^2$$", config: config).body.withoutSourceLineMetadata

        #expect(body.contains(#"<span class="eq-number">(1)</span>"#))
    }

    @Test func manualTagIsPassedThroughToKaTeX() {
        let body = MarkdownRenderer().render(#"$$a = b \tag{3.1}$$"#).body

        // The tag stays in the TeX for KaTeX to render; no separate eq-number.
        #expect(body.contains(#"\tag{3.1}"#))
        #expect(!body.contains("eq-number"))
    }

    // MARK: KaTeX macro configuration (10.x)

    @Test func globalGroupAndMacrosAreConfigured() {
        let html = MarkdownRenderer().render("$x$").html

        #expect(html.contains("globalGroup: true"))
        #expect(html.contains("macros: window.__md2MathMacros"))
    }

    @Test func frontMatterMacrosAreSerializedIntoKaTeXConfig() {
        let config = RenderConfig(mathMacros: ["\\vec": "\\mathbf"])
        let html = MarkdownRenderer().render(#"$\vec{x}$"#, config: config).html

        // JSON `\\`-escaping yields the single backslashes KaTeX expects.
        #expect(html.contains(#""\\vec""#))
        #expect(html.contains(#""\\mathbf""#))
    }

    @Test func noMacrosSerializeToEmptyObject() {
        let html = MarkdownRenderer().render("$x$").html

        #expect(html.contains("window.__md2InitialMacros = {};"))
    }
}
