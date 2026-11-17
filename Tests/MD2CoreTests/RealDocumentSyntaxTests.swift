import Foundation
import Testing
@testable import MD2App
@testable import MD2Core

struct RealDocumentSyntaxTests {
    @Test func balancedLinkDestinationUsesItsWholePathAndStyleRange() {
        let link = #"[portable install](https://example.test/windows_(portable).md "Install guide")"#
        let source = "📦 See \(link), then [next](/next)."
        let body = MarkdownRenderer().render(source, assetMode: .appScheme).body
        #expect(body.contains(#"<a href="https://example.test/windows_(portable).md" title="Install guide">portable install</a>, then <a href="/next">next</a>."#))
        let spans = MarkdownStylePlan(source).spans.filter { $0.kind == .link }
        #expect(spans.map { (source as NSString).substring(with: $0.range) } == [link, "[next](/next)"])
    }

    @Test func linksStillRejectUnsafeSchemesAndDoNotTruncateUnbalancedDestinations() {
        let source = #"[unsafe](javascript&#58;alert(1)) [unfinished](notes_(old) then [next](/next)."#
        let body = MarkdownRenderer().render(source, assetMode: .appScheme).body
        #expect(!body.contains(#"href="javascript"#))
        #expect(!body.contains(#"href="notes_"#))
        #expect(body.contains(#"[unfinished](notes_(old) then <a href="/next">next</a>"#))
    }

    @Test func rawLinkStylingKeepsEscapedQuotesInTheTitle() {
        let source = #"[x](/notes_(old).md "a \") and rest")"#
        let span = MarkdownStylePlan(source).spans.first { $0.kind == .link }
        #expect(span?.range == NSRange(location: 0, length: source.utf16.count))
        let body = MarkdownRenderer().render(source, assetMode: .appScheme).body
        #expect(body.contains(#"href="/notes_(old).md" title="a &quot;) and rest""#))
    }

    @Test(arguments: [
        #"[link](/safe "unfinished ![sample](must-not-copy.png)"#,
        #"[link](/sample_(archive).md "snippet ) ![sample](must-not-copy.png)")"#
    ])
    func portableImageScannerStillRefusesImageSyntaxInLinkTitles(_ link: String) {
        let scan = MarkdownImageReferences.scan(link + "\n\n![real](real.png)")
        #expect(scan.references.map(\.destination) == ["real.png"])
        #expect(scan.unsupported.count == 1)
    }

    @Test func portableImageScanRecognizesOpeningBracketBeforeJoiningScalar() {
        let source = "![\u{0301}a](sample.png)"
        let scan = MarkdownImageReferences.scan(source)
        #expect(scan.references.map(\.destination) == ["sample.png"])
    }

    @Test func fenceInfoSuffixDoesNotAffectSyntaxHighlightingOrActivateDiagram() {
        let source = "~~~swift\tfilename=Probe.swift\nlet value = 42\n# Not a heading\n~~~\n~~~mermaid note\ngraph TD; A-->B\n~~~\n## Summary"
        let rendered = MarkdownRenderer().render(source, assetMode: .appScheme)
        #expect(rendered.body.contains(#"<code class="language-swift"><span class="tok-keyword">let</span>"#))
        #expect(rendered.body.contains(#"<code class="language-mermaid">graph TD; A--&gt;B</code>"#))
        #expect(rendered.outline.map(\.title) == ["Summary"])
    }

    @Test func aHeadingWithPipesEndsTheTableInPreviewAndInSourceEditing() throws {
        let source = "## Signals | overview\n| Check | Signal |\n| --- | --- |\n| CPU | Normal |\n## Results | next steps\nMore text."
        let rendered = MarkdownRenderer().render(source, assetMode: .appScheme)
        #expect(rendered.body.contains("</table>\n<h2"))
        #expect(rendered.body.contains("<table data-md2-source-line=\"2\" data-md2-source-end-line=\"4\">"))
        #expect(rendered.outline.map(\.title) == ["Signals | overview", "Results | next steps"])

        let selection = (source as NSString).range(of: "Normal")
        let edit = try MarkdownTableEditing.result(source, selection: selection, action: .insertRowBelow).get()
        let edited = (source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        #expect(edited.contains("| CPU | Normal |\n|  |  |\n## Results | next steps"))
        let heading = (source as NSString).range(of: "Results")
        #expect(MarkdownTableEditing.edit(source, selection: heading, action: .deleteRow) == nil)
    }
}
