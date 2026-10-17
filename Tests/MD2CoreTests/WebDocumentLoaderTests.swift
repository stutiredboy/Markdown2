import Foundation
import MD2Core
import Testing
@testable import MD2App

struct WebDocumentLoaderTests {
    @Test func appHTMLDoesNotEmbedEnginesOrFonts() {
        let markdown = "# Test\n\n$x^2$\n\n```mermaid\ngraph TD; A-->B\n```"
        let inline = MarkdownRenderer().render(markdown)
        let app = MarkdownRenderer().render(markdown, assetMode: .appScheme)
        #expect(app.body == inline.body)
        #expect(app.html.utf8.count < 40_000)
        #expect(inline.html.utf8.count > 3_000_000)
        #expect(!app.html.contains("base64,"))
        #expect(app.html.contains("src=\"\(BundledWebAsset.katex.url)\""))
        #expect(app.html.contains("href=\"\(BundledWebAsset.katexCSS.url)\""))
        #expect(app.html.contains("src=\"\(BundledWebAsset.mermaid.url)\""))
        print("HTML bytes: inline=\(inline.html.utf8.count), app=\(app.html.utf8.count)")
    }

    @Test func bundledAssetsRejectUnknownOrAlteredURLs() {
        for asset in BundledWebAsset.allCases {
            #expect(!asset.data.isEmpty)
            #expect(BundledWebAsset(url: asset.url) == asset)
            #expect(BundledWebAsset(url: URL(string: asset.url.absoluteString + "?file=/etc/passwd")!) == nil)
            #expect(BundledWebAsset(url: URL(string: asset.url.absoluteString.replacingOccurrences(of: "://assets/", with: "://other/"))!) == nil)
        }
        #expect(BundledWebAsset(url: URL(string: "md2-app://assets/../katex/katex.min.js")!) == nil)
        #expect(BundledWebAsset(url: URL(string: "md2-app://assets/etc/passwd")!) == nil)
    }

    @Test func enginesAreIncludedInDependencyOrderAndOnlyWhenNeeded() throws {
        let html = MarkdownRenderer().render("```flow\na=>start: A\n```\n\n```sequence\nA->B: Hi\n```", assetMode: .appScheme).html
        let assets: [BundledWebAsset] = [.katex, .mhchem, .underscore, .raphael, .flowchart, .sequence]
        let positions = try assets.map { try #require(html.range(of: $0.url.absoluteString)?.lowerBound) }
        #expect(positions == positions.sorted())
        #expect(!html.contains("mermaid.min.js"))
        #expect(html.components(separatedBy: BundledWebAsset.raphael.url.absoluteString).count == 2)
        #expect(!MarkdownRenderer().render("plain", assetMode: .appScheme).html.contains("/diagrams/"))
    }

    @Test func relativeLinksKeepFilesystemTargetsAndFragmentsStayInPage() {
        let html = ##"<a href="../other%20notes.md#part">doc</a><a href="spec.pdf?q=1&amp;x=2">pdf</a><a href="#fn-1">note</a><a href="https://example.com">web</a>"##
        let result = LocalLinkHTMLRewriter.rewrite(html, baseURL: URL(fileURLWithPath: "/tmp/my docs"))
        #expect(result.contains(#"href="file:///tmp/other%20notes.md#part""#))
        #expect(result.contains(#"href="file:///tmp/my%20docs/spec.pdf?q=1&amp;x=2""#))
        #expect(result.contains(##"href="#fn-1""##))
        #expect(result.contains(#"href="https://example.com""#))
        #expect(LocalLinkHTMLRewriter.rewrite(#"<a href="other.md">doc</a>"#, baseURL: nil) == #"<a href="other.md">doc</a>"#)
    }

    @Test func memoryPageRoutingAllowsOnlyCurrentPageAndFragments() {
        let page = URL(string: "md2-doc://document/id/index.html")!
        #expect(PreviewLinkRouter.route(for: page, documentPageURL: page) == .allowInPage)
        #expect(PreviewLinkRouter.route(for: URL(string: page.absoluteString + "#heading"), documentPageURL: page) == .allowInPage)
        for value in ["md2-doc://document/other/index.html", "md2-doc://document/id/other.md", "md2-app://assets/unknown", page.absoluteString + "?old=1"] {
            #expect(PreviewLinkRouter.route(for: URL(string: value), documentPageURL: page) == .ignore)
        }
    }

    @Test func backgroundRenderUsesSharedAssetsByDefault() async {
        let snapshot = DocumentRenderSnapshot(text: "# Test", baseURL: nil, citationStyle: .authorYear, numberAllEquations: false)
        let worker = DocumentRenderWorker()
        let app = await worker.render(snapshot)
        let standalone = await worker.render(snapshot, assetMode: .inline)
        #expect(app.html.contains("md2-app://"))
        #expect(!standalone.html.contains("md2-app://"))
    }
}
