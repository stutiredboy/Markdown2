import Testing
@testable import MD2Core

struct OutlineBuilderTests {
    @Test func buildsNestedOutlineWithStableUniqueIDs() {
        let markdown = """
        # Intro
        ## Details
        # Intro
        ### 中文标题
        """

        let headings = OutlineBuilder().build(from: markdown)

        #expect(headings == [
            Heading(id: "intro", level: 1, title: "Intro", line: 1),
            Heading(id: "details", level: 2, title: "Details", line: 2),
            Heading(id: "intro-2", level: 1, title: "Intro", line: 3),
            Heading(id: "中文标题", level: 3, title: "中文标题", line: 4)
        ])
    }

    @Test func ignoresHeadingsInsideCodeFences() {
        let markdown = """
        # Real

        ```swift
        # Not a heading
        ```

        ## Also Real
        """

        let headings = OutlineBuilder().build(from: markdown)

        #expect(headings.map(\.title) == ["Real", "Also Real"])
        #expect(headings.map(\.line) == [1, 7])
    }

    @Test func skipsLeadingFrontMatterWhenBuildingOutline() {
        let markdown = """
        ---
        title: Markdown2 Sample
        bibliography: references.bib
        math-macros: { "\\\\RR": "\\\\mathbb{R}" }
        ---

        [TOC]

        # Markdown2 Sample
        ## Citations & Bibliography
        """

        let headings = OutlineBuilder().build(from: markdown)

        #expect(headings == [
            Heading(id: "markdown2-sample", level: 1, title: "Markdown2 Sample", line: 9),
            Heading(id: "citations-bibliography", level: 2, title: "Citations & Bibliography", line: 10)
        ])
        #expect(!headings.contains { $0.title.contains("math-macros") })
    }
}
