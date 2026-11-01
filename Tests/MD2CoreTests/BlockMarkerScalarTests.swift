import Foundation
import Testing
@testable import MD2Core

/// Block markers and link-reference syntax are ASCII, and CommonMark reads them
/// by code point. A joining scalar right after a marker (a combining mark, ZWJ,
/// a variation selector or a spacing mark) fuses with the marker's last
/// character into one grapheme, and a `Character` comparison then stops seeing
/// the marker: `# ` + U+0301 rendered a paragraph, `- [ ] ` + U+0301 a list item
/// without a checkbox. These pin that a joiner changes no structure a letter in
/// the same place would not, and that the joiner itself stays in the content.
struct BlockMarkerScalarTests {
    private let renderer = MarkdownRenderer()

    private static let joiners: [(name: String, scalar: String)] = [
        ("combining acute", "\u{0301}"),
        ("zero-width joiner", "\u{200D}"),
        ("variation selector", "\u{FE0F}"),
        ("Devanagari vowel sign", "\u{093F}")
    ]

    /// `{X}` marks where the joiner (or, for comparison, a letter) goes.
    private static let constructs: [(name: String, template: String)] = [
        ("ATX heading", "# {X}word"),
        ("ATX heading with closing sequence", "## {X}word ##"),
        ("dash bullet", "- {X}word"),
        ("star bullet", "* {X}word"),
        ("plus bullet", "+ {X}word"),
        ("blockquote without a space", ">{X}word"),
        ("list inside a blockquote", "> - {X}word"),
        ("open task", "- [ ] {X}word"),
        ("done task", "- [X] {X}word"),
        ("fence info string", "```{X}lang\ncode\n```"),
        ("indented code", "    {X}code"),
        ("nested list item", "- a\n  - {X}word"),
        ("list continuation", "- a\n\n  {X}word"),
        ("dollar display math", "$${X}x$$"),
        ("bracket display math", "\\[{X}x\\]"),
        ("reference label", "[{X}r]\n\n[{X}r]: /u"),
        ("full reference", "[t][{X}r]\n\n[{X}r]: /u"),
        ("image reference", "![{X}r]\n\n[{X}r]: /u.png"),
        ("reference title", "[r]\n\n[r]: /u \"{X}t\"")
    ]

    static let cases: [(construct: String, template: String, joiner: String, scalar: String)] =
        constructs.flatMap { construct in
            joiners.map { (construct.name, construct.template, $0.name, $0.scalar) }
        }

    private func structure(_ html: String) -> [String] {
        let tags = try! NSRegularExpression(pattern: #"<(/?[A-Za-z][A-Za-z0-9]*)"#)
        return tags.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            Range(match.range(at: 1), in: html).map { String(html[$0]).lowercased() }
        }
    }

    /// Value: protects=a joining scalar after a block marker or inside link-reference syntax leaves the block structure a letter would give; fails_when=a marker check compares `Character`s again and the fused grapheme hides the marker (a paragraph instead of a heading, list, quote, code block, math block or reference link); why_new=no test put a joiner after a block marker; seam=none; no_claim=green proves these constructs and joiners, not every block form.
    @Test(arguments: cases)
    func joinerAfterAMarkerKeepsTheStructure(_ sample: (construct: String, template: String, joiner: String, scalar: String)) {
        let withJoiner = renderer.render(sample.template.replacingOccurrences(of: "{X}", with: sample.scalar)).body
        let withLetter = renderer.render(sample.template.replacingOccurrences(of: "{X}", with: "q")).body
        #expect(structure(withJoiner) == structure(withLetter), "\(sample.construct), \(sample.joiner): \(withJoiner)")
        // The joiner shows wherever the letter does (a full reference's key
        // shows in neither).
        let joinerShown = withJoiner.unicodeScalars.contains(sample.scalar.unicodeScalars.first!)
        #expect(joinerShown == withLetter.contains("q"), "\(sample.construct), \(sample.joiner): \(withJoiner)")
    }

    /// Value: protects=dropping a marker keeps the joiner that follows it, so the content starts with it; fails_when=a marker is dropped by `Character`, taking the fused joiner with it; why_new=the structure test cannot see a lost scalar inside a matching tag; seam=none; no_claim=green proves U+0301 in these blocks.
    @Test func droppingAMarkerKeepsTheJoinerAfterIt() {
        let mark = "\u{0301}"
        #expect(renderer.render("# \(mark)word").body.contains(">\(mark)word</h1>"))
        #expect(renderer.render("- \(mark)word").body.contains("<li>\(mark)word</li>"))
        #expect(renderer.render(">\(mark)word").body.contains(">\(mark)word</p>"))
        #expect(renderer.render("- [ ] \(mark)word").body.contains("data-md2-task-line=\"1\"> \(mark)word</li>"))
        #expect(renderer.render("    \(mark)code").body.contains("<code>\(mark)code</code>"))
        #expect(renderer.render("```\(mark)lang\ncode\n```").body.contains("class=\"language-\(mark)lang\""))
        #expect(renderer.render("[\(mark)r]\n\n[\(mark)r]: /u").body.contains("<a href=\"/u\">\(mark)r</a>"))
        // A continuation line that starts with a joiner stays in its item.
        #expect(renderer.render("- a\n\n  \(mark)word").body.contains("<p data-md2-source-line=\"3\">\(mark)word</p>"))
    }

    /// Value: protects=a prepended mark before `[` does not hide a reference link's bracket; fails_when=reference-link bracket pairing iterates `Character`s and the prepend joins `[` into one grapheme; why_new=the joiner cases put the scalar after `[`, not before it; seam=none; no_claim=green proves U+0600 before a shortcut and a full reference.
    @Test func prependBeforeABracketKeepsTheReferenceLink() {
        #expect(renderer.render("x \u{0600}[r]\n\n[r]: /u").body.contains("\u{0600}<a href=\"/u\">r</a>"))
        #expect(renderer.render("x \u{0600}[t][r]\n\n[r]: /u").body.contains("\u{0600}<a href=\"/u\">t</a>"))
    }

    /// Value: protects=the editor and the renderer measure indentation as scalars, so a joiner after the last indent space does not shorten it; fails_when=`MarkdownIndentation.width` counts `Character`s and stops at the fused space; why_new=list nesting and continuation depend on this width but no test fed it a joiner; seam=MarkdownIndentation.width (editor list commands and the renderer); no_claim=green proves spaces and a tab before U+0301.
    @Test func indentationWidthCountsTheSpaceBeforeAJoiner() {
        #expect(MarkdownIndentation.width("  \u{0301}x") == 2)
        #expect(MarkdownIndentation.width("\t \u{0301}x") == 5)
    }
}
