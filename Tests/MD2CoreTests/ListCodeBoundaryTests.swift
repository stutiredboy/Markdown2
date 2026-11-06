import Testing
@testable import MD2Core
@testable import MD2App

struct ListCodeBoundaryTests {
    @Test(arguments: ["- literal", "* literal", "+ literal", "1. literal", "1) literal", "- [ ] literal", "- [x] literal"])
    func listMarkersInCodeStayLiteral(marker: String) {
        let body = MarkdownRenderer().render("- parent\n\n      " + marker).body
        #expect(body.withoutSourceLineMetadata == "<ul>\n<li>parent\n<pre><code>\(marker)</code></pre></li>\n</ul>")
        #expect(!body.contains("data-md2-task-line"))
        #expect(body.contains(#"<pre data-md2-source-line="3">"#))
    }

    @Test func listLookingLinesDoNotSplitAnExistingCodeBlock() {
        let markdown = "- parent\n\n      before\n      - [ ] literal\n      1. literal\n\n      after\n- sibling"
        let body = MarkdownRenderer().render(markdown).body
        #expect(body.contains(#"<pre data-md2-source-line="3" data-md2-source-end-line="7"><code>before"#))
        #expect(body.contains("before\n- [ ] literal\n1. literal\n\nafter</code></pre>"))
        #expect(body.contains(#"<li data-md2-source-line="8">sibling</li>"#))
        #expect(!body.contains("data-md2-task-line"))
    }

    @Test(arguments: [
        ("\t  code", "code"), (" \t  code", "code"), ("  \t  code", "code"),
        ("\t\tcode", "  code"), ("      \tinside\tend", "\tinside\tend")
    ])
    func tabsUseOriginalColumnsAndKeepCodeText(line: String, expected: String) {
        let body = MarkdownRenderer().render("- parent\n\n" + line).body.withoutSourceLineMetadata
        #expect(body.contains("<pre><code>\(expected)</code></pre>"))
    }

    @Test(arguments: ["\t code", " \t code", "  \t code", "   \t code"])
    func tabStopBelowCodeThresholdRemainsParagraph(line: String) {
        let body = MarkdownRenderer().render("- parent\n\n" + line).body.withoutSourceLineMetadata
        #expect(body.contains("<p>code</p>"))
        #expect(!body.contains("<pre>"))
    }

    @Test(arguments: ["- \tparent", " - \tparent", "1.\tparent", " 1.\tparent"])
    func markerGapTabsStartAtTheMarkerColumn(marker: String) {
        let body = MarkdownRenderer().render(marker + "\n\n\t\tcode").body.withoutSourceLineMetadata
        #expect(body.contains("<pre><code>code</code></pre>"))
    }

    @Test(arguments: ["  - child", "    - child", " \t- child"])
    func validChildrenRemainListsAfterBlankLines(child: String) {
        let body = MarkdownRenderer().render("- parent\n\n" + child).body.withoutSourceLineMetadata
        #expect(body.contains("parent\n<ul>\n<li>child</li>\n</ul>"))
        #expect(!body.contains("<pre>"))
    }

    @Test(arguments: ["      continued", "      continued\n  still paragraph"])
    func noBlankContinuationStaysParagraphButLaterBlankStartsCode(continuation: String) {
        let body = MarkdownRenderer().render("- parent\n" + continuation + "\n\n      - literal").body.withoutSourceLineMetadata
        #expect(body.contains("<p>continued"))
        #expect(!body.contains("<code>continued"))
        #expect(body.contains("<pre><code>- literal</code></pre>"))
    }

    @Test func quotedNestedCodeKeepsAbsoluteSourceLines() {
        let markdown = "# Title\n\n> 1. parent\n>    - child\n>\n> \t\t - [ ] literal\n>    - sibling"
        let body = MarkdownRenderer().render(markdown).body
        #expect(body.contains(#"<pre data-md2-source-line="6"><code>- [ ] literal</code></pre>"#))
        #expect(body.contains(#"<li data-md2-source-line="7">sibling</li>"#))
        #expect(!body.contains("data-md2-task-line"))
    }

    @Test func referenceDefinitionAfterLiteralListMarkerStaysCode() {
        let markdown = "- parent\n\n      - literal\n      [ref]: https://example.com/\n\n[ref]"
        let body = MarkdownRenderer().render(markdown).body.withoutSourceLineMetadata
        #expect(body.contains("<code>- literal\n[ref]: https://example.com/</code>"))
        #expect(body.contains("<p>[ref]</p>"))
        #expect(!body.contains("<a href="))
    }

    @Test func quoteLookingCodeCannotDefineReferences() {
        let body = MarkdownRenderer().render("- parent\n\n      > [ref]: https://example.com/\n\n[ref]").body.withoutSourceLineMetadata
        #expect(body.contains("<code>&gt; [ref]: https://example.com/</code>"))
        #expect(body.contains("<p>[ref]</p>"))
        #expect(!body.contains("<blockquote>"))
        #expect(!body.contains("<a href="))
    }

    @Test(arguments: [2, 3, 4])
    func realQuotesAndFencesKeepTheirContainer(indent: Int) {
        let prefix = String(repeating: " ", count: indent)
        let quote = MarkdownRenderer().render("- parent\n\n" + prefix + "> quoted").body.withoutSourceLineMetadata
        #expect(quote.contains("<blockquote>\n<p>quoted</p>\n</blockquote></li>"))
        let fence = MarkdownRenderer().render("- parent\n\n" + prefix + "```\n" + prefix + "x\ty\n" + prefix + "```").body.withoutSourceLineMetadata
        #expect(fence.contains("<pre><code>x\ty</code></pre></li>"))
    }

    @Test func fenceLookingCodeDoesNotConsumeOutsideParagraph() {
        let body = MarkdownRenderer().render("- parent\n\n      ```\noutside").body.withoutSourceLineMetadata
        #expect(body.contains("<pre><code>```</code></pre></li>\n</ul>\n<p>outside</p>"))
    }

    @Test func closedFenceEstablishesCodeBoundaryWithoutABlank() {
        let body = MarkdownRenderer().render("- parent\n\n  ```\n  abc\n  ```\n      - [ ] literal").body
        #expect(body.contains("<code>abc</code>"))
        #expect(body.contains(#"<pre data-md2-source-line="6"><code>- [ ] literal</code></pre>"#))
        #expect(!body.contains("data-md2-task-line"))
    }

    @Test func unterminatedFenceKeepsTaskLookingLinesAsItsOwnCode() {
        let body = MarkdownRenderer().render("- parent\n\n  ```\n  abc\n      - [ ] literal").body.withoutSourceLineMetadata
        #expect(body.contains("<code>abc\n    - [ ] literal</code>"))
        #expect(!body.contains("data-md2-task-line"))
    }

    @Test func literalFenceDoesNotHideFollowingOutlineAndFootnotes() {
        let rendered = MarkdownRenderer().render("- parent\n\n      ```\n\n# Outside\n\nText[^n]\n\n[^n]: note")
        #expect(rendered.outline.map(\.title) == ["Outside"])
        #expect(rendered.outline.first?.line == 5)
        #expect(rendered.body.contains("id=\"outside\""))
        #expect(rendered.body.contains("href=\"#fn-n\""))
        #expect(rendered.body.contains("class=\"footnotes\""))
    }

    @Test(arguments: [("", ""), ("- parent\n\n", "  "), ("10. parent\n\n", "    ")])
    func realFencesStillProtectOutlineAndFootnoteContents(prefix: String, indent: String) {
        let source = prefix + indent + "```\n" + indent + "# Hidden\n" + indent
            + "[^ghost]: hidden\n" + indent + "```\n\n# Outside\n\nText[^n] [^ghost]\n\n[^n]: note"
        let rendered = MarkdownRenderer().render(source)
        #expect(rendered.outline.map(\.title) == ["Outside"])
        #expect(rendered.body.contains("href=\"#fn-n\""))
        #expect(!rendered.body.contains("href=\"#fn-ghost\""))
    }

    @Test func literalFenceAndFakeFootnoteRemainCodeDuringMetadataScan() {
        let source = "- parent\n\n      ```\n      [^ghost]: hidden\n\n# Outside\n\nText[^n] [^ghost]\n\n[^n]: note"
        let rendered = MarkdownRenderer().render(source)
        #expect(rendered.outline.map(\.title) == ["Outside"])
        #expect(rendered.outline.first?.line == 6)
        #expect(rendered.body.contains("<code>```\n[^ghost]: hidden</code>"))
        #expect(rendered.body.contains("href=\"#fn-n\""))
        #expect(!rendered.body.contains("href=\"#fn-ghost\""))
    }

    @Test func quotedLiteralFenceDoesNotHideLaterQuotedHeading() {
        let rendered = MarkdownRenderer().render("> - parent\n>\n>       ```\n>\n> # Outside")
        #expect(rendered.body.contains("<code>```</code>"))
        #expect(rendered.body.contains("id=\"outside\""))
        #expect(rendered.body.contains("data-md2-source-line=\"5\""))
    }

    @Test @MainActor func onlyRealRenderedTasksCanTriggerSourceEdits() async {
        let original = "- parent\n\n      - [ ] literal\n  - [ ] real"
        let store = DocumentStore()
        store.text = original
        await store.flushPendingRender()
        let body = store.rendered.body
        let codeEmitsTask = body.contains("data-md2-task-line=\"3\"")
        let codeAccepted = codeEmitsTask && store.toggleTask(atLine: 3, to: true,
                                                             renderedAt: store.renderedSourceLineRevision)
        #expect(!codeEmitsTask)
        #expect(!codeAccepted)
        #expect(store.text == original)
        #expect(body.contains("data-md2-task-line=\"4\""))
        let realAccepted = body.contains("data-md2-task-line=\"4\"") && store.toggleTask(
            atLine: 4, to: true, renderedAt: store.renderedSourceLineRevision)
        #expect(realAccepted)
        #expect(store.text == "- parent\n\n      - [ ] literal\n  - [x] real")
        _ = store.closeDocument(discardRecovery: false)
    }
}
