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
        // The page's policy names these URLs too, so look for the tags themselves.
        func tag(_ asset: BundledWebAsset) -> String { #"<script src="\#(asset.url.absoluteString)""# }
        let positions = try assets.map { try #require(html.range(of: tag($0))?.lowerBound) }
        #expect(positions == positions.sorted())
        #expect(!html.contains("mermaid.min.js"))
        #expect(html.components(separatedBy: tag(.raphael)).count == 2)
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

    @Test func renderedLocalLinksDecodeHTMLEntitiesBeforeResolvingURLs() {
        let directory = URL(fileURLWithPath: "/tmp/md2-link-entities", isDirectory: true)
        let cases: [(source: String, target: String)] = [
            ("Target.md&#35;target", "Target.md#target"),
            ("Target.md&#x23;target", "Target.md#target"),
            ("Target.md&#X23;target", "Target.md#target"),
            ("my&#32;notes.md#part", "my%20notes.md#part"),
            ("caf&#233;.md&#35;t&#97;rget", "caf%C3%A9.md#target"),
            ("&#x7ae0;&#x8282;.md#&#x8282;", "%E7%AB%A0%E8%8A%82.md#%E8%8A%82"),
            ("caf&eacute;.md&num;target", "caf%C3%A9.md#target"),
            ("docs&sol;Target.md&num;target", "docs/Target.md#target"),
            ("Target.md#&NotEqualTilde;", "Target.md#%E2%89%82%CC%B8"),
            ("Target.md#x&amp;y", "Target.md#x&amp;y"),
            ("quoted&quot;.md#part", "quoted%22.md#part"),
            ("literal&#37;23.md&#35;target", "literal%23.md#target"),
            ("literal%2523.md&#35;target", "literal%2523.md#target"),
            ("literal%26num%3B.md", "literal%26num%3B.md"),
            ("Target.md&amp;#35;target", "Target.md&amp;#35;target"),
            ("literal&amp;num;.md", "literal&amp;num;.md"),
            ("literal&amp;amp;.md", "literal&amp;amp;.md")
        ]
        for testCase in cases {
            // Exercise the renderer's entity protection as well as the loader;
            // raw HTML alone would miss escaping introduced between those layers.
            let body = MarkdownRenderer().render("[Go](\(testCase.source))", assetMode: .appScheme).body
            let rewritten = LocalLinkHTMLRewriter.rewrite(body, baseURL: directory)
            #expect(rewritten == "<p data-md2-source-line=\"1\"><a href=\"file:///tmp/md2-link-entities/\(testCase.target)\">Go</a></p>",
                    "Authored destination: \(testCase.source); rendered: \(body)")
        }
    }

    @Test func renderedEntityFragmentsAndSchemesKeepTheirRoutingBoundaries() {
        let directory = URL(fileURLWithPath: "/tmp/md2-link-entities", isDirectory: true)
        for destination in ["&#35;target", "&num;target", "https&colon;//example.com", "mailto&colon;reader@example.com"] {
            let body = MarkdownRenderer().render("[Go](\(destination))", assetMode: .appScheme).body
            #expect(body.contains("<a href="), "positive control must be a rendered link: \(destination)")
            #expect(LocalLinkHTMLRewriter.rewrite(body, baseURL: directory) == body)
        }
        for destination in ["javascript&colon;alert", "data&colon;text/plain,x", "ftp&colon;//example.com/x", "custom&colon;open"] {
            let body = MarkdownRenderer().render("[Go](\(destination))", assetMode: .appScheme).body
            #expect(!body.contains("<a href="), "a refused scheme must not become a local file: \(destination)")
            #expect(LocalLinkHTMLRewriter.rewrite(body, baseURL: directory) == body)
        }
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

    /// The live preview replaces only the body, so the macros the page renders
    /// with must come with the rendered document (F04 in the 2026-10-15 review).
    @Test func backgroundRenderCarriesFrontMatterMacros() async {
        let text = "---\nmath-macros: {\"\\\\audit\": \"A\"}\n---\n\n$\\audit$"
        let snapshot = DocumentRenderSnapshot(text: text, baseURL: nil, citationStyle: .authorYear, numberAllEquations: false)
        let rendered = await DocumentRenderWorker().render(snapshot)
        #expect(rendered.mathMacros == ["\\audit": "A"])
        #expect(MarkdownRenderer().render("$x$").mathMacros.isEmpty)
    }

    @Test func liveContentOptionsCarryMacrosAndTheLoadedBody() throws {
        func decode(_ options: String) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: Data(options.utf8)) as? [String: Any])
        }
        let first = try decode(MarkdownPreviewView.Coordinator.liveContentOptions(
            mathMacros: ["\\R": "\\mathbb{R}"], loadedBody: "<p data-md2-source-line=\"1\">\u{2028}</p>"))
        #expect(first["macros"] as? [String: String] == ["\\R": "\\mathbb{R}"])
        #expect(first["loaded"] as? String == "<p data-md2-source-line=\"1\">\u{2028}</p>")

        let later = try decode(MarkdownPreviewView.Coordinator.liveContentOptions(mathMacros: [:], loadedBody: nil))
        #expect(later["macros"] as? [String: String] == [:])
        #expect(later["loaded"] == nil)
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
