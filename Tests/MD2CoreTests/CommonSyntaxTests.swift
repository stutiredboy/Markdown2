import Foundation
import Testing
@testable import MD2Core
@testable import MD2App

/// Every character in the normative boundary set, not just range endpoints:
/// a character dropped from the middle of a range fails here even though its
/// range endpoints still pass.
///
/// Value: protects=every character in the normative boundary set terminates a bare URL and is a valid left boundary; fails_when=a mid-range character is dropped from the shared constant so endpoint samples still pass; why_new=the previous table sampled only 24 range endpoints; seam=none; no_claim=green proves literal characters only, not the entity spellings that stay literal by design.
private let bareURLBoundarySamples: [(label: String, character: Character)] = {
    let ranges: [(name: String, range: ClosedRange<UInt32>)] = [
        ("middle dot", 0x00B7...0x00B7),
        ("en/em dash", 0x2013...0x2014),
        ("curly quote", 0x2018...0x201D),
        ("ellipsis", 0x2026...0x2026),
        ("ideographic punctuation", 0x3001...0x3003),
        ("CJK angle/corner bracket", 0x3008...0x3011),
        ("CJK tortoise-shell bracket", 0x3014...0x301F),
        ("wavy dash", 0x3030...0x3030),
        ("part alternation mark", 0x303D...0x303D),
        ("katakana middle dot", 0x30FB...0x30FB),
        ("fullwidth ASCII punctuation A", 0xFF01...0xFF0F),
        ("fullwidth ASCII punctuation B", 0xFF1A...0xFF20),
        ("fullwidth ASCII punctuation C", 0xFF3B...0xFF40),
        ("fullwidth ASCII punctuation D", 0xFF5B...0xFF65),
        ("zero width space", 0x200B...0x200B)
    ]
    var samples: [(label: String, character: Character)] = []
    for (name, range) in ranges {
        for value in range {
            let codePoint = String(format: "U+%04X", value)
            samples.append((label: "\(codePoint) \(name)", character: Character(Unicode.Scalar(value)!)))
        }
    }
    return samples
}()

private let bareURLTerminatorSamples = bareURLBoundarySamples.filter {
    !MarkdownRenderer.bareURLStructuralLookalikes.contains($0.character)
}

struct CommonSyntaxTests {
    private let renderer = MarkdownRenderer()
    private let enabled = RenderConfig(inlineFeatures: .init(highlight: true, superscript: true, subscriptEnabled: true))

    @Test func referenceFormsNormalizationAndFirstDefinition() {
        let body = renderer.render("""
        [full][  FOO   bar ] [Foo bar][] [foo bar] [ẞ] [unknown]

        [foo bar]: <https://example.com/a_(b)> "A &amp; B"
        [FOO BAR]: /ignored
        [SS]: /unicode
        """).body
        #expect(body.components(separatedBy: "href=\"https://example.com/a_(b)\"").count == 4)
        #expect(body.contains("title=\"A &amp; B\""))
        #expect(body.contains("href=\"/unicode\">ẞ</a>"))
        #expect(body.contains("[unknown]"))
        #expect(!body.contains("/ignored"))
        #expect(!body.contains("[foo bar]:"))
    }

    @Test func multilineDefinitionsEscapesAndImages() {
        let body = renderer.render(#"""
        [label][foo bar] [escaped][a\]] ![Logo][image]

        [foo
          bar]:
          /url(a)
          'line one
        line two'
        [a\]]: /escaped\(url\)
        [image]: assets/logo.png "Logo"
        """#).body
        #expect(body.contains("href=\"/url(a)\" title=\"line one\nline two\""))
        #expect(body.contains("href=\"/escaped(url)\""))
        #expect(body.contains("<img src=\"assets/logo.png\" alt=\"Logo\" title=\"Logo\">"))
    }

    @Test func definitionsRespectBlocksAndReservedSyntax() {
        let body = renderer.render("""
        # Heading
        [TOC]

        [before] [inside] [code] [math] [paragraph] [@cite] [^fn]

        > [inside]: /quote
        > [before]

        - [before]: /list

        ```md
        [code]: /code
        ```

        $$
        [math]: /math
        $$

        text
        [paragraph]: /paragraph

        [TOC]: /wrong
        [@cite]: /wrong
        [^fn]: footnote
        """).body
        #expect(body.contains("href=\"/quote\""))
        #expect(body.contains("href=\"/list\""))
        #expect(!body.contains("href=\"/code\""))
        #expect(!body.contains("href=\"/math\""))
        #expect(!body.contains("href=\"/paragraph\""))
        #expect(!body.contains("href=\"/wrong\""))
        #expect(body.contains("footnote-ref"))
        #expect(body.contains("class=\"toc\""))
    }

    @Test func referencesCannotNestOrActivateUnsafeURLs() {
        let body = renderer.render(#"""
        [**bold** and `code`][ok] [outer [inner](/inside)][ok]
        [bad][unsafe] ![bad][unsafe] \[ok] `[ok]` $[ok]$

        [ok]: /safe "\" onclick=\"bad"
        [unsafe]: javascript&#58;alert(1)
        """#).body
        #expect(body.contains("<strong>bold</strong> and <code>code</code></a>"))
        #expect(!body.contains("href=\"javascript"))
        #expect(!body.contains("src=\"javascript"))
        #expect(!body.contains(" onclick=\""))
        #expect(!body.contains("<a href=\"/safe\"><a"))
        #expect(body.contains("<code>[ok]</code>"))
    }

    @Test(arguments: [
        ("https://example.com/a_(b)).", "https://example.com/a_(b)", ")."),
        ("www.example.com/a?!", "http://www.example.com/a", "?!"),
        ("www.example.com/a.b.", "http://www.example.com/a.b", "."),
        ("https://example.com/?a=1&b=2", "https://example.com/?a=1&amp;b=2", ""),
        ("https://example.com/?a=1&amp;b=2", "https://example.com/?a=1&amp;b=2", ""),
        ("https://example.com/a&copy;", "https://example.com/a", "&amp;copy;"),
        ("first.last+tag@example.com", "mailto:first.last+tag@example.com", "")
    ])
    func bareLinks(_ sample: (String, String, String)) {
        let body = renderer.render(sample.0).body
        #expect(body.contains("href=\"\(sample.1)\""), "\(body)")
        #expect(body.contains("</a>\(sample.2)</p>"), "\(body)")
    }

    @Test(arguments: bareURLTerminatorSamples)
    func boundaryCharactersTerminateBareURLs(sample: (label: String, character: Character)) {
        let body = renderer.render("https://example.com/a\(sample.character)tail").body
        #expect(body.contains("<a href=\"https://example.com/a\">https://example.com/a</a>"), "\(sample.label): \(body)")
        #expect(body.contains("</a>\(sample.character)tail"), "\(sample.label): \(body)")
    }

    @Test(arguments: bareURLBoundarySamples)
    func boundaryCharactersPrecedeBareURLs(sample: (label: String, character: Character)) {
        let body = renderer.render("x\(sample.character)https://example.com").body
        #expect(body.contains("<a href=\"https://example.com\">https://example.com</a>"), "\(sample.label): \(body)")
        #expect(body.contains("x\(sample.character)<a href=\"https://example.com\">https://example.com</a>"), "\(sample.label) must stay outside the anchor: \(body)")
    }

    @Test(arguments: [
        ("见 https://example.com/docs，然后继续。", "https://example.com/docs", "，然后继续。"),
        ("见 https://example.com，然后继续。", "https://example.com", "，然后继续。"),
        ("参考 https://zh.wikipedia.org/wiki/北京。", "https://zh.wikipedia.org/wiki/北京", "。"),
        ("https://example.com/wiki/北京，更多", "https://example.com/wiki/北京", "，更多")
    ])
    func cjkPunctuationBoundsReportedBareLinks(sample: (String, String, String)) {
        let (source, destination, tail) = sample
        let body = renderer.render(source).body
        #expect(body.contains("<a href=\"\(destination)\">\(destination)</a>"), "\(body)")
        #expect(body.contains("</a>\(tail)"), "\(body)")
    }

    @Test func cjkBoundariesApplyToWwwAutolinks() {
        let leading = renderer.render("访问www.example.com").body
        #expect(leading.contains("<a href=\"http://www.example.com\">www.example.com</a>"), "\(leading)")

        let trailing = renderer.render("www.example.com。").body
        #expect(trailing.contains("<a href=\"http://www.example.com\">www.example.com</a>"), "\(trailing)")
        #expect(trailing.contains("</a>。</p>"), "\(trailing)")
    }

    @Test func hanAfterAuthorityIsAbsorbedIntoHostname() {
        let path = renderer.render("https://example.com/wiki/北京").body
        #expect(path.contains("<a href=\"https://example.com/wiki/北京\">https://example.com/wiki/北京</a>"), "\(path)")

        let absorbed = renderer.render("https://example.com然后继续").body
        #expect(absorbed.contains("<a href=\"https://example.com然后继续\">https://example.com然后继续</a>"), "\(absorbed)")

        let afterHan = renderer.render("访问https://example.com然后继续").body
        #expect(afterHan.contains("访问<a href=\"https://example.com然后继续\">"), "\(afterHan)")
    }

    @Test func entityEncodedPunctuationKeepsExistingBehavior() {
        let trailing = renderer.render("https://example.com/a&#xff0c;然后").body
        #expect(trailing.contains("<a href=\"https://example.com/a，然后\">"), "\(trailing)")

        let leading = renderer.render("&#xff1a;https://example.com").body
        #expect(!leading.contains("<a href=\"https://example.com\">"), "\(leading)")
    }

    @Test func asciiIdentifierBoundariesStillBlock() {
        let body = renderer.render("abchttps://example.com").body
        #expect(!body.contains("href=\"https://example.com\""), "\(body)")
        #expect(body.contains("abchttps://example.com"), "\(body)")

        let wwwBody = renderer.render("abcwww.example.com").body
        #expect(!wwwBody.contains("href=\"http://www.example.com\""), "\(wwwBody)")
        #expect(wwwBody.contains("abcwww.example.com"), "\(wwwBody)")
    }

    /// Value: protects=the pre-existing ASCII `(` and `_` left boundaries still link bare URLs after the boundary-class rewrite; fails_when=either delimiter is dropped from the lookbehind; why_new=the existing suite covers `*` and `~` but not `(` or `_` as bare-URL left boundaries; seam=none; no_claim=green proves these two delimiters, not every ASCII boundary.
    @Test(arguments: [
        ("(https://example.com)", "(<a href=\"https://example.com\">https://example.com</a>)"),
        ("_https://example.com", "_<a href=\"https://example.com\">https://example.com</a>")
    ])
    func existingASCIILeftBoundariesStillLink(sample: (String, String)) {
        let body = renderer.render(sample.0).body
        #expect(body.contains(sample.1), "\(body)")
    }

    /// Value: protects=full-width Latin letters and digits remain URL content and are not boundary characters; fails_when=the URL body is widened to every U+FF00 code point or the lookbehind accepts them as left boundaries; why_new=the boundary tables cover only punctuation and U+200B, and the spec previously contradicted this behavior; seam=none; no_claim=green proves these two spellings, not every full-width letter or digit.
    @Test func fullwidthLettersAndDigitsAreURLContent() {
        let body = renderer.render("https://example.comＡＢ１２").body
        #expect(body.contains("<a href=\"https://example.comＡＢ１２\">https://example.comＡＢ１２</a>"), "\(body)")

        let leading = renderer.render("Ａhttps://example.com").body
        #expect(!leading.contains("href=\"https://example.com\""), "\(leading)")
        #expect(leading.contains("Ａhttps://example.com"), "\(leading)")
    }

    /// Value: protects=characters outside the normative set stay in URL content and are not left boundaries; fails_when=an accidental range widening in the boundary class includes neighbouring code points; why_new=the inclusion table cannot catch accidental widening; seam=none; no_claim=green proves this one outside character, not every non-normative code point.
    @Test func nonNormativeCharactersStayURLContent() {
        let body = renderer.render("https://example.com/café").body
        #expect(body.contains("<a href=\"https://example.com/café\">"), "\(body)")

        let blocked = renderer.render("éhttps://example.com").body
        #expect(!blocked.contains("href=\"https://example.com\""), "\(blocked)")
    }

    /// Value: protects=code points adjacent to every normative range stay URL content and are not left boundaries; fails_when=an off-by-one range widening includes a neighbouring code point; why_new=the é probe is not adjacent to any range, and the constant/table sync test cannot catch a consistent widening; seam=none; no_claim=green proves these edge neighbours, not every non-normative code point.
    @Test(arguments: ["\u{00B6}", "\u{00B8}", "\u{200C}", "\u{2012}", "\u{2015}", "\u{2017}", "\u{201E}", "\u{2025}", "\u{2027}", "\u{3004}", "\u{3012}", "\u{3013}", "\u{3020}", "\u{302F}", "\u{3031}", "\u{303C}", "\u{303E}", "\u{30FC}", "\u{FF10}", "\u{FF19}", "\u{FF21}", "\u{FF3A}", "\u{FF41}", "\u{FF5A}", "\u{FF66}"] as [Character])
    func adjacentNonNormativeCodePointsStayURLContent(character: Character) {
        let body = renderer.render("https://example.com/a\(character)tail").body
        #expect(body.contains("<a href=\"https://example.com/a\(character)tail\">"), "\(body)")

        let blocked = renderer.render("x\(character)https://example.com").body
        #expect(!blocked.contains("href=\"https://example.com\""), "\(blocked)")
    }

    /// Value: protects=supplementary-plane Han is a valid left boundary, not only the BMP block; fails_when=the lookbehind is narrowed to a BMP-only Han range; why_new=all existing Han probes are BMP; seam=none; no_claim=green proves this one supplementary ideograph, not the whole Han script.
    @Test func supplementaryHanIsAValidLeftBoundary() {
        let body = renderer.render("\u{20000}https://example.com").body
        #expect(body.contains("\u{20000}<a href=\"https://example.com\">https://example.com</a>"), "\(body)")
    }

    /// Value: protects=full-width structural lookalikes are valid left boundaries but stay URL content, so a lookalike cannot retarget a link to a shorter host; fails_when=the URL body terminates at one of them again; why_new=the terminator table covers prose punctuation, not the host-deception case; seam=none; no_claim=green proves these five lookalikes, not every full-width code point.
    @Test(arguments: ["．", "／", "＃", "＠", "？"] as [Character])
    func structuralLookalikesStayURLContent(character: Character) {
        let deception = renderer.render("https://evil.com\(character)trusted.com").body
        #expect(!deception.contains("<a href=\"https://evil.com\">"), "\(deception)")

        let path = renderer.render("https://example.com/a\(character)tail").body
        #expect(path.contains("<a href=\"https://example.com/a\(character)tail\">"), "\(path)")

        let leading = renderer.render("\(character)https://example.com").body
        #expect(leading.contains("<a href=\"https://example.com\">https://example.com</a>"), "\(leading)")
    }

    /// Value: protects=the boundary constant and the exhaustive test table stay in sync; fails_when=a character is added to one but not the other; why_new=the test table re-encodes the ranges independently; seam=bareURLBoundaryCharacters (non-test callers: 1, via protectBareAutolinks); no_claim=green proves set equality, not that both regex classes use the constant.
    @Test func boundaryConstantMatchesSampleTable() {
        let samples = Set(bareURLBoundarySamples.map(\.character))
        #expect(samples == Set(MarkdownRenderer.bareURLBoundaryCharacters))
    }

    /// Value: protects=the bare-URL left-boundary widening leaves the email alternative unchanged, so Han before an address prevents a mailto link; fails_when=Han or the boundary set is merged into the email lookbehind; why_new=only the positive standalone email row exists; seam=none; no_claim=green proves this Han-adjacent spelling only, not every boundary character before an email.
    @Test func hanBeforeEmailLeavesItUnlinked() {
        let adjacent = renderer.render("访问foo@example.com").body
        #expect(!adjacent.contains("href=\"mailto:foo@example.com\""), "\(adjacent)")
        #expect(adjacent.contains("访问foo@example.com"), "\(adjacent)")

        let standalone = renderer.render("foo@example.com").body
        #expect(standalone.contains("href=\"mailto:foo@example.com\""), "\(standalone)")

        let punctuation = renderer.render("，foo@example.com").body
        #expect(punctuation.contains("href=\"mailto:foo@example.com\""), "\(punctuation)")
    }

    @Test func autolinksRespectBoundariesAndProtectedContent() {
        let body = renderer.render(#"""
        `https://code.example.com` $https://math.example.com$
        [https://label.example.com](https://target.example.com)
        [https://reference.example.com][ref]
        ![https://image.example.com](image.png)
        abcwww.example.com www.bad_domain.com
        https://example.com`code` https://example.com<em>end</em>

        [ref]: https://target.example.com
        """#).body
        #expect(!body.contains("href=\"https://code.example.com\""))
        #expect(!body.contains("href=\"https://math.example.com\""))
        #expect(!body.contains("href=\"https://label.example.com\""))
        #expect(!body.contains("href=\"https://reference.example.com\""))
        #expect(!body.contains("href=\"https://image.example.com\""))
        #expect(!body.contains("href=\"http://www.bad_domain.com\""))
        #expect(body.contains("</a><code>code</code>"))
        #expect(body.contains("</a><em>end</em>"))
    }

    @Test(arguments: ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"])
    func alerts(_ kind: String) {
        let markdown = "> [!\(kind)]\n> **body**\n>\n> - list"
        let en = renderer.render(markdown)
        let zh = renderer.render(markdown, config: .init(alertLanguage: .simplifiedChinese))
        #expect(en.body.contains("markdown-alert-\(kind.lowercased())"))
        #expect(en.body.contains(">\(kind.capitalized)</p>"))
        #expect(zh.body.contains(">\(AlertLanguage.simplifiedChinese.title(for: kind))</p>"))
        #expect(en.body.contains("<strong>body</strong>"))
        #expect(en.body.contains("data-md2-source-line=\"2\""))
        #expect(en.body.contains("data-md2-source-end-line=\"4\""))
        #expect(!en.body.contains("[!\(kind)]"))
        #expect(en.html.contains("@media print"))
    }

    @Test func ordinaryQuotesAndCodeRemainLiteral() {
        let body = renderer.render("> [!UNKNOWN]\n> body\n\n> [!NOTE] inline\n\n```\n> [!NOTE]\n```").body
        #expect(!body.contains("class=\"markdown-alert"))
        #expect(body.contains("[!UNKNOWN]"))
        #expect(body.contains("[!NOTE] inline"))
    }

    @Test func optionalSyntaxDefaultsAndPrecedence() {
        let markdown = #"==高亮== x^2^ H~2~O ~~删除~~ `==code==` $x^2$ \==literal== X~long\ text~"#
        let off = renderer.render(markdown).body
        let on = renderer.render(markdown, config: enabled).body
        #expect(off.contains("==高亮== x^2^ H~2~O"))
        #expect(on.contains("<mark>高亮</mark> x<sup>2</sup> H<sub>2</sub>O"))
        #expect(on.contains("<del>删除</del>"))
        #expect(on.contains("<code>==code==</code>"))
        #expect(on.contains("==literal=="))
        #expect(on.contains("X<sub>long text</sub>"))
        #expect(!on.contains("<sup>2</sup>$"))
    }

    @Test func optionalSyntaxInFootnotesAndReferenceLabels() {
        let body = renderer.render("[==label==][a] note[^n]\n\n[a]: /a\n[^n]: ==note== H~2~O", config: enabled).body
        #expect(body.contains("<mark>label</mark></a>"))
        #expect(body.contains("<mark>note</mark> H<sub>2</sub>O"))
    }

    @Test func multilineLabelsCodeRunsAndStyledAutolinks() {
        let body = renderer.render("""
        [text][foo
          bar] **https://example.com** ~~www.example.com~~
        ``code ` https://code.example.com [text][foo bar]``

        [foo bar]: /target
        """).body
        #expect(body.contains("<a href=\"/target\">text</a>"))
        #expect(body.contains("<strong><a href=\"https://example.com\">https://example.com</a></strong>"))
        #expect(body.contains("<del><a href=\"http://www.example.com\">www.example.com</a></del>"))
        #expect(body.contains("<code>code ` https://code.example.com [text][foo bar]</code>"))
    }

    @Test func inlineLinkLabelsUseOptionalStylesWithoutChangingDestinations() {
        let body = renderer.render("[==highlight== H~2~O x^2^](/path/==literal==)", config: enabled).body
        #expect(body.contains("href=\"/path/==literal==\"><mark>highlight</mark> H<sub>2</sub>O x<sup>2</sup></a>"))
        let angled = renderer.render("[https://label.example.com](<https://target.example.com>)").body
        #expect(angled.contains("<a href=\"https://target.example.com\">https://label.example.com</a>"))
    }

    @Test func definitionLabelLimitAndInvalidDefinitionsStayVisible() {
        let allowed = String(repeating: "a", count: 999)
        let tooLong = allowed + "a"
        let body = renderer.render("[\(allowed)] [\(tooLong)]\n\n[\(allowed)]: /ok\n[\(tooLong)]: /bad\n\n[invalid]: /url \"title\" extra").body
        #expect(body.contains("href=\"/ok\""))
        #expect(!body.contains("href=\"/bad\""))
        #expect(body.contains("[invalid]: /url &quot;title&quot; extra"))
    }

    @Test func exampleREADMEExercisesCommonSyntax() throws {
        let markdown = try String(contentsOf: Fixtures.url("../../Examples/CommonSyntax.md"), encoding: .utf8)
        let rendered = renderer.render(markdown, config: enabled)
        for kind in ["note", "tip", "important", "warning", "caution"] {
            #expect(rendered.body.contains("markdown-alert-\(kind)"))
        }
        #expect(rendered.body.contains("<mark>高亮文字</mark>"))
        #expect(rendered.body.contains("mailto:hello@example.com"))
        #expect(rendered.body.contains("href=\"https://example.com/docs\" title=\"文档\""))
        #expect(rendered.body.contains("[missing]"))
        #expect(!rendered.body.contains("[docs]:"))
    }
}

@MainActor
struct CommonSyntaxSettingsTests {
    @Test func independentPersistentSettingsAndLanguage() async {
        let name = "SyntaxSettings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.inlineFeatures == .init())
        settings.enablesHighlight = true
        settings.enablesSubscript = true
        settings.language = .zhHans
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.inlineFeatures == .init(highlight: true, subscriptEnabled: true))
        #expect(reloaded.alertLanguage == .simplifiedChinese)
        let store = DocumentStore(syntaxConfigProvider: { (reloaded.inlineFeatures, reloaded.alertLanguage) })
        store.text = "> [!NOTE]\n> ==body== H~2~O x^2^"
        store.reRenderForSettingsChange()
        await store.flushPendingRender()
        #expect(store.rendered.body.contains(">注意</p>"))
        #expect(store.rendered.body.contains("<mark>body</mark> H<sub>2</sub>O x^2^"))
        reloaded.enablesHighlight = false
        reloaded.enablesSuperscript = true
        store.reRenderForSettingsChange()
        await store.flushPendingRender()
        #expect(store.rendered.body.contains("==body== H<sub>2</sub>O x<sup>2</sup>"))
    }
}
