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

    @Test func imageSourceUnderscoresAreNotParsedAsEmphasis() {
        let document = MarkdownRenderer().render("![图 2-1 霍尔三维结构示意图](figures/fig2_1_hall.png)")

        #expect(document.html.contains(#"<img src="figures/fig2_1_hall.png" alt="图 2-1 霍尔三维结构示意图">"#))
        #expect(!document.html.contains("fig2<em>1</em>hall"))
    }

    @Test func linkHrefUnderscoresAreNotParsedAsEmphasis() {
        let document = MarkdownRenderer().render("[Open spec](docs/open_spec_v1.html)")

        #expect(document.html.contains(#"<a href="docs/open_spec_v1.html">Open spec</a>"#))
        #expect(!document.html.contains("open<em>spec</em>v1"))
    }

    @Test func linkLabelsStillRenderEmphasisWhenHrefIsProtected() {
        let document = MarkdownRenderer().render("[**Open** spec](docs/open_spec_v1.html)")

        #expect(document.html.contains(#"<a href="docs/open_spec_v1.html"><strong>Open</strong> spec</a>"#))
    }

    @Test func infersImageDimensionsFromSizedURLPath() {
        let document = MarkdownRenderer().render(#"![Sample](https://via.placeholder.com/200x100 "Placeholder image")"#)

        #expect(document.html.contains(#"<span class="image-frame" style="width: 200px; aspect-ratio: 200 / 100;"><img src="https://via.placeholder.com/200x100" alt="Sample" title="Placeholder image" width="200" height="100"></span>"#))
    }

    @Test func rendersWidthAndHeightAttributesInFrame() {
        let document = MarkdownRenderer().render("![photo](assets/photo.jpg){width=320 height=180}")

        #expect(document.html.contains(#"<span class="image-frame" style="width: 320px; aspect-ratio: 320 / 180;"><img src="assets/photo.jpg" alt="photo" width="320" height="180"></span>"#))
        #expect(!document.html.contains("{width=320 height=180}"))
    }

    @Test func rendersWidthOnlyWithoutFixedFrame() {
        let document = MarkdownRenderer().render("![diagram](assets/diagram.png){width=480}")

        #expect(document.html.contains(#"<img src="assets/diagram.png" alt="diagram" width="480">"#))
        // Width-only must not wrap in a fixed-aspect frame (no known ratio).
        #expect(!document.html.contains(#"<span class="image-frame" style="width: 480px"#))
        #expect(!document.html.contains("{width=480}"))
    }

    @Test func explicitWidthOverridesURLInferredDimensions() {
        let document = MarkdownRenderer().render("![photo](assets/photo-1200x800.png){width=480}")

        #expect(document.html.contains(#"<img src="assets/photo-1200x800.png" alt="photo" width="480">"#))
        #expect(!document.html.contains(#"width="1200""#))
        #expect(!document.html.contains("aspect-ratio: 1200"))
    }

    @Test func ignoresInvalidSizeAttribute() {
        let document = MarkdownRenderer().render("![photo](assets/photo.jpg){width=large}")

        #expect(document.html.contains(#"<img src="assets/photo.jpg" alt="photo">"#))
        #expect(!document.html.contains("width=large"))
        #expect(!document.html.contains("{width=large}"))
    }

    @Test func preservesNonSizeBraceBlockAsLiteralText() {
        let document = MarkdownRenderer().render("![x](a.png){.foo}")

        #expect(document.html.contains(#"<img src="a.png" alt="x">{.foo}"#))
    }

    @Test func preservesTitledImageWithoutSizeAttributes() {
        let document = MarkdownRenderer().render(#"![alt](images/existing.png "Title")"#)

        #expect(document.html.contains(#"<img src="images/existing.png" alt="alt" title="Title">"#))
    }

    @Test func brokenImageDiagnosticIsNotInSharedRenderedShell() {
        // The broken-image placeholder is injected into the preview web view only,
        // never the shared `RenderedDocument.html` that PDF export and printing
        // reuse, so a deliverable never shows a broken-image box.
        let document = MarkdownRenderer().render("![missing](assets/missing.png)")

        #expect(!document.html.contains("md2-broken-image"))
        #expect(!document.html.contains("addEventListener('error'"))
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

    @Test func twoSpaceIndentedUnorderedListItemNestsUnderParent() {
        let markdown = """
        - parent
          - child
        """

        let document = MarkdownRenderer().render(markdown)

        #expect(document.html.contains("<li>parent\n<ul>\n<li>child</li>\n</ul></li>"))
    }

    @Test func monthlyReportTwoSpaceNestedBulletsStayUnderBoldParents() {
        let markdown = """
        - **重点故障与隐患**：
          - 5月18日及6月18日，东冠 M02（9.5 年）与滨安 M01（7.8 年）两台 H3C 核心交换机相继出现管理平面“假死”与配置保存失败故障。
        - **告警与工单**：
          - 5月人工处理 L1/L2 告警共 **5,586 次**
        """

        let html = MarkdownRenderer().render(markdown).html.withoutSourceLineMetadata

        #expect(html.contains("<ul>\n<li><strong>重点故障与隐患</strong>：\n<ul>"))
        #expect(html.contains("<li>5月18日及6月18日，东冠 M02"))
        #expect(html.contains("</ul></li>\n<li><strong>告警与工单</strong>：\n<ul>"))
        #expect(html.contains("<li>5月人工处理 L1/L2 告警共 <strong>5,586 次</strong></li>"))
    }

    @Test func unindentedImagesBetweenNestedSiblingItemsDoNotBreakChildList() {
        let markdown = """
        - parent
          - first child
        ![](first.png)
        ![](second.png)
          - second child
        """

        let html = MarkdownRenderer().render(markdown).html.withoutSourceLineMetadata

        #expect(html.contains("<li>parent\n<ul>\n<li>first child\n<p><img src=\"first.png\" alt=\"\"><br><img src=\"second.png\" alt=\"\"></p></li>\n<li>second child</li>\n</ul></li>"))
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

    @Test func markerAlignedBulletsNestUnderTwoDigitOrderedItem() {
        let markdown = """
        10. first
            - detail a
        11. second
        """

        let html = MarkdownRenderer().render(markdown).html.withoutSourceLineMetadata

        #expect(html.contains("<ol>\n<li>first\n<ul>\n<li>detail a</li>\n</ul></li>\n<li>second</li>\n</ol>"))
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

    @Test func tableIndentedUnderOrderedItemRendersInsideItem() {
        // The marker is indented three columns and its body six, so the table
        // sits at the item's content column. It must render as the item's table
        // body — not leak to the top level where 4+ space indentation would make
        // it an indented code block (the orchestrator-notes bug).
        let markdown = [
            "   2. 基本信息采集",
            "",
            "      采集的信息为：",
            "",
            "      |SQL 字段|写入字段|",
            "      | ---------- | ---------- |",
            "      |`@@global.hostname`|`mysqlHostname`|",
            "",
            "   3. binlog 坐标采集",
        ].joined(separator: "\n")

        let html = MarkdownRenderer().render(markdown).html.withoutSourceLineMetadata

        #expect(html.contains("<table>"))
        #expect(html.contains("<td style=\"text-align:left\"><code>@@global.hostname</code></td>"))
        // The table header must not be swallowed into a <pre> code block.
        #expect(!html.contains("<pre><code>"))
        #expect(!html.contains("|SQL 字段|"))
        // Both numbered items stay in one continuous ordered list.
        #expect(html.contains("<li>基本信息采集"))
        #expect(html.contains("<li>binlog 坐标采集</li>"))
        #expect(html.contains("<ol>") && !html.contains("</ol>\n<ol>"))
    }

    @Test func paragraphAndCodeBlockNestUnderListItem() {
        let markdown = """
        - step one

          A follow-up paragraph.

          ```swift
          let x = 1
          ```
        - step two
        """

        let html = MarkdownRenderer().render(markdown).html.withoutSourceLineMetadata

        // The item's block body renders inside the <li>: a paragraph and a
        // fenced code block, both nested rather than leaked to the top level.
        #expect(html.contains("<li>step one\n<p>A follow-up paragraph.</p>"))
        #expect(html.contains("<code class=\"language-swift\">") || html.contains("<pre"))
        #expect(html.contains("<li>step two</li>"))
    }

    @Test func twoSpaceIndentedNestedTaskAndOrderedListsKeepStructure() {
        let markdown = """
        - parent
          - [x] done
          1. step one
          2. step two
        """

        let html = MarkdownRenderer().render(markdown).html.withoutSourceLineMetadata

        #expect(html.contains("<ul>\n<li>parent\n<ul class=\"task-list\">\n<li><input type=\"checkbox\" checked> done</li>\n</ul>\n<ol>\n<li>step one</li>\n<li>step two</li>\n</ol></li>\n</ul>"))
    }

    @Test func shortIndentedLineStaysSiblingParagraph() {
        // CommonMark example 255: ` two` is indented one space — short of the
        // `- ` content column (two) — so it is a separate paragraph, not body.
        let markdown = "- one\n\n two"

        let html = MarkdownRenderer().render(markdown).html.withoutSourceLineMetadata

        #expect(html.contains("<ul>\n<li>one</li>\n</ul>"))
        #expect(html.contains("<p>two</p>"))
        #expect(!html.contains("<li>one\n<p>two</p>"))
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
