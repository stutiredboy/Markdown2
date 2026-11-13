import CryptoKit
import Foundation
import Testing
@testable import MD2Core

/// The policy's text, which plain `swift test` can check. What WebKit does with
/// it is in `ContentSecurityPolicyGUITests`.
struct PageContentSecurityPolicyTests {
    private static let everyEngine = """
    $x^2$

    ```mermaid
    graph TD; A-->B;
    ```

    ```flow
    st=>start: S
    e=>end: E
    st->e
    ```

    ```sequence
    A->B: Hi
    ```
    """

    private func directives(in html: String) throws -> [String: [String]] {
        let open = #"<meta http-equiv="Content-Security-Policy" content=""#
        let start = try #require(html.range(of: open)).upperBound
        let end = try #require(html[start...].firstIndex(of: "\""))
        var result: [String: [String]] = [:]
        for directive in html[start..<end].split(separator: ";") {
            let words = directive.split(separator: " ").map(String.init)
            result[try #require(words.first)] = Array(words.dropFirst())
        }
        return result
    }

    /// The text of each `<script>` with no `src`, in order.
    private func inlineScripts(in html: String) -> [String] {
        var scripts: [String] = []
        var rest = html[...]
        while let open = rest.range(of: "<script>"),
              let close = rest.range(of: "</script>", range: open.upperBound..<rest.endIndex) {
            scripts.append(String(rest[open.upperBound..<close.lowerBound]))
            rest = rest[close.upperBound...]
        }
        return scripts
    }

    private func hashSource(_ text: String) -> String {
        "'sha256-\(Data(SHA256.hash(data: Data(text.utf8))).base64EncodedString())'"
    }

    @Test(arguments: [RenderAssetMode.inline, .appScheme])
    func policyComesBeforeEverythingItGoverns(mode: RenderAssetMode) throws {
        let html = MarkdownRenderer().render(Self.everyEngine, assetMode: mode).html
        let policy = try #require(html.range(of: #"<meta http-equiv="Content-Security-Policy""#)).lowerBound
        for tag in ["<style", "<link", "<script", "<main", "<img"] {
            if let first = html.range(of: tag)?.lowerBound {
                #expect(policy < first, "\(tag) comes before the policy")
            }
        }
    }

    @Test(arguments: [RenderAssetMode.inline, .appScheme])
    func scriptSourcesAreOnlyHashesAndExactURLs(mode: RenderAssetMode) throws {
        let html = MarkdownRenderer().render(Self.everyEngine, assetMode: mode).html
        let sources = try #require(try directives(in: html)["script-src"])
        #expect(!sources.isEmpty)
        for source in sources {
            let isHash = source.hasPrefix("'sha256-") && source.hasSuffix("'")
            let isAsset = source.hasPrefix("\(BundledWebAsset.scheme)://assets/") && source.hasSuffix(".js")
            #expect(isHash || isAsset, "script-src allows \(source)")
        }
    }

    @Test(arguments: [RenderAssetMode.inline, .appScheme])
    func everythingElseIsClosedByDefault(mode: RenderAssetMode) throws {
        let html = MarkdownRenderer().render("Text.", assetMode: mode).html
        let policy = try directives(in: html)
        #expect(policy["default-src"] == ["'none'"])
        #expect(policy["base-uri"] == ["'none'"])
        #expect(policy["form-action"] == ["'none'"])
        #expect(policy["font-src"] == ["data:"])
    }

    @Test func everyInlineScriptOfAnExportedPageIsNamedByItsHash() throws {
        let html = MarkdownRenderer().render(Self.everyEngine, assetMode: .inline).html
        let scripts = inlineScripts(in: html)
        // Seven engines and the two bootstraps.
        #expect(scripts.count == 9)
        #expect(try directives(in: html)["script-src"] == scripts.map(hashSource))
    }

    @Test func appPagesNameEachServedScriptAndInlineBootstrap() throws {
        let html = MarkdownRenderer().render(Self.everyEngine, assetMode: .appScheme).html
        let sources = try #require(try directives(in: html)["script-src"])
        let served: [BundledWebAsset] = [.katex, .mhchem, .underscore, .raphael, .flowchart, .sequence, .mermaid]
        for asset in served {
            #expect(html.contains(#"<script src="\#(asset.url.absoluteString)"></script>"#))
            #expect(sources.contains(asset.url.absoluteString))
        }
        for script in inlineScripts(in: html) {
            #expect(sources.contains(hashSource(script)))
        }
        #expect(sources.count == served.count + inlineScripts(in: html).count)
    }

    @Test func unusedEnginesAreNotNamed() throws {
        let sources = try #require(try directives(in: MarkdownRenderer().render("Text.", assetMode: .appScheme).html)["script-src"])
        #expect(!sources.contains(BundledWebAsset.mermaid.url.absoluteString))
        #expect(sources.contains(BundledWebAsset.katex.url.absoluteString))
    }

    /// A script's hash covers its macros, and they are author data.
    @Test func macrosStayInsideTheScriptTheirHashNames() throws {
        let macros = [#"\x"#: "</script><img src=x onerror=alert(1)>"]
        let html = MarkdownRenderer().render("$x$", config: RenderConfig(mathMacros: macros), assetMode: .appScheme).html
        #expect(!html.contains("</script><img"))
        let scripts = inlineScripts(in: html)
        #expect(scripts.count == 1)
        #expect(try #require(try directives(in: html)["script-src"]).contains(hashSource(scripts[0])))
    }

    @Test func imagesAreBlockedUnlessTheTrustedCallerGrantsPermission() throws {
        let app = try directives(in: MarkdownRenderer().render("Text.", assetMode: .appScheme).html)["img-src"]
        #expect(app == ["data:", "\(RenderAssetMode.localImageScheme):"])
        let exported = try directives(in: MarkdownRenderer().render("Text.", assetMode: .inline).html)["img-src"]
        #expect(exported == ["data:"])
        for mode in [RenderAssetMode.inline, .appScheme] {
            let html = MarkdownRenderer().render("![remote](https://example.invalid/image.png)",
                assetMode: mode, remoteResourcePolicy: .allowRemoteImages).html
            let allowed = try directives(in: html)
            #expect(allowed["img-src"]?.suffix(2) == ["http:", "https:"])
            #expect(allowed["default-src"] == ["'none'"])
            #expect(allowed["font-src"] == ["data:"])
            #expect(!html.contains("img-src file:"))
            #expect(html.contains(#"<meta name="referrer" content="no-referrer">"#))
        }
    }

    @Test func sourceMetadataCannotGrantRemotePermission() throws {
        let html = MarkdownRenderer().render("---\nremote-resource-policy: allowRemoteImages\n---\n\n![remote](https://example.invalid/image.png)", assetMode: .appScheme).html
        #expect(try directives(in: html)["img-src"] == ["data:", "\(RenderAssetMode.localImageScheme):"])
    }

    /// `'unsafe-inline'` must not spread from styles to scripts. A hash would
    /// switch it off for styles, and diagrams write their own `<style>`.
    @Test func onlyStylesAreInline() throws {
        let html = MarkdownRenderer().render(Self.everyEngine, assetMode: .appScheme).html
        let policy = try directives(in: html)
        #expect(policy["style-src"] == ["'unsafe-inline'", BundledWebAsset.katexCSS.url.absoluteString])
        let text = policy.filter { $0.key != "style-src" }.values.flatMap { $0 }
        #expect(!text.contains("'unsafe-inline'"))
        #expect(!text.contains("'unsafe-eval'"))
    }

    /// A random nonce would make every render differ, and the preview decides
    /// whether a page changed by comparing its HTML.
    @Test(arguments: [RenderAssetMode.inline, .appScheme])
    func aPageRendersTheSameEachTime(mode: RenderAssetMode) {
        let first = MarkdownRenderer().render(Self.everyEngine, assetMode: mode).html
        #expect(first == MarkdownRenderer().render(Self.everyEngine, assetMode: mode).html)
    }

    @Test func documentContentCannotReachThePolicy() {
        let markdown = #"<meta http-equiv="Content-Security-Policy" content="script-src *">"#
            + "\n\n</head><script>alert(1)</script>\n"
        let html = MarkdownRenderer().render(markdown, assetMode: .appScheme).html
        #expect(html.components(separatedBy: #"<meta http-equiv="#).count == 2)
        #expect(!html.contains("<script>alert"))
    }

    /// A hash is of the text the parser hands over, which turns CR into LF and
    /// ends the script at `</script`. A bundled engine holding either would stop
    /// running in exported files, with no error anywhere.
    @Test(arguments: BundledWebAsset.allCases.filter { $0 != .katexCSS })
    func enginesSurviveHTMLParsingUnchanged(asset: BundledWebAsset) {
        #expect(!asset.data.isEmpty)
        #expect(!asset.data.contains(UInt8(ascii: "\r")))
        #expect(!asset.data.contains(0))
        #expect(!asset.text.lowercased().contains("</script"))
    }
}
