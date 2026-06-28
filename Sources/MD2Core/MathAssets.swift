import Foundation

/// Loads the bundled, self-contained KaTeX assets used to typeset math in the
/// Read-mode preview.
///
/// The CSS already has its woff2 fonts embedded as `data:` URIs, and the JS is
/// the standard KaTeX distribution. Both are inlined directly into the generated
/// preview HTML so they resolve under the `loadFileURL` preview path without any
/// network access or relative-resource scoping.
enum MathAssets {
    /// The KaTeX stylesheet with fonts embedded as base64 data URIs.
    static let css: String = load("katex.bundle", "css")

    /// The KaTeX JavaScript bundle (provides the global `katex`).
    static let javaScript: String = load("katex.min", "js")

    /// The mhchem extension, enabling chemistry expressions such as `\ce{...}`.
    /// Must be loaded after `javaScript`, which it extends.
    static let mhchem: String = load("mhchem.min", "js")

    private static func load(_ name: String, _ ext: String) -> String {
        guard let url = MD2CoreResources.bundle.url(
            forResource: name,
            withExtension: ext,
            subdirectory: "katex"
        ), let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return contents
    }
}
