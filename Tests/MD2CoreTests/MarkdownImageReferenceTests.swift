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
        for source in ["![a](a(b).png)", "![a](a.png 'title')", "![a](a\\ b.png)"] {
            let scan = MarkdownImageReferences.scan(source)
            #expect(scan.references.isEmpty)
            #expect(!scan.unsupported.isEmpty || scan.excludedBlocks > 0)
        }
    }

    @Test func anglePathsPreserveDelimitersWhitespaceAndExactUnicodeRange() {
        let text = "😀 ![图](<../shared/图片 sample.png>  \"标题\"){width=31}\r\n[普通链接][shared]\r\n"
        let scan = MarkdownImageReferences.scan(text)
        #expect(scan.references.count == 1)
        #expect(scan.references.first?.destination == "../shared/图片 sample.png")
        if let reference = scan.references.first {
            #expect((text as NSString).substring(with: reference.range) == "../shared/图片 sample.png")
            #expect((text as NSString).substring(with: NSRange(location: reference.range.location - 1, length: 1)) == "<")
            #expect((text as NSString).substring(with: NSRange(location: NSMaxRange(reference.range), length: 1)) == ">")
        }
        #expect(scan.excludedBlocks == 0)
        #expect(MarkdownImageReferences.scan("![p](<preview image.png>)").references.count == 1)
    }

    @Test func completeImageAttributesAreOneInertSyntacticPayload() {
        for attributes in [#"{width=31 note="![literal](hidden.png)"}"#,
                           #"{#fig:one note="![literal](hidden.png)"}"#,
                           #"{unknown="![literal](hidden.png)"}"#,
                           #"{width=31 note="<pre>![literal](hidden.png)"}"#] {
            let text = "![real](real.png)" + attributes + " ![second](second.png)"
            let scan = MarkdownImageReferences.scan(text)
            #expect(scan.references.map(\.destination) == ["real.png", "second.png"])
            #expect(scan.unsupported.isEmpty)
            #expect(MarkdownRenderer().render(text).body.components(separatedBy: "<img ").count - 1 == 2)
        }
    }

    @Test func listContextSurvivesBlankLinesNestedListsAndOrderedMarkers() {
        for prefix in ["- list item\n\n  ", "1. list item\n\n   ",
                       "- outer\n  - inner\n\n    ", "> quote\n>\n> - item\n>\n>   "] {
            let text = prefix + "![nested](nested.png)\n\n- sibling\n\n![top](top.png)"
            let scan = MarkdownImageReferences.scan(text)
            #expect(scan.references.map(\.destination) == ["top.png"])
            #expect(scan.excludedBlocks > 0)
        }
    }

    @Test func attributeClosingBraceUsesRawEscapeParityAndMatchesRenderer() {
        for count in 0...6 {
            let slashes = String(repeating: "\\", count: count)
            let text = "![real](real.png){width=31 note=\"" + slashes + "} ![literal](literal.png)\"} ![last](last.png)"
            let expected = count.isMultiple(of: 2) ? ["real.png", "literal.png", "last.png"] : ["real.png", "last.png"]
            #expect(MarkdownImageReferences.scan(text).references.map(\.destination) == expected)
            #expect(MarkdownRenderer().render(text).body.components(separatedBy: "<img ").count - 1 == expected.count)
        }
        let raw = Array(#"{note="\} still here"}"#.utf16)
        let last = MarkdownLinkSyntax.lastAttributeClosingBrace(in: raw, input: .rawSource)
        #expect(MarkdownLinkSyntax.endOfImageAttributes(in: raw, after: 0, lastClosingBrace: last, input: .rawSource) == raw.count)
        // Protected input is already tokenized by the renderer: any remaining
        // brace is structural, even if preceded by a literal backslash unit.
        #expect(MarkdownLinkSyntax.endOfImageAttributes(in: raw, after: 0, lastClosingBrace: last, input: .protectedEscapes) < raw.count)
    }

    @Test func multilineAndUnfinishedAttributesAreReportedWithoutEditingTheirContents() {
        for payload in [#"{width=31 note="\}"# + "\n![literal](literal.png)\"}",
                        #"{width=31 note="\} ![literal](literal.png)"#,
                        #"{width=31 note="<span title='}'> ![literal](literal.png)"}"#,
                        #"{width=31 note="<https://example.com/}> ![literal](literal.png)"}"#,
                        #"{width=31 note="\ref{fig:unknown} ![literal](literal.png)"}"#,
                        #"{width=31 note="[^label}] ![literal](literal.png)"}"#,
                        #"{width=31 note="[@book, }] ![literal](literal.png)"}"#] {
            let text = "![real](real.png)" + payload + "\n\n![top](top.png)"
            let scan = MarkdownImageReferences.scan(text)
            #expect(scan.references.map(\.destination) == ["top.png"])
            #expect(scan.excludedBlocks == 1)
        }
        let many = String(repeating: #"![a](a.png){\} "#, count: 9_000)
        #expect(MarkdownLinkSyntax.candidateRanges(in: many, includeImageMarker: true).count == 9_000)
        #expect(MarkdownImageReferences.scan(many).excludedBlocks == 1)
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
