import Foundation
import Testing
@testable import MD2Core

struct MarkdownImageReferenceTests {
    @Test func destinationsKeepExactUTF16RangesAcrossUnicodeAndLineEndings() {
        let source = "😀 文 e\u{301}\r\n![中文](../a%20b.png \"title\"){width=42 #fig:x}\r![two](/x.png)\n"
        let scan = MarkdownImageReferences.scan(source)
        #expect(scan.references.map(\.destination) == ["../a%20b.png", "/x.png"])
        #expect(scan.references.map { (source as NSString).substring(with: $0.range) } == ["../a%20b.png", "/x.png"])
        #expect(!scan.exceededLimit)
    }

    @Test func literalCodeContainersFrontMatterHTMLAndMathAreExcluded() {
        let source = """
        ---
        image: ![yaml](fake.png)
        ---

        `![code](fake.png)`

            ![indent](fake.png)

        > quoted
        ![lazy](fake.png)

        - ```mermaid

        ![diagram](fake.png)

          ```

        <pre>

        ![html](fake.png)
        </pre>

        $$

        ![math](fake.png)
        $$

        \\![escaped](fake.png)

        ![real](real.png)
        """
        let scan = MarkdownImageReferences.scan(source)
        #expect(scan.references.map(\.destination) == ["real.png"])
        #expect(scan.excludedBlocks >= 7)
        #expect(scan.unsupported.isEmpty)
    }

    @Test func multilineHTMLAndNestedLatexEnvironmentsNeverBecomeImages() {
        let source = """
        Text <!--

        ![comment](fake.png)
        -->

        \\begin{align}
        \\begin{align}
        \\end{align}

        ![math](fake.png)
        \\end{align}

        <img alt="

        ![attribute](fake.png)
        ">

        ![real](real.png)
        """
        let scan = MarkdownImageReferences.scan(source)
        #expect(scan.references.map(\.destination) == ["real.png"])
        #expect(scan.excludedBlocks == 3)
    }

    @Test func referenceStylesRemainExplicitlyUnsupportedAndDefinitionsUntouched() {
        let scan = MarkdownImageReferences.scan("![full][shared]\n![short]\n![collapsed][]\n\n[shared]: image.png \"title\"\n")
        #expect(scan.references.isEmpty)
        #expect(scan.unsupported.count == 3)
        #expect(scan.excludedBlocks == 1)
    }

    @Test func imageShapedLinkTitlesAndNestedLabelsAreNotCollected() {
        let scan = MarkdownImageReferences.scan(#"prefix [link](x "![example](fake.png)")"# + "\n\nprefix [![nested](fake.png)](target)\n\n![real](real.png)")
        #expect(scan.references.map(\.destination) == ["real.png"])
        #expect(scan.unsupported.count == 2)
    }

    @Test func tabIndentedCodeAndRendererFrontMatterStayLiteral() {
        for text in [" \t![code](fake.png)", "-\t![container](fake.png)",
                     "---\nkey: value\n...\n\n![yaml](fake.png)\n---\n"] {
            #expect(MarkdownImageReferences.scan(text).references.isEmpty)
        }
    }

    @Test func malformedAndComplexCandidatesNeverInventDestinations() {
        for source in ["![a](a(b).png)", "![a](<a b.png>)", "![a](a.png 'title')", "![a](a\\ b.png)"] {
            let scan = MarkdownImageReferences.scan(source)
            #expect(scan.references.isEmpty)
            #expect(!scan.unsupported.isEmpty || scan.excludedBlocks > 0)
        }
    }

    @Test func limitsFailClosedBeforeFilesystemPlanning() {
        let huge = String(repeating: "x", count: MarkdownImageReferences.maximumSourceUnits + 1)
        #expect(MarkdownImageReferences.scan(huge).exceededLimit)
        let many = String(repeating: "![a](a.png) ", count: MarkdownImageReferences.maximumCandidates + 1)
        #expect(MarkdownImageReferences.scan(many).exceededLimit)
        let unfinished = String(repeating: "![", count: 100_000)
        #expect(MarkdownImageReferences.scan(unfinished).exceededLimit)
    }
}
