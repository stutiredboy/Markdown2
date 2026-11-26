import Testing
@testable import MD2Core

/// Verifies the renderer's `data-md2-source-line` / `data-md2-source-end-line`
/// block metadata that mode-switch anchoring maps preview blocks back to
/// editor source lines with.
struct SourceLineMetadataTests {
    @Test func headingsAndParagraphsCarrySourceLines() {
        let markdown = """
        # Title

        Paragraph one
        spans two lines.

        Second paragraph.
        """

        let html = MarkdownRenderer().render(markdown).html

        #expect(html.contains(#"<h1 id="title" data-md2-source-line="1">Title</h1>"#))
        #expect(html.contains(#"<p data-md2-source-line="3" data-md2-source-end-line="4">"#))
        #expect(html.contains(#"<p data-md2-source-line="6">Second paragraph.</p>"#))
    }

    @Test func rawHTMLBlocksCarryTheirOwnSourceLines() {
        let markdown = """
        Heading text

        `literal <div>
        still code`
        <div>First block</div>
        <div title="a &gt; b" data-md2-source-line="99"><span>Second block</span></div>

        > <details open>
        > <summary>Disclosure</summary>
        > </details>
        """

        let body = MarkdownRenderer().render(markdown).body

        #expect(body.contains("<code>literal &lt;div&gt; still code</code>"))
        #expect(body.contains(#"<div data-md2-source-line="5">First block</div>"#))
        #expect(body.contains(#"<div title="a &gt; b" data-md2-source-line="6"><span>Second block</span></div>"#))
        #expect(body.contains(#"<details open data-md2-source-line="8">"#))
        #expect(body.contains(#"<summary data-md2-source-line="9">Disclosure</summary>"#))
        #expect(!body.contains(#"data-md2-source-line="99""#))
    }

    @Test func longCodeBlockCarriesFullSpan() {
        let code = (1...40).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let markdown = """
        # Title

        ```swift
        \(code)
        ```
        """

        let html = MarkdownRenderer().render(markdown).html

        // Fence opens on line 3 and closes on line 44 (40 code lines between).
        #expect(html.contains(#"<pre data-md2-source-line="3" data-md2-source-end-line="44">"#))
    }

    @Test func hashLinesInsideCodeFenceAreNotHeadingAnchors() {
        let markdown = """
        # Real heading

        ```bash
        # not a heading
        echo done
        ```
        """

        let document = MarkdownRenderer().render(markdown)

        #expect(document.outline.count == 1)
        #expect(document.outline.first?.id == "real-heading")
        // The `#` line stays code: no heading element/anchor is created for it.
        #expect(!document.html.contains("not-a-heading"))
        #expect(document.html.contains(#"<pre data-md2-source-line="3" data-md2-source-end-line="6">"#))
        #expect(document.html.contains("# not a heading"))
    }

    @Test func listsTablesAndRulesCarrySourceLines() {
        let markdown = """
        - first
        - second

        | A | B |
        | --- | --- |
        | 1 | 2 |

        ---
        """

        let html = MarkdownRenderer().render(markdown).html

        #expect(html.contains(#"<ul data-md2-source-line="1" data-md2-source-end-line="2">"#))
        #expect(html.contains(#"<table data-md2-source-line="4" data-md2-source-end-line="6">"#))
        #expect(html.contains(#"<hr data-md2-source-line="8">"#))
    }

    @Test func blockquoteAndNestedContentCarryAbsoluteLines() {
        let markdown = """
        # Title

        > quoted line one
        > quoted line two
        """

        let html = MarkdownRenderer().render(markdown).html

        #expect(html.contains(#"<blockquote data-md2-source-line="3" data-md2-source-end-line="4">"#))
        // The paragraph nested inside the quote keeps document-absolute lines.
        #expect(html.contains(#"<p data-md2-source-line="3" data-md2-source-end-line="4">"#))
    }

    @Test func displayMathAndDiagramBlocksCarrySourceLines() {
        let markdown = """
        $$
        a^2 + b^2 = c^2
        $$

        ```mermaid
        graph TD; A-->B;
        ```
        """

        let html = MarkdownRenderer().render(markdown).html

        #expect(html.contains(#"<div class="math math-display" data-md2-source-line="1" data-md2-source-end-line="3">"#))
        #expect(html.contains(#"<div class="diagram diagram-mermaid diagram-pending" data-md2-source-line="5" data-md2-source-end-line="7">"#))
    }

    @Test func footnoteItemsCarryDefinitionSourceLine() {
        let markdown = """
        Body text with a note.[^a]

        [^a]: The note text.
        """

        let html = MarkdownRenderer().render(markdown).html

        #expect(html.contains(#"<li id="fn-a" data-md2-source-line="3">"#))
    }

    @Test func setextHeadingCarriesTwoLineSpan() {
        let markdown = """
        Title Text
        ==========
        """

        let html = MarkdownRenderer().render(markdown).html

        #expect(html.contains(#"<h1 id="title-text" data-md2-source-line="1" data-md2-source-end-line="2">"#))
    }

    @Test func taskCheckboxesAreEnabledAndCarryTheirItemSourceLines() {
        let markdown = """
        # Title

        - [ ] first
        - [x] second
            - [ ] nested child
        """

        let html = MarkdownRenderer().render(markdown).html

        #expect(html.contains(#"<input type="checkbox" data-md2-task-line="3"> first"#))
        #expect(html.contains(#"<input type="checkbox" data-md2-task-line="4" checked> second"#))
        #expect(html.contains(#"<input type="checkbox" data-md2-task-line="5"> nested child"#))
        // Enabled so a preview click can toggle; only task items carry inputs.
        #expect(!html.contains(#"<input type="checkbox" disabled"#))
    }

    @Test func blockquotedTaskItemsCarryAbsoluteTaskLines() {
        let markdown = """
        # Title

        > intro line
        > - [ ] quoted task
        """

        let html = MarkdownRenderer().render(markdown).html

        #expect(html.contains(#"<input type="checkbox" data-md2-task-line="4"> quoted task"#))
    }

    @Test func nonTaskListItemsCarryNoTaskLineAttribute() {
        let markdown = """
        - plain item
        1. ordered item
        """

        let html = MarkdownRenderer().render(markdown).html

        #expect(!html.contains("data-md2-task-line"))
        #expect(!html.contains("<input"))
    }

    @Test func sourceLineAttributesDoNotLeakIntoVisibleText() {
        let html = MarkdownRenderer().render("Plain paragraph.").html

        #expect(html.contains(#"<p data-md2-source-line="1">Plain paragraph.</p>"#))
        #expect(!html.contains("data-md2-source-line=\"1\">data-md2"))
    }
}
