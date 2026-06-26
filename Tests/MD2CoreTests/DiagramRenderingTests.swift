import Testing
@testable import MD2Core

struct DiagramRenderingTests {
    // MARK: Diagram blocks (3.x)

    @Test func rendersMermaidPlaceholder() {
        let markdown = """
        ```mermaid
        graph TD; A-->B;
        ```
        """

        let html = MarkdownRenderer().render(markdown).html.withoutSourceLineMetadata

        // The placeholder starts in the source-hiding pending state and carries
        // the verbatim (HTML-escaped) source for the engine to read.
        #expect(html.contains(#"<div class="diagram diagram-mermaid diagram-pending">graph TD; A--&gt;B;</div>"#))
        // The diagram source is not emitted as a code block.
        #expect(!html.contains("language-mermaid"))
    }

    @Test func diagramPlaceholderStartsPendingWithVerbatimSource() {
        // Each diagram kind emits the pending state while keeping its source.
        let cases: [(String, String)] = [
            ("mermaid", "diagram-mermaid"),
            ("flow", "diagram-flow"),
            ("sequence", "diagram-sequence"),
        ]

        for (info, cssClass) in cases {
            let html = MarkdownRenderer().render("""
            ```\(info)
            graph TD; A-->B;
            ```
            """).html.withoutSourceLineMetadata

            #expect(html.contains(#"<div class="diagram \#(cssClass) diagram-pending">"#))
            // The verbatim source survives so the engine can render it.
            #expect(html.contains("graph TD; A--&gt;B;"))
        }
    }

    @Test func rendersFlowchartPlaceholder() {
        let markdown = """
        ```flow
        st=>start: Start
        e=>end: End
        st->e
        ```
        """

        let html = MarkdownRenderer().render(markdown).html.withoutSourceLineMetadata

        #expect(html.contains(#"<div class="diagram diagram-flow diagram-pending">"#))
        #expect(html.contains("st=&gt;start: Start"))
        #expect(html.contains("st-&gt;e"))
    }

    @Test func rendersSequencePlaceholder() {
        let markdown = """
        ```sequence
        Alice->Bob: Hi
        Bob-->Alice: Hello
        ```
        """

        let html = MarkdownRenderer().render(markdown).html.withoutSourceLineMetadata

        #expect(html.contains(#"<div class="diagram diagram-sequence diagram-pending">"#))
        #expect(html.contains("Alice-&gt;Bob: Hi"))
        #expect(html.contains("Bob--&gt;Alice: Hello"))
    }

    @Test func diagramInfoStringIsCaseInsensitive() {
        let markdown = """
        ```Mermaid
        graph TD; A-->B;
        ```
        """

        let document = MarkdownRenderer().render(markdown)

        #expect(document.html.contains(#"class="diagram diagram-mermaid diagram-pending""#))
    }

    @Test func diagramSourceIsVerbatimAndNotMarkdownProcessed() {
        // Underscores/asterisks in diagram source must reach the engine literally.
        let markdown = """
        ```mermaid
        graph LR; _a_-->*b*;
        ```
        """

        let html = MarkdownRenderer().render(markdown).html.withoutSourceLineMetadata

        // The verbatim, HTML-escaped source proves no inline Markdown ran: the
        // underscores/asterisks survive instead of becoming <em>/<strong>.
        #expect(html.contains(#"<div class="diagram diagram-mermaid diagram-pending">graph LR; _a_--&gt;*b*;</div>"#))
    }

    // MARK: Non-diagram fences stay code (3.3 / spec: no interference)

    @Test func swiftFenceStaysCodeBlock() {
        let markdown = """
        ```swift
        let a = 1
        ```
        """

        let document = MarkdownRenderer().render(markdown)

        #expect(document.html.contains("language-swift"))
        #expect(!document.html.contains("class=\"diagram"))
    }

    @Test func plainTextFenceWithDiagramSourceStaysLiteral() {
        let markdown = """
        ```text
        graph TD; A-->B;
        ```
        """

        let html = MarkdownRenderer().render(markdown).html.withoutSourceLineMetadata

        #expect(html.contains("<pre><code"))
        #expect(!html.contains("class=\"diagram"))
    }

    @Test func unlabeledFenceStaysCodeBlock() {
        let markdown = """
        ```
        plain fenced content
        ```
        """

        let html = MarkdownRenderer().render(markdown).html.withoutSourceLineMetadata

        #expect(html.contains("<pre><code>plain fenced content</code></pre>"))
        #expect(!html.contains("class=\"diagram"))
    }

    // MARK: Offline assets / bootstrap presence

    @Test func previewInlinesDiagramEnginesAndBootstrap() {
        let document = MarkdownRenderer().render("""
        ```mermaid
        graph TD; A-->B;
        ```
        """)

        // Bootstrap dispatches per engine.
        #expect(document.html.contains(".diagram-mermaid"))
        #expect(document.html.contains(".diagram-flow"))
        #expect(document.html.contains(".diagram-sequence"))
        // Defensive guards mirror the math bootstrap.
        #expect(document.html.contains("typeof mermaid"))
    }

    @Test func bootstrapRevealsEachEngineAndErrorPath() {
        let document = MarkdownRenderer().render("""
        ```mermaid
        graph TD; A-->B;
        ```
        """)

        // A shared reveal helper drops the pending state and adds the ready class.
        #expect(document.html.contains("function reveal(el)"))
        #expect(document.html.contains(#"el.classList.remove("diagram-pending")"#))
        #expect(document.html.contains(#"el.classList.add("diagram-ready")"#))
        // The error/fallback path reveals too, so failures show source, not blank.
        #expect(document.html.contains("function fail(el, source)"))
        // Mermaid reveals inside its async render callback.
        #expect(document.html.contains("el.innerHTML = result.svg;"))
        // Engines that are unavailable still reveal their source.
        #expect(document.html.contains(#"if (typeof flowchart === "undefined") { reveal(el); continue; }"#))
        #expect(document.html.contains(#"if (typeof Diagram === "undefined") { reveal(sel); continue; }"#))
        #expect(document.html.contains(#"if (typeof mermaid === "undefined")"#))
    }

    // MARK: Export settle signal (offscreen capture waits for async Mermaid)

    @Test func bootstrapExposesDiagramSettleSignalForExport() {
        let html = MarkdownRenderer().render("""
        ```mermaid
        graph TD; A-->B;
        ```
        """).html

        // The export/print pipeline polls this flag to learn when asynchronous
        // Mermaid rendering has finished before snapshotting the offscreen page.
        #expect(html.contains("window.__md2DiagramsSettled"))
        #expect(html.contains("window.__md2DiagramPending"))
        #expect(html.contains("function settleOne()"))
        // Each Mermaid render settles the pending count on both success and failure,
        // so a failing diagram still lets the pass settle (it falls back to source).
        #expect(html.contains(".then(settleOne, settleOne)"))
        // A pass with no outstanding async render settles immediately.
        #expect(html.contains("if (window.__md2DiagramPending === 0) { window.__md2DiagramsSettled = true; }"))
    }

    // MARK: Legibility override is scoped away from Mermaid

    @Test func legibilityOverrideExcludesMermaidAndDropsRevert() {
        // Mermaid manages its own theme — and colors some geometry (e.g.
        // xychart-beta plot lines) via SVG presentation attributes. The preview's
        // legibility override must not touch Mermaid: forcing var(--text) and then
        // reverting it resolves those strokes to the SVG initial `none`, blanking
        // the series. So the override is scoped with :not(.diagram-mermaid), and
        // the old `revert` counter-rules are gone.
        let html = MarkdownRenderer().render("""
        ```mermaid
        graph TD; A-->B;
        ```
        """).html

        // The override is scoped to exclude Mermaid.
        #expect(html.contains(".diagram:not(.diagram-mermaid) text"))
        #expect(html.contains(".diagram:not(.diagram-mermaid) path"))
        // The unscoped override no longer recolors Mermaid geometry: the bare
        // `.diagram text {` / `.diagram path` selectors are gone (the scoped
        // `.diagram:not(.diagram-mermaid) …` form contains neither substring).
        #expect(!html.contains(".diagram text {"))
        #expect(!html.contains(".diagram path,"))
        // The `revert` counter-rules that blanked presentation-attribute strokes
        // are removed entirely.
        #expect(!html.contains("stroke: revert"))
        #expect(!html.contains("fill: revert"))
    }
}
