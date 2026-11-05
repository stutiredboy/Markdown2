import CryptoKit
import Foundation

/// An inline `<script>` and the policy source that lets exactly that text run.
/// Both come from here because a hash covers every byte between the tags: a
/// page whose wrapping drifts from its hash loses the script without an error.
enum InlineScript {
    static func element(_ code: String) -> String {
        "<script>\(content(code))</script>"
    }

    static func hashSource(_ code: String) -> String {
        let digest = SHA256.hash(data: Data(content(code).utf8))
        return "'sha256-\(Data(digest).base64EncodedString())'"
    }

    private static func content(_ code: String) -> String {
        "\n\(code)\n"
    }
}

/// The Content-Security-Policy of every page `MarkdownRenderer` produces: the
/// layer under `HTMLSafety` and each diagram engine's own sanitizing. It lets
/// run only the scripts the page was built with, so an event handler, a
/// `javascript:` URL or an injected `<script>` runs nothing, on any engine, even
/// when the markup reaches the page.
///
/// It is a `<meta>` rather than a response header because an exported file has
/// no response. The tag must stay ahead of everything it governs: a policy
/// applies only to what the parser reaches after it.
enum PageContentSecurityPolicy {
    static func metaTag(scriptSources: [String], assetMode: RenderAssetMode) -> String {
        let directives = [
            "default-src 'none'",
            // Hashes and exact URLs only. `'unsafe-inline'` would let handlers
            // and `javascript:` URLs run, and no engine needs `'unsafe-eval'`.
            "script-src \(scriptSources.joined(separator: " "))",
            // Inline style stays open: Mermaid writes a `<style>` into each
            // diagram, KaTeX and the engines set `style` attributes, and the app
            // adds its typography and print overrides as `<style>` elements.
            "style-src 'unsafe-inline'" + (assetMode.stylesheetSource.map { " \($0)" } ?? ""),
            // Open on purpose: Markdown images load from the network.
            "img-src http: https: data: \(assetMode.localImageSource)",
            // KaTeX's fonts are embedded in its stylesheet.
            "font-src data:",
            // Neither falls back to `default-src`.
            "base-uri 'none'",
            "form-action 'none'"
        ]
        return #"<meta http-equiv="Content-Security-Policy" content="\#(directives.joined(separator: "; "))">"#
    }
}
