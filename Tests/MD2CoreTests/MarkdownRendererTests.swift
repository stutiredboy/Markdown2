import Testing
@testable import MD2Core

struct MarkdownRendererTests {
    @Test func rendersCommonMarkdownBlocks() {
        let markdown = """
        # Title

        A **bold** and *soft* [link](https://example.com).

        - [x] Done
        - [ ] Next

        | Name | Value |
        | --- | --- |
        | One | `1` |

        ```swift
        let value = "<safe>"
        ```
        """

        let html = MarkdownRenderer().render(markdown).html.withoutSourceLineMetadata

        #expect(html.contains(#"<h1 id="title">Title</h1>"#))
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("<em>soft</em>"))
        #expect(html.contains(#"<a href="https://example.com">link</a>"#))
        #expect(html.contains(#"<ul class="task-list">"#))
        #expect(html.contains(#"<input type="checkbox" checked>"#))
        #expect(html.contains("<table>"))
        #expect(html.contains("<code>1</code>"))
        #expect(html.contains(#"<code class="language-swift">"#))
        #expect(html.contains(#"<span class="tok-keyword">let</span> value ="#))
        #expect(html.contains(#"<span class="tok-string">&quot;&lt;safe&gt;&quot;</span>"#))
    }

    @Test func rendersTableOfContentsFromHeadings() {
        let markdown = """
        [TOC]

        # Title
        ## Part
        """

        let html = MarkdownRenderer().render(markdown).html.withoutSourceLineMetadata

        #expect(html.contains(#"<nav class="toc">"#))
        #expect(html.contains(##"<a class="toc-level-1" href="#title">Title</a>"##))
        #expect(html.contains(##"<a class="toc-level-2" href="#part">Part</a>"##))
    }

    @Test func escapesHTMLInParagraphs() {
        let document = MarkdownRenderer().render("<script>alert(1)</script>")

        #expect(document.html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(!document.html.contains("<script>alert(1)</script>"))
    }

    @Test func rendersImagesWithoutDoubleEscapingAttributes() {
        let document = MarkdownRenderer().render("![A&B](images/a&b.png)")

        #expect(document.html.contains(#"<img src="images/a&amp;b.png" alt="A&amp;B">"#))
        #expect(!document.html.contains("amp;amp"))
    }

    @Test func infersImageDimensionsFromSizedURLPath() {
        let document = MarkdownRenderer().render(#"![Sample](https://via.placeholder.com/200x100 "Placeholder image")"#)

        #expect(document.html.contains(#"<span class="image-frame" style="width: 200px; aspect-ratio: 200 / 100;"><img src="https://via.placeholder.com/200x100" alt="Sample" title="Placeholder image" width="200" height="100"></span>"#))
    }

    @Test func nestsIndentedUnorderedListItems() {
        let markdown = """
        - 空调
            - 内外机
            - 安装（铜、电缆）
            - 人工
        - 电缆
        - 配电箱
        """

        let document = MarkdownRenderer().render(markdown)

        // 空调 owns a nested child list with its three sub-items.
        #expect(document.html.contains("<li>空调\n<ul>\n<li>内外机</li>"))
        #expect(document.html.contains("<li>人工</li>\n</ul></li>"))
        // 电缆 and 配电箱 are siblings of 空调, after the nested list closes.
        #expect(document.html.contains("</ul></li>\n<li>电缆</li>\n<li>配电箱</li>"))
    }

    @Test func nestsMultipleLevelsOfLists() {
        let markdown = """
        - a
            - b
                - c
        """

        let document = MarkdownRenderer().render(markdown)

        #expect(document.html.contains("<li>a\n<ul>\n<li>b\n<ul>\n<li>c</li>\n</ul></li>\n</ul></li>"))
    }

    @Test func tabIndentedListItemNestsOneLevel() {
        let markdown = "- parent\n\t- child"

        let document = MarkdownRenderer().render(markdown)

        #expect(document.html.contains("<li>parent\n<ul>\n<li>child</li>\n</ul></li>"))
    }

    @Test func twoSpaceIndentedListItemStaysAtCurrentFourSpaceLevel() {
        let markdown = """
        - parent
          - sibling
        """

        let document = MarkdownRenderer().render(markdown)

        #expect(document.html.contains("<li>parent</li>\n<li>sibling</li>"))
        #expect(!document.html.contains("<li>parent\n<ul>"))
    }

    @Test func dedentClosesNestedListAndContinuesParent() {
        let markdown = """
        - a
            - b
        - d
        """

        let document = MarkdownRenderer().render(markdown)

        #expect(document.html.contains("<li>a\n<ul>\n<li>b</li>\n</ul></li>\n<li>d</li>"))
    }

    @Test func nestedTaskListItemsKeepCheckboxes() {
        let markdown = """
        - parent
            - [x] done
        """

        let html = MarkdownRenderer().render(markdown).html.withoutSourceLineMetadata

        #expect(html.contains(#"<ul class="task-list">\#n<li><input type="checkbox" checked> done</li>"#))
        // The outer list has no task item, so it is not a task-list.
        #expect(html.contains("<ul>\n<li>parent"))
    }

    @Test func nestsOrderedListUnderUnorderedItem() {
        let markdown = """
        - parent
            1. step one
            2. step two
        """

        let document = MarkdownRenderer().render(markdown)

        #expect(document.html.contains("<li>parent\n<ol>\n<li>step one</li>\n<li>step two</li>\n</ol></li>"))
    }

    @Test func blankLineSeparatedOrderedListKeepsContinuousNumbering() {
        let markdown = """
        1. first

        2. second

        3. third
        """

        let html = MarkdownRenderer().render(markdown).html.withoutSourceLineMetadata

        // One <ol> spanning all three items, not three lists each restarting at 1.
        #expect(html.contains("<ol>\n<li>first</li>\n<li>second</li>\n<li>third</li>\n</ol>"))
    }

    @Test func markerAlignedBulletsNestUnderOrderedItem() {
        let markdown = """
        1. first
           - detail a
           - detail b
        2. second
        """

        let html = MarkdownRenderer().render(markdown).html.withoutSourceLineMetadata

        // The 3-space bullets align to the `1. ` content column and nest under
        // `first`; `second` continues the same ordered list as its second item.
        #expect(html.contains("<ol>\n<li>first\n<ul>\n<li>detail a</li>\n<li>detail b</li>\n</ul></li>\n<li>second</li>\n</ol>"))
    }

    @Test func mixedOrderedListWithBlankLinesAndNestedBulletsStaysOneList() {
        let markdown = """
        1. **first point**
           - supporting detail
           - another detail

        2. **second point**
           - supporting detail
        """

        let html = MarkdownRenderer().render(markdown).html.withoutSourceLineMetadata

        // Mirrors the `## 6. 管理启示` shape: blank-line-separated numbered items
        // with marker-aligned nested bullets render as one continuously numbered
        // <ol>, each item owning its nested <ul>.
        #expect(html.contains("<ol>\n<li><strong>first point</strong>\n<ul>\n<li>supporting detail</li>\n<li>another detail</li>\n</ul></li>\n<li><strong>second point</strong>\n<ul>\n<li>supporting detail</li>\n</ul></li>\n</ol>"))
    }

    @Test func standaloneIndentedDashRendersAsCodeNotList() {
        let markdown = """
        Some paragraph.

            - not a list
        """

        let document = MarkdownRenderer().render(markdown)

        #expect(document.html.contains("<pre"))
        #expect(document.html.contains("- not a list"))
        #expect(!document.html.contains("<li>not a list</li>"))
    }

    @Test func softLineBreaksInParagraphRenderAsBr() {
        let markdown = """
        line one
        line two
        line three
        """

        let html = MarkdownRenderer().render(markdown).html.withoutSourceLineMetadata

        #expect(html.contains("<p>line one<br>line two<br>line three</p>"))
        #expect(!html.contains("line one line two"))
    }

    @Test func multiLineBlockquotePreservesLineBreaks() {
        let markdown = """
        > asdfasdf
        > asdfasdf
        > asdfasdf
        """

        let document = MarkdownRenderer().render(markdown)

        #expect(document.html.contains("asdfasdf<br>asdfasdf<br>asdfasdf"))
        #expect(!document.html.contains("asdfasdf asdfasdf asdfasdf"))
    }

    @Test func blankLineSeparatesParagraphsWithoutBridgingBreak() {
        let markdown = """
        para one

        para two
        """

        let html = MarkdownRenderer().render(markdown).html.withoutSourceLineMetadata

        #expect(html.contains("<p>para one</p>"))
        #expect(html.contains("<p>para two</p>"))
        #expect(!html.contains("para one<br>"))
    }

    @Test func backslashHardBreakRemovesMarkerAndEmitsBr() {
        let markdown = "line one\\\nline two"

        let document = MarkdownRenderer().render(markdown)

        #expect(document.html.contains("line one<br>line two"))
        #expect(!document.html.contains("line one\\"))
    }

    @Test func trailingSpacesHardBreakRemovesMarkerAndEmitsSingleBr() {
        let markdown = "line one  \nline two"

        let document = MarkdownRenderer().render(markdown)

        #expect(document.html.contains("line one<br>line two"))
        #expect(!document.html.contains("line one  <br>"))
        #expect(!document.html.contains("line one<br><br>line two"))
    }

    // The live-preview (Side by Side) path swaps the rendered content into the
    // page's <main> in place. It relies on the rendered `body` being the
    // unwrapped content and on the render routines being exposed as re-runnable
    // window functions rather than one-shot IIFEs.
    @Test func exposesBodyContentWithoutDocumentShell() {
        let document = MarkdownRenderer().render("# Title\n\nA paragraph.")

        #expect(document.body.contains("Title"))
        #expect(document.body.contains("A paragraph."))
        // The body is the inner content only — no document shell.
        #expect(!document.body.contains("<html>"))
        #expect(!document.body.contains("<main>"))
        // The full document wraps that same body inside <main>.
        #expect(document.html.contains("<main>"))
        #expect(document.html.contains(document.body))
    }

    @Test func exposesReRunnableMathRenderHook() {
        let html = MarkdownRenderer().render("Inline $x^2$ math.").html

        #expect(html.contains("window.__md2RenderMath = function"))
        #expect(html.contains("window.__md2RenderMath(document);"))
    }

    @Test func exposesReRunnableDiagramRenderHookWhenDiagramsPresent() {
        let markdown = """
        ```mermaid
        graph TD; A-->B;
        ```
        """

        let html = MarkdownRenderer().render(markdown).html

        #expect(html.contains("window.__md2RenderDiagrams = function"))
        #expect(html.contains("window.__md2RenderDiagrams(document);"))
    }
}
