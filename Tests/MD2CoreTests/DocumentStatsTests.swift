import Testing
@testable import MD2Core

struct DocumentStatsTests {
    @Test func countsEachHanCharacterIncludingMixedAndSupplementaryText() {
        #expect(DocumentStats(markdown: String(repeating: "中文正文统计", count: 11) + "六十九").words == 69)
        #expect(DocumentStats(plainText: "中文English测试 world 123，𠀀。👩‍💻").words == 8)
    }

    @Test func countsVisibleLabelsWithoutDestinationsMarkersOrImagePaths() {
        let markdown = """
        ---
        title: Hidden metadata
        ---
        # 中文标题

        **正文** [链接](https://example.com/long/path "invisible title") ![不计入图片](assets/long-image-name.png)

        [参考][ref]

        [ref]: https://example.com/another/path
        """
        let stats = DocumentStats(markdown: markdown)
        #expect(stats.words == 10)
        #expect(stats.lines == 10)
    }

    @Test func htmlAttributesAreNotCountedAndInlineWordsStayJoined() {
        let text = RenderedPlainText.extract(from: #"<p title="not > text">hel<strong>lo</strong> &amp; 世界 &#x20000;</p><p>next</p>"#)
        #expect(text == "hello & 世界 𠀀\nnext")
        #expect(DocumentStats(plainText: text).words == 5)
    }

    @Test func visibleCodeCountsButFencesAndHighlightClassesDoNot() {
        #expect(DocumentStats(markdown: "```swift\nlet value = 42\n```").words == 3)
        #expect(DocumentStats(markdown: "![alt](path/image.png)").words == 0)
        #expect(RenderedPlainText.extract(from: "<!-- invisible comment -->").isEmpty)
    }

    @Test func tableCellsAndListItemsDoNotMergeWords() {
        let markdown = "| First | Second |\n| --- | --- |\n| Alpha | Beta |\n\n- one\n- two"
        #expect(DocumentStats(markdown: markdown).words == 6)
    }

    @Test func htmlEntitiesCountAsDisplayedCharactersWithoutDoubleDecoding() {
        #expect(DocumentStats(markdown: "中文&nbsp;&copy; &eacute; &#x20000;").words == 4)
        #expect(RenderedPlainText.extract(from: "<p>&amp;lt; &NotEqualTilde;</p>") == "&lt; ≂̸")
    }

    @Test func renderedStatsRespectEnabledInlineFeatures() {
        let result = MarkdownRenderer().render("==中文== H~2~O", config: .init(inlineFeatures: .init(highlight: true, subscriptEnabled: true)))
        #expect(result.stats.words == 3)
        #expect(result.stats.characters == 6)
    }

    @Test func countsBasicDocumentStats() {
        let stats = DocumentStats(markdown: "Hello world\nThis is MD2")

        #expect(stats.words == 5)
        #expect(stats.characters == 23)
        #expect(stats.lines == 2)
        #expect(stats.readingMinutes == 1)
    }

    @Test func emptyDocumentHasNoReadingTime() {
        let stats = DocumentStats(markdown: "")

        #expect(stats.words == 0)
        #expect(stats.characters == 0)
        #expect(stats.lines == 0)
        #expect(stats.readingMinutes == 0)
    }
}
