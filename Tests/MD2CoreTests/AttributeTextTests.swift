import Foundation
import Testing
@testable import MD2Core

/// Image `alt` and link `title` are attribute values. Protected inline
/// constructs inside them keep their authored spelling instead of splicing
/// renderer markup into the attribute, while escapes and entities resolve to
/// the literal they stand for.
struct AttributeTextTests {
    private static let bibliography = BibTeXParser.parse("""
    @article{smith2023, author = {Jane Smith}, title = {On Things}, year = {2023} }
    """)

    private let renderer = MarkdownRenderer()

    /// Every `<img>` and `<a>` start tag, and how many of them are well formed:
    /// each attribute value is double-quoted and free of `<`, `>`, and `"`.
    private func startTags(in html: String) -> (all: Int, wellFormed: Int) {
        let range = NSRange(html.startIndex..., in: html)
        let all = try! NSRegularExpression(pattern: #"<(?:img|a)\b"#).numberOfMatches(in: html, range: range)
        let wellFormed = try! NSRegularExpression(
            pattern: #"<(?:img|a)(?:\s+[a-z0-9-]+="[^"<>]*")*>"#
        ).numberOfMatches(in: html, range: range)
        return (all, wellFormed)
    }

    /// Value: protects=alt/title hold the authored spelling of every protected construct and stay well-formed attributes; fails_when=a protect call site falls back to its rendered fragment as the source, or alt/title stop reading attribute text, so `<span class="…">` or `<a href="…">` splices into the attribute and ends it early; why_new=no test covered protected constructs inside alt/title (the D4 tests pin only token boundaries); seam=none; no_claim=green proves these constructs only, not emphasis delimiters, which stay literal in alt as before.
    ///
    /// The second argument is the title spelling. It differs only for `\(x\)`:
    /// paren math never opens inside a link destination, so in a title `\(`
    /// and `\)` are escaped parentheses.
    @Test(arguments: [
        ("`x`", "`x`"),
        ("$x$", "$x$"),
        (#"\(x\)"#, "(x)"),
        (#"<span title="q">s</span>"#, #"<span title="q">s</span>"#),
        ("<https://x.example>", "<https://x.example>"),
        (#"\ref{fig:f}"#, #"\ref{fig:f}"#),
        ("@smith2023", "@smith2023")
    ])
    func protectedConstructKeepsAuthoredSpellingInAltAndTitle(_ construct: String, _ titleText: String) {
        let markdown = """
        ![a \(construct) b](i.png "t \(construct)") [l](https://e.example "t \(construct)")

        ![F](f.png){#fig:f}
        """
        let body = renderer.render(markdown, config: RenderConfig(bibliography: Self.bibliography)).body
        let alt = HTMLEscaping.escape(construct)
        let title = HTMLEscaping.escape(titleText)

        #expect(body.contains(#"<img src="i.png" alt="a \#(alt) b" title="t \#(title)">"#))
        #expect(body.contains(#"<a href="https://e.example" title="t \#(title)">l</a>"#))
        let tags = startTags(in: body)
        #expect(tags.all > 0)
        #expect(tags.wellFormed == tags.all, "\(body)")
    }

    /// A footnote reference cannot sit inside image alt (its `]` ends the alt),
    /// but it can sit inside a title.
    @Test func footnoteReferenceKeepsAuthoredSpellingInTitle() {
        let body = renderer.render("[l](https://e.example \"see [^1]\")\n\n[^1]: note").body
        #expect(body.contains(#"<a href="https://e.example" title="see [^1]">l</a>"#))
    }

    @Test func escapesAndEntitiesResolveInAttributeText() {
        let body = renderer.render(#"![a \* &amp; &copy; \" b](i.png "t \" &amp;")"#).body
        #expect(body.contains(#"<img src="i.png" alt="a * &amp; &copy; &quot; b" title="t &quot; &amp;">"#))
    }

    /// A title is not parsed as inline content, so an image spelled inside it
    /// stays text rather than nesting an `<img>` in the attribute.
    @Test func imageSyntaxInsideTitleStaysText() {
        let body = renderer.render(#"[l](https://e.example "![i](p.png)")"#).body
        #expect(body.contains(#"<a href="https://e.example" title="![i](p.png)">l</a>"#))
    }

    /// The figure caption still renders inline content; only the image's own
    /// alt attribute uses the authored spelling.
    @Test func figureCaptionRendersWhileAltStaysAuthored() {
        let body = renderer.render("![cap $x$ `c`](f.png){#fig:c}").body
        #expect(body.contains(#"<img src="f.png" alt="cap $x$ `c`">"#))
        #expect(body.contains(#"Figure 1: cap <span class="math math-inline">x</span> <code>c</code></figcaption>"#))
    }

    /// Reference images share the inline rule. The old tag-stripping alt lost
    /// literal angle-bracket text because it decoded entities before stripping.
    @Test func referenceImageAltMatchesInlineImageAlt() {
        let body = renderer.render("![a <notatag> b][r] ![c `x` $y$][r]\n\n[r]: i.png").body
        #expect(body.contains(#"<img src="i.png" alt="a &lt;notatag&gt; b">"#))
        #expect(body.contains(#"<img src="i.png" alt="c `x` $y$">"#))
    }

    /// Reference labels match on the authored spelling, so a label holding
    /// math or raw HTML resolves against the definition written the same way.
    @Test func referenceLabelWithMathOrHTMLResolves() {
        let body = renderer.render("[$x$] [a <b>c</b>]\n\n[$x$]: /math\n[a <b>c</b>]: /html").body
        #expect(body.contains(#"<a href="/math"><span class="math math-inline">x</span></a>"#))
        #expect(body.contains(#"<a href="/html">a <b>c</b></a>"#))
    }

    /// Reserved markers are typed text: an image leading a link label is not
    /// the `!` of an alert marker, while a typed `[!x]` stays reserved.
    @Test func leadingImageInLabelIsNotAReservedMarker() {
        let body = renderer.render("[![badge](b.svg)][ci] [!x][ci]\n\n[ci]: https://ci.example").body
        #expect(body.contains(#"<a href="https://ci.example"><img src="b.svg" alt="badge"></a>"#))
        #expect(body.contains("[!x]"))
        #expect(!body.contains(">!x</a>"))
    }

    /// The bare-URL guard reads the alt attribute a broken image shows; the
    /// authored lookalike there still blocks the shorter anchor.
    @Test func lookalikeInAuthoredAltStillBlocksBareURL() {
        for markdown in ["https://evil.com![$.trusted.com$](x.png)", "https://evil.com![`.trusted.com`](x.png)"] {
            let body = renderer.render(markdown).body
            #expect(!body.contains(#"<a href="https://evil.com">"#), "\(markdown)")
        }
    }


    /// Value: protects=every HTML-special character is escaped even when a combining mark joins it into a larger grapheme; fails_when=escaping searches `Character`s (as `String.replacingOccurrences` does), so `"` + U+0301 is not a `"` and stays raw; why_new=no test escaped a special character inside a grapheme cluster; seam=none; no_claim=green proves the five characters with one mark each, not other cluster shapes.
    @Test(arguments: [
        ("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;")
    ])
    func escapingReachesSpecialCharactersJoinedByAMark(_ character: String, _ entity: String) {
        let mark = "\u{0301}"
        #expect(HTMLEscaping.escape("a\(character)\(mark)b").unicodeScalars.elementsEqual("a\(entity)\(mark)b".unicodeScalars))
        #expect(HTMLEscaping.escapeAttribute("'\(mark)\(character)\(mark)").unicodeScalars.elementsEqual("&#39;\(mark)\(entity)\(mark)".unicodeScalars))
        #expect(HTMLEscaping.escape("'\(mark)") == "'\(mark)")
    }

    /// Value: protects=author text cannot close an attribute and add an event handler; fails_when=a `"` that a combining mark joins reaches an href, src or alt unescaped, which a browser reads as the end of the value followed by `onerror=…` or `onmouseover=…`; why_new=the well-formedness check covered protected constructs, not clusters around a quote; seam=none; no_claim=green proves these four attribute paths (bare URL, angle autolink, image alt, link title), not the raw-HTML sanitizer's own attributes.
    @Test(arguments: [
        "see https://a.com/x&quot;\u{0301}/onmouseover=alert(1)// next",
        "<https://a.com/x\"\u{0301}/onmouseover=alert(1)//>",
        "![a\"\u{0301}/onerror=alert(1)//](x.png)",
        "[l](https://e.example \"t\"\u{0301}/onmouseover=alert(1)//\")"
    ])
    func combiningMarkCannotCloseAnAttribute(_ markdown: String) {
        let body = renderer.render(markdown).body
        let tags = startTags(in: body)
        #expect(tags.all > 0, "\(body)")
        #expect(tags.wellFormed == tags.all, "\(body)")
        let scalars = Array(body.unicodeScalars)
        #expect(!zip(scalars, scalars.dropFirst()).contains { $0 == "\"" && $1 == "\u{0301}" }, "\(body)")
        #expect(body.contains("&quot;\u{0301}"), "\(body)")
    }
}
