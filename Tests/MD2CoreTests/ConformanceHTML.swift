import Foundation

/// HTML normalisation for reference comparison in the conformance suite.
///
/// Markdown2's output intentionally diverges from CommonMark/GFM reference HTML
/// in ways that do not change the rendered document: it injects `data-md2-*`
/// source/task metadata and auto-generated heading `id`s, and joins blocks with
/// newlines. Normalisation removes exactly those invisible differences and
/// collapses insignificant whitespace *between* tags, while preserving the
/// contents of `<pre>` verbatim (where whitespace is significant). It is
/// deliberately minimal and documented so the conformance baseline is stable.
enum ConformanceHTML {
    static func normalize(_ html: String) -> String {
        var s = html
        s = stripInjectedAttributes(s)
        s = collapseInterTagWhitespace(s, protecting: "pre")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops the XHTML self-closing slash on void elements so the reference's
    /// `<hr />`, `<br />`, `<img … />` compare equal to Markdown2's HTML5
    /// `<hr>`, `<br>`, `<img …>`. Purely syntactic; does not change rendering.
    static func normalizeVoidElements(_ html: String) -> String {
        html.replacingOccurrences(
            of: #"\s*/>"#,
            with: ">",
            options: .regularExpression
        )
    }

    /// Removes attributes Markdown2 injects that are intentionally absent from
    /// the upstream reference: `data-md2-*` metadata and auto-generated `id`s.
    static func stripInjectedAttributes(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(
            of: #"\s+data-md2-[a-z-]+="[^"]*""#,
            with: "",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"\s+id="[^"]*""#,
            with: "",
            options: .regularExpression
        )
        return s
    }

    /// Collapses whitespace that sits between two tags (`>` … `<`) to nothing,
    /// leaving the contents of `protecting` elements (e.g. `<pre>`) untouched.
    static func collapseInterTagWhitespace(_ html: String, protecting tag: String) -> String {
        let (stripped, protected) = protect(html, tag: tag)
        var s = stripped.replacingOccurrences(
            of: #">\s+<"#,
            with: "><",
            options: .regularExpression
        )
        s = normalizeVoidElements(s)
        for (token, original) in protected {
            s = s.replacingOccurrences(of: token, with: original)
        }
        return s
    }

    /// Replaces each `<tag …>…</tag>` region with an opaque token so its inner
    /// whitespace survives normalisation; returns the placeholders to restore.
    private static func protect(_ html: String, tag: String) -> (String, [(String, String)]) {
        let pattern = "<\(tag)(?:\\s[^>]*)?>[\\s\\S]*?</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (html, []) }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (html, []) }

        var result = html
        var protected: [(String, String)] = []
        for (offset, match) in matches.enumerated().reversed() {
            let original = ns.substring(with: match.range)
            let token = "\u{0001}PRE\(offset)\u{0001}"
            protected.append((token, original))
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: token)
            }
        }
        return (result, protected)
    }
}
