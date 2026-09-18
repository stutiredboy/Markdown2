import Foundation
import Testing
@testable import MD2App
@testable import MD2Core

/// The line-number gutter is a property of the two live surfaces only. Its styles
/// and its render script live in the preview's injected user script, which the
/// shared rendered HTML never contains — so the PDF exporter and the HTML exporter
/// cannot see it. These assertions pin that boundary, because the failure it
/// guards is silent: a gutter that leaked into `rendered.html` would ship numbers
/// into every exported PDF and HTML file with no error anywhere.
struct LineNumberExportIsolationTests {
    private let markdown = """
    # Heading

    Body paragraph with `code` and a [link](https://example.com).

    ```swift
    let x = 1
    ```

    Closing paragraph.
    """

    /// Markers that would exist in exported output if the gutter leaked into the
    /// shared render path.
    private let leakMarkers = [
        "md2-line-gutter",
        "md2-line-numbers",
        "data-md2-gutter",
        "--md2-gutter-width"
    ]

    @Test func renderedHTMLCarriesNoGutterMarkup() {
        let html = MarkdownRenderer().render(markdown).html

        for marker in leakMarkers {
            #expect(!html.contains(marker), "rendered HTML must not contain \(marker)")
        }
    }

    @Test func exportedHTMLCarriesNoGutterMarkup() {
        let rendered = MarkdownRenderer().render(markdown)
        let exported = SelfContainedHTMLBuilder.build(html: rendered.html, baseURL: nil)

        for marker in leakMarkers {
            #expect(!exported.contains(marker), "exported HTML must not contain \(marker)")
        }
    }

    @Test func theGutterScriptIsNeverPartOfRenderedHTML() {
        let html = MarkdownRenderer().render(markdown).html
        let enabled = MarkdownPreviewView.lineNumberGutterScript(showsLineNumbers: true)
        let disabled = MarkdownPreviewView.lineNumberGutterScript(showsLineNumbers: false)

        // Distinct code, so the assertions below cannot pass on an empty string.
        #expect(!enabled.isEmpty)
        #expect(enabled.contains("__md2RenderLineNumbers"))

        #expect(!html.contains(enabled))
        #expect(!html.contains(MarkdownPreviewView.lineNumberGutterScript(showsLineNumbers: false)))
        // A distinctive fragment, independent of the boolean interpolated at the end.
        #expect(!html.contains("__md2RenderLineNumbers"))
    }

    @Test func renderedHTMLDoesNotDependOnTheLineNumberPreference() {
        // The renderer has no line-number input, which is what makes the
        // preference structurally unable to reach an export. If a render flag is
        // ever added, this fails and the export path must be re-audited.
        let rendered = MarkdownRenderer().render(markdown)
        let config = RenderConfig()

        #expect(rendered.html == MarkdownRenderer().render(markdown, config: config).html)
        #expect(rendered.body == MarkdownRenderer().render(markdown, config: config).body)
    }

    @Test func theGutterStyleIsGatedBehindItsSwitchClass() {
        // Defense in depth: every gutter style rule is scoped under
        // `html.md2-line-numbers`, so even a leaked stylesheet stays inert — the
        // class is only ever set by the preview script.
        let script = MarkdownPreviewView.lineNumberGutterScript(showsLineNumbers: true)

        #expect(script.contains("html.md2-line-numbers .md2-line-gutter"))
        #expect(script.contains("html.md2-line-numbers main"))

        // The layer is hidden unless the switch class is present.
        #expect(script.contains(".md2-line-gutter{position:absolute;inset:0;pointer-events:none;display:none;}"))

        // Every position rule mentions the class; none is a bare selector that
        // would apply to a rendered document on its own.
        for styleRule in script.split(separator: "' +") where styleRule.contains("padding-left") {
            #expect(
                styleRule.contains("html.md2-line-numbers"),
                "an ungated rule could leak: \(styleRule)"
            )
        }
    }

    @Test func theGutterDigitsAreGeneratedContentNotText() {
        // The digits come from `content: attr(...)`, so the layer holds no text
        // nodes: find, selection, and copy cannot see them even in the preview.
        let script = MarkdownPreviewView.lineNumberGutterScript(showsLineNumbers: true)

        #expect(script.contains("content:attr(data-md2-gutter)"))
        #expect(!script.contains("textContent = String"))
    }
}
