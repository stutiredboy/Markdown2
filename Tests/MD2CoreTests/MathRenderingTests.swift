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

    @Test func rendersBracketDelimitedDisplayMath() {
        let markdown = #"""
        \[
        C^{availability}_t=\frac{A_t}{H_t}\times 100
        \]
        """#

        let html = MarkdownRenderer().render(markdown).html.withoutSourceLineMetadata

        #expect(html.contains(#"<div class="math math-display">C^{availability}_t=\frac{A_t}{H_t}\times 100</div>"#))
        #expect(!html.contains(#"<p>\["#))
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

    // MARK: Paren-delimited inline math (LaTeX spelling)

    @Test func rendersParenDelimitedInlineMath() {
        let document = MarkdownRenderer().render(#"The mass is \(E = mc^2\) today."#)

        #expect(document.html.contains(#"<span class="math math-inline">E = mc^2</span>"#))
        #expect(document.html.contains("The mass is <span"))
        #expect(document.html.contains("</span> today."))
    }

    @Test func parenDelimitedInlineMathAcceptsSurroundingSpaces() {
        let document = MarkdownRenderer().render(#"\( x + y \)"#)

        #expect(document.html.contains(#"<span class="math math-inline"> x + y </span>"#))
    }

    @Test func backslashTeXCommandsSurviveInsideParenDelimitedMath() {
        let document = MarkdownRenderer().render(#"\(0.25\,C_\text{eff}\)"#)

        // `\(` is not eaten as a Markdown escape, and `\,` reaches KaTeX verbatim.
        #expect(document.html.contains(#"<span class="math math-inline">0.25\,C_\text{eff}</span>"#))
        #expect(!document.html.contains("MD2-"))
    }

    @Test func unterminatedParenDelimiterIsNotMath() {
        let document = MarkdownRenderer().render(#"see \(x + y"#)

        #expect(!document.html.contains("class=\"math"))
        #expect(document.html.contains("see (x + y"))
    }

    @Test func escapedBackslashBeforeParenDoesNotOpenMath() {
        let document = MarkdownRenderer().render(#"Escaped \\(x\\) here."#)

        #expect(!document.html.contains("class=\"math"))
    }

    @Test func twoParenDelimitedSpansOnOneLineBothRender() {
        let document = MarkdownRenderer().render(#"\(a\) text \(b\)"#)

        #expect(document.html.contains(#"<span class="math math-inline">a</span>"#))
        #expect(document.html.contains(#"<span class="math math-inline">b</span>"#))
    }

    @Test func rowSeparatorSurvivesInsideParenDelimitedMath() {
        let document = MarkdownRenderer().render(#"\(a\\ b\) end"#)

        // The `\\` pair is consumed as TeX, so it reaches KaTeX intact.
        #expect(document.html.contains(#"<span class="math math-inline">a\\ b</span>"#))
    }

    @Test func trailingBackslashBeforeCloserLeavesSpanLiteral() {
        // `\(a\\)` consumes `\\` as TeX, leaving no closer: the span stays literal.
        let document = MarkdownRenderer().render(#"\(a\\) end"#)

        #expect(!document.html.contains("class=\"math"))
    }

    @Test func emptyParenPairIsNotMath() {
        let document = MarkdownRenderer().render(#"\(\)"#)

        #expect(!document.html.contains("class=\"math"))
        #expect(document.html.contains("()"))
    }

    // MARK: Delimiter ownership (reading order)

    /// Value: protects=dollar signs inside `\(...\)` reach the engine as TeX;
    /// fails_when=the `$` form is claimed before the outer span or restores as a
    /// nested span; why_new=the former test pinned the nested-span defect as a
    /// declared boundary; seam=none; no_claim=only `$` inside `\(...\)`, not other
    /// nesting combinations.
    @Test func dollarSignsInsideParenDelimitedMathReachTheEngine() {
        let outer = MarkdownRenderer().render(#"Outer \( x $y$ z \) end."#).html
        #expect(outer.contains(#"Outer <span class="math math-inline"> x $y$ z </span> end."#))

        let text = MarkdownRenderer().render(#"\(\text{$x$}\)"#).body
        #expect(text.contains(#"<span class="math math-inline">\text{$x$}</span>"#))
        #expect(text.components(separatedBy: "math-inline").count - 1 == 1)
    }

    /// Value: protects=a code span wholly inside a math span is TeX source, and a
    /// backslash before it does not split it; fails_when=code spans are claimed
    /// first and restore as nested `<code>`, or a closer inside the code span ends
    /// the math; why_new=no test covered code inside math; seam=none;
    /// no_claim=only these three shapes, not every backtick-run length.
    @Test(arguments: [
        (#"a $a `b` c$ z"#, #"<span class="math math-inline">a `b` c</span>"#),
        (#"\(a `\)` b\) z"#, #"<span class="math math-inline">a `\)` b</span>"#),
        (#"$a \`b$` c$"#, #"<span class="math math-inline">a \`b$` c</span>"#)
    ])
    func codeSpanInsideMathIsTeXSource(_ markdown: String, _ span: String) {
        let html = MarkdownRenderer().render(markdown).html

        #expect(html.contains(span))
        #expect(!html.contains("<code>"))
    }

    /// Value: protects=the opener and closer guards the scan carries over from the
    /// former regex passes; fails_when=a hand-written guard drifts — `$` before
    /// whitespace, `$` after `$` or `\`, a closer before `$`, a backslash before an
    /// in-line line terminator, or `\(` after a backslash opens or closes a span;
    /// why_new=no test exercised these guards while they lived in the patterns;
    /// seam=none; no_claim=only the listed guards, one shape each.
    @Test(arguments: [
        ("a $ x$ b", "a $ x$ b"),
        ("a $x$$ b", "a $x$$ b"),
        (#"a \$x$ b"#, "a $x$ b"),
        ("a $$x$ b", "a $$x$ b"),
        ("$a\\\u{2028}b$", "$a\\\u{2028}b$"),
        ("\\(a\\\u{2028}b\\)", "(a\\\u{2028}b)"),
        (#"a \\(x\) b"#, #"a \(x) b"#)
    ])
    func carriedOverGuardsKeepTextLiteral(_ markdown: String, _ literal: String) {
        let body = MarkdownRenderer().render(markdown).body

        #expect(body.contains(literal))
        #expect(!body.contains("math-inline"))
    }

    /// Value: protects=code spans bind tighter than math, so a math candidate whose
    /// closer sits inside a code span is not math; fails_when=the scan lets the
    /// earliest `$` or `\(` own a span that cuts through a code span (pure reading
    /// order, as Pandoc does); why_new=currency followed by shell code was only
    /// protected implicitly by the old pass order; seam=none; no_claim=only closers
    /// inside a code span, not openers inside one (covered by the inline-code tests).
    @Test(arguments: [
        ("The plan costs $20/month. Set `$API_KEY` first.", "<code>$API_KEY</code>"),
        ("Then $a ` b$ and ` c", "<code>b$ and</code>"),
        (#"Then \(a ` \) ` b"#, #"<code>\)</code>"#)
    ])
    func mathDoesNotCloseInsideACodeSpan(_ markdown: String, _ code: String) {
        let html = MarkdownRenderer().render(markdown).html

        #expect(html.contains(code))
        #expect(!html.contains("class=\"math"))
    }

    /// Value: protects=between `$...$` and `\(...\)` the earliest opener owns its
    /// span and the other form's delimiters are plain TeX; fails_when=one form keeps
    /// a fixed priority (the old `$`-first order merged `\(a$b\) and \(c$d\)` into
    /// one nested span); why_new=no test crossed the two math forms; seam=none;
    /// no_claim=only these crossings, not three-way nesting.
    @Test func earliestOpenerOwnsBetweenMathForms() {
        let pair = MarkdownRenderer().render(#"\(a$b\) and \(c$d\)"#).html
        #expect(pair.contains(#"<span class="math math-inline">a$b</span> and <span class="math math-inline">c$d</span>"#))

        let parenFirst = MarkdownRenderer().render(#"\( a $b \) c$"#).html
        #expect(parenFirst.contains(#"<span class="math math-inline"> a $b </span> c$"#))

        let dollarFirst = MarkdownRenderer().render(#"$a \( b$ c \)"#).html
        #expect(dollarFirst.contains(#"<span class="math math-inline">a \( b</span> c )"#))

        let nested = MarkdownRenderer().render(#"$\text{\(x\)}$"#).html
        #expect(nested.contains(#"<span class="math math-inline">\text{\(x\)}</span>"#))
    }

    @Test func parenDelimitedMathInsideInlineCodeStaysLiteral() {
        let document = MarkdownRenderer().render(#"use `\(x\)` here"#)

        #expect(!document.html.contains("class=\"math"))
        #expect(document.html.contains(#"<code>\(x\)</code>"#))
    }

    @Test func escapedParensInLinkDestinationAreNotMath() {
        // Inside `](…)` a `\(` is a CommonMark escape, not a math delimiter: the
        // destination must survive as a literal parenthesized href.
        let document = MarkdownRenderer().render(#"[link](\(foo\))"#)

        #expect(!document.html.contains("class=\"math"))
        #expect(document.html.contains(##"<a href="(foo)">link</a>"##))
    }

    @Test func escapedParensInNestedLinkDestinationAreNotMath() {
        let document = MarkdownRenderer().render(#"[link](foo\(and\(bar\))"#)

        #expect(!document.html.contains("class=\"math"))
        #expect(document.html.contains(##"<a href="foo(and(bar)">link</a>"##))
    }

    @Test func escapedParensAfterBalancedDestinationParensAreNotMath() {
        // Nested parens in a link destination are a pre-existing link-parsing
        // boundary (the destination regex stops at the first `)`). What this pins
        // is the part this change owns: the escaped pair does not become math.
        let document = MarkdownRenderer().render(#"[link](b(c)\(d\))"#)

        #expect(!document.html.contains("class=\"math"))
    }

    @Test func mathAfterALinkOnTheSameLineStillRenders() {
        let document = MarkdownRenderer().render(#"[a](b) then \(x + y\) end"#)

        #expect(document.html.contains(##"<a href="b">a</a>"##))
        #expect(document.html.contains(#"<span class="math math-inline">x + y</span>"#))
    }

    @Test func parenDelimitedMathInsideLinkLabelStillRenders() {
        // The label sits before `](`, so it is not part of any destination.
        let document = MarkdownRenderer().render(#"[\(x\)](url)"#)

        #expect(document.html.contains(#"<span class="math math-inline">x</span>"#))
        #expect(document.html.contains(##"<a href="url">"##))
    }

    /// Value: protects=link syntax inside an already-claimed span cannot open a
    /// destination for a later `\(`; fails_when=the scan feeds a claimed span's raw
    /// scalars to the destination tracker instead of one opaque unit; why_new=the
    /// old pass saw code spans as tokens but paren spans raw, and no test pinned
    /// either; seam=none; no_claim=only `](` inside code and paren math.
    @Test func linkSyntaxInsideAClaimedSpanDoesNotHideLaterParenMath() {
        let afterCode = MarkdownRenderer().render(#"Type `](` then \(x\) here"#).html
        #expect(afterCode.contains(#"<span class="math math-inline">x</span>"#))

        let afterMath = MarkdownRenderer().render(#"\(](\) then \(y\)"#).html
        #expect(afterMath.contains(#"<span class="math math-inline">](</span> then <span class="math math-inline">y</span>"#))
    }

    /// Value: protects=a `\(` rejected inside a destination does not swallow a later
    /// opener outside it; fails_when=the scan skips past the rejected candidate's
    /// would-be span, as the old match-then-filter pass did; why_new=no test had a
    /// second opener after the destination closes; seam=none; no_claim=only this
    /// single-destination arrangement.
    @Test func rejectedParenOpenerInsideDestinationDoesNotSwallowLaterMath() {
        let html = MarkdownRenderer().render(#"[a](\(x) \(y\))"#).html

        #expect(html.contains(##"<a href="(x">a</a> <span class="math math-inline">y</span>)"##))
    }

    // MARK: Native math environments (no `$$` wrapper)

    @Test func rendersMultiLineAlignEnvironment() {
        let markdown = #"""
        \begin{align}
        a &= b \\
        c &= d
        \end{align}
        """#

        let body = MarkdownRenderer().render(markdown).body.withoutSourceLineMetadata

        // The environment is retained so the engine can parse the block, in its
        // starred form so the engine's own row numbering stays out of the way.
        #expect(body.contains(#"<div class="math math-display">\begin{align*}"#))
        #expect(body.contains(#"\end{align*}</div>"#))
        #expect(!body.contains("<p>"))
    }

    @Test func singleLineEquationEnvironmentKeepsItsWrappersStarred() {
        let body = MarkdownRenderer().render(#"\begin{equation}E = mc^2\end{equation}"#).body.withoutSourceLineMetadata

        #expect(body.contains(#"<div class="math math-display">\begin{equation*}E = mc^2\end{equation*}</div>"#))
    }

    @Test func engineNumberedEnvironmentsAreStarred() {
        // The engine numbers align/alignat/gather/equation rows itself, through a
        // CSS counter that fills its `.eqn-num` slot — invisible in the generated
        // HTML but painted in the preview and in exports. Starring the environment
        // keeps display numbering under one authority.
        for name in ["align", "alignat", "gather", "equation"] {
            let body = MarkdownRenderer().render("\\begin{\(name)}\na &= b\n\\end{\(name)}").body

            #expect(body.contains("\\begin{\(name)*}"), "\(name) opener was not starred: \(body)")
            #expect(body.contains("\\end{\(name)*}"), "\(name) closer was not starred: \(body)")
        }
    }

    @Test func starredEnvironmentIsNotDoubleStarred() {
        let body = MarkdownRenderer().render(#"\begin{align*}a &= b\end{align*}"#).body

        #expect(body.contains(#"\begin{align*}"#))
        #expect(!body.contains(#"align**"#))
    }

    @Test func labelledEnvironmentCarriesExactlyOneNumber() {
        // Markdown2 supplies the number for a labeled equation; the engine must not
        // also number the rows.
        let markdown = #"""
        \begin{align}
        a &= b \label{eq:one} \\
        c &= d
        \end{align}
        """#

        let body = MarkdownRenderer().render(markdown).body.withoutSourceLineMetadata

        #expect(body.contains(#"<span class="eq-number">(1)</span>"#))
        #expect(body.contains(#"\begin{align*}"#))
    }

    @Test func manualTagStillRendersInAStarredEnvironment() {
        // Starring suppresses the engine's automatic counter without breaking an
        // explicit `\tag{}`.
        let markdown = #"""
        \begin{align}
        a &= b \tag{3.1}
        \end{align}
        """#

        let body = MarkdownRenderer().render(markdown).body.withoutSourceLineMetadata

        #expect(body.contains(#"\tag{3.1}"#))
        #expect(body.contains(#"\begin{align*}"#))
        #expect(!body.contains("eq-number"))
    }

    @Test func starredEnvironmentIsUnnumbered() {
        let body = MarkdownRenderer().render(#"\begin{equation*}E = mc^2\end{equation*}"#).body.withoutSourceLineMetadata

        #expect(body.contains("math-display"))
        #expect(!body.contains("eq-number"))
    }

    @Test func nestedInnerEnvironmentDoesNotCloseTheBlockEarly() {
        let markdown = #"""
        \begin{align}
        x &= \begin{cases} 1 & a \\ 2 & b \end{cases} \\
        y &= 2
        \end{align}
        """#

        let body = MarkdownRenderer().render(markdown).body.withoutSourceLineMetadata

        #expect(body.contains(#"\begin{cases}"#))
        #expect(body.contains("y &amp;= 2"))
        #expect(!body.contains("<p>"))
    }

    @Test func nestedSameNameEnvironmentTypesetsAsOneBlock() {
        let markdown = #"""
        \begin{matrix}
        \begin{matrix} a \end{matrix}
        \end{matrix}
        """#

        let body = MarkdownRenderer().render(markdown).body.withoutSourceLineMetadata

        // Both the inner and outer closers stay inside the block — none is
        // orphaned as literal text.
        #expect(body.contains(#"<div class="math math-display">"#))
        #expect(!body.contains("<p>"))
        #expect(body.components(separatedBy: #"\end{matrix}"#).count - 1 == 2)
    }

    @Test func fencedCodeCloserDoesNotCaptureAProseLine() {
        let markdown = #"""
        \begin{align}
        prose line

        ```
        sample
        \end{align}
        ```
        """#

        let body = MarkdownRenderer().render(markdown).body.withoutSourceLineMetadata

        // The scan bails at the fence, so the prose stays prose and the fence stays code.
        #expect(!body.contains("math-display"))
        #expect(body.contains("<pre><code>"))
        #expect(body.contains("prose line"))
    }

    @Test func paragraphAdjacentToEnvironmentKeepsItsBoundaries() {
        let markdown = #"""
        Some prose.
        \begin{align}
        a &= b
        \end{align}
        Trailing text.
        """#

        let html = MarkdownRenderer().render(markdown).html.withoutSourceLineMetadata

        #expect(html.contains("<p>Some prose.</p>"))
        #expect(html.contains("math-display"))
        #expect(html.contains("<p>Trailing text.</p>"))
    }

    @Test func unterminatedEnvironmentFallsBackToText() {
        let markdown = #"""
        \begin{align}
        a &= b
        """#

        let body = MarkdownRenderer().render(markdown).body.withoutSourceLineMetadata

        #expect(!body.contains("math-display"))
        #expect(body.contains(#"\begin{align}"#))
    }

    @Test func mismatchedEnvironmentNamesAreNotABlock() {
        let markdown = #"""
        \begin{align}
        a &= b
        \end{gather}
        """#

        let body = MarkdownRenderer().render(markdown).body.withoutSourceLineMetadata

        #expect(!body.contains("math-display"))
        #expect(body.contains(#"\end{gather}"#))
    }

    @Test func engineRejectedEnvironmentIsReportedRatherThanMangled() {
        let markdown = #"""
        \begin{eqnarray}
        a &=& b
        \end{eqnarray}
        """#

        let body = MarkdownRenderer().render(markdown).body.withoutSourceLineMetadata

        // Recognized, then handed to the engine so its refusal is reported in place
        // instead of the source being read as ordinary prose.
        #expect(body.contains(#"<div class="math math-display">"#))
        #expect(body.contains(#"\begin{eqnarray}"#))
        #expect(!body.contains("<p>"))
    }

    @Test func labeledEnvironmentIsNumberedAndRegistered() {
        let markdown = #"""
        \begin{equation}
        E = mc^2 \label{eq:energy}
        \end{equation}
        """#

        let body = MarkdownRenderer().render(markdown).body.withoutSourceLineMetadata

        #expect(body.contains(#"<span class="eq-number">(1)</span>"#))
        #expect(body.contains(#"id="eq:energy""#))
        // The label command must not reach the engine.
        #expect(!body.contains(#"\label"#))
    }

    @Test func forwardReferenceAboveLabeledEnvironmentResolves() {
        let markdown = #"""
        See \ref{eq:energy} above.

        \begin{equation}
        E = mc^2 \label{eq:energy}
        \end{equation}
        """#

        let body = MarkdownRenderer().render(markdown).body.withoutSourceLineMetadata

        #expect(body.contains(##"<a class="cross-ref" href="#eq:energy">1</a>"##))
        #expect(!body.contains(#"\ref{eq:energy}"#))
    }

    @Test func numberAllEquationsSettingNumbersUnlabeledEnvironment() {
        let markdown = #"""
        \begin{equation}
        E = mc^2
        \end{equation}
        """#

        let body = MarkdownRenderer().render(markdown, config: RenderConfig(numberAllEquations: true))
            .body.withoutSourceLineMetadata

        #expect(body.contains(#"<span class="eq-number">(1)</span>"#))
    }

    @Test func footnoteShapedLineInsideEnvironmentIsNotADefinition() {
        let markdown = #"""
        \begin{align}
        a &= b \\
        [^x]: not a footnote
        \end{align}
        """#

        let body = MarkdownRenderer().render(markdown).body.withoutSourceLineMetadata

        #expect(body.contains("math-display"))
        #expect(!body.contains("fn-"))
    }

    @Test func unlabeledEnvironmentIsUnnumberedByDefault() {
        let markdown = #"""
        \begin{equation}
        E = mc^2
        \end{equation}
        """#

        let body = MarkdownRenderer().render(markdown).body.withoutSourceLineMetadata

        #expect(body.contains("math-display"))
        #expect(!body.contains("eq-number"))
    }

    @Test func environmentInsideFencedCodeStaysLiteral() {
        let markdown = #"""
        ```
        \begin{align}
        \end{align}
        ```
        """#

        let body = MarkdownRenderer().render(markdown).body.withoutSourceLineMetadata

        #expect(!body.contains("class=\"math"))
        #expect(body.contains(#"\begin{align}"#))
    }

    @Test func indentedEnvironmentIsCodeNotMath() {
        // Indented code is checked ahead of math in the render walk, so a
        // four-space-indented environment stays code.
        let markdown = "    \\begin{align}\n    a &= b\n    \\end{align}"

        let body = MarkdownRenderer().render(markdown).body.withoutSourceLineMetadata

        #expect(body.contains("<pre><code>"))
        #expect(!body.contains("math-display"))
    }

    @Test func forwardReferenceIntoQuotedEnvironmentResolves() {
        // `\ref{}` resolves after the render walk has numbered every container,
        // so a reference above a quoted environment reaches it.
        let markdown = #"""
        See \ref{eq:q}.

        > \begin{equation}
        > E = mc^2 \label{eq:q}
        > \end{equation}
        """#

        let body = MarkdownRenderer().render(markdown).body.withoutSourceLineMetadata

        #expect(body.contains(#"<div class="numbered-equation" id="eq:q">"#))
        #expect(body.contains(##"<a class="cross-ref" href="#eq:q">1</a>"##))
        #expect(!body.contains(#"\ref{eq:q}"#))
    }
}
