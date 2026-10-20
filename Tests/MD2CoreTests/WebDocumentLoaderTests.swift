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

    @Test func thousandsOfRelativeLinksRewriteWithoutQuadraticGrowth() {
        let directory = URL(fileURLWithPath: "/tmp/md2-links")
        func elapsed(_ count: Int) -> Duration {
            let html = String(repeating: #"<p><a href="chapter.md">chapter</a></p>"#, count: count)
            let start = ContinuousClock.now
            let result = LocalLinkHTMLRewriter.rewrite(html, baseURL: directory)
            #expect(result.components(separatedBy: "file:///tmp/md2-links/chapter.md").count == count + 1)
            return start.duration(to: .now)
        }
        _ = elapsed(20)
        let small = elapsed(1_000)
        let large = elapsed(4_000)
        print("Relative links: 1000=\(small), 4000=\(large)")
        #expect(large < .seconds(1))
        #expect(large < small * 10)
    }

    @Test func legacyPreviewCleanupOnlyRemovesOldGeneratedNames() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("md2-preview-clean-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent(".md2-preview-\(UUID().uuidString).html")
        let recent = directory.appendingPathComponent(".md2-preview-\(UUID().uuidString).html")
        let unrelated = directory.appendingPathComponent(".md2-preview-not-generated.html")
        for url in [old, recent, unrelated] { try "content".write(to: url, atomically: true, encoding: .utf8) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: unrelated.path)
        LegacyPreviewCleaner.clean(in: directory)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
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
