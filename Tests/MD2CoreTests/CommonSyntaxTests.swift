import Foundation
import Testing
@testable import MD2Core
@testable import MD2App

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
