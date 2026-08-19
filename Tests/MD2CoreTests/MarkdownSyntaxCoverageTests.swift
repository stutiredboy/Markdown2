import Foundation
import Testing
@testable import MD2Core

struct MarkdownSyntaxCoverageTests {
    @Test func rendersProvidedAcademicReportSample() throws {
        // Optional local fixture; bail out when absent so the suite stays portable.
        let url = URL(fileURLWithPath: "/Users/user/Documents/学术写作/课程作业/论文评审报告样例.md")
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let markdown = try String(contentsOf: url, encoding: .utf8)
        let document = MarkdownRenderer().render(markdown)
        let html = document.html.withoutSourceLineMetadata

        #expect(document.outline.count >= 10)
        #expect(html.contains("<blockquote>"))
        #expect(html.contains("<hr>"))
        #expect(html.components(separatedBy: "<table>").count - 1 >= 3)
        #expect(html.contains("<th style=\"text-align:left\">维度</th>"))
        #expect(html.contains("<strong>专业学位（示例）</strong>"))
        #expect(html.contains("<code>[J]</code>"))
        #expect(html.contains("<br>"))
        #expect(!html.contains("| 维度 |"))
    }

    @Test func rendersBlockSyntaxMatrix() {
        let markdown = """
        ATX Title
        =========

        Setext Subtitle
        ---------------

        > Quote with **strong**
        >
        > - quoted item

        * * *

            indented <code>

        ```swift
        let value = "<safe>"
        ```

        | Left | Center | Right | Pipe |
        | :--- | :---: | ---: | --- |
        | a | b | c | `x | y` |

        1. ordered
        2. list

        - [x] task
        - [ ] next
        """

        let html = MarkdownRenderer().render(markdown).html.withoutSourceLineMetadata

        #expect(html.contains(#"<h1 id="atx-title">ATX Title</h1>"#))
        #expect(html.contains(#"<h2 id="setext-subtitle">Setext Subtitle</h2>"#))
        #expect(html.contains("<blockquote>"))
        #expect(html.contains("<ul>"))
        #expect(html.contains("<hr>"))
        #expect(html.contains("<pre><code>indented &lt;code&gt;\n</code></pre>"))
        #expect(html.contains(#"<code class="language-swift">"#))
        #expect(html.contains(#"<span class="tok-keyword">let</span> value ="#))
        #expect(html.contains(#"<span class="tok-string">&quot;&lt;safe&gt;&quot;</span>"#))
        #expect(html.contains(#"<th style="text-align:center">Center</th>"#))
        #expect(html.contains(#"<td style="text-align:right">c</td>"#))
        #expect(html.contains("<code>x | y</code>"))
        #expect(html.contains("<ol>"))
        #expect(html.contains(#"<ul class="task-list">"#))
    }

    @Test func rendersInlineSyntaxMatrix() {
        let markdown = """
        **strong** __also strong__ *em* _also em_ ***both*** ~~gone~~ `a < b`
        \\*escaped\\* &copy; <https://example.com> <u>html</u>
        [site](https://example.com "Example") ![alt](image.png "Image")
        <script>alert(1)</script>
        """

        let html = MarkdownRenderer().render(markdown).html

        #expect(html.contains("<strong>strong</strong>"))
        #expect(html.contains("<strong>also strong</strong>"))
        #expect(html.contains("<em>em</em>"))
        #expect(html.contains("<em>also em</em>"))
        #expect(html.contains("<strong><em>both</em></strong>"))
        #expect(html.contains("<del>gone</del>"))
        #expect(html.contains("<code>a &lt; b</code>"))
        #expect(html.contains("*escaped*"))
        #expect(html.contains("&copy;"))
        #expect(html.contains(#"<a href="https://example.com">https://example.com</a>"#))
        #expect(html.contains("<u>html</u>"))
        #expect(html.contains(#"<a href="https://example.com" title="Example">site</a>"#))
        #expect(html.contains(#"<img src="image.png" alt="alt" title="Image">"#))
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(!html.contains("<script>alert(1)</script>"))
    }
}
