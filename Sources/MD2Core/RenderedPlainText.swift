import Foundation

/// Extracts text from the renderer's sanitized body, never from the document
/// shell or Markdown source. Attributes (URLs, image paths, titles) are not text.
/// This stays off WebKit/AppKit so background rendering and selection counting
/// share exactly the same rules.
public enum RenderedPlainText {
    private static let tokens = try! NSRegularExpression(
        pattern: #"<!--[\s\S]*?-->|<[^>"']*(?:"[^"]*"[^>"']*|'[^']*'[^>"']*)*>"#)
    private static let classAttribute = try! NSRegularExpression(pattern: #"\bclass\s*=\s*["']([^"']*)["']"#)
    private static let blocks: Set<String> = ["p", "div", "section", "h1", "h2", "h3", "h4", "h5", "h6", "li", "ul", "ol", "blockquote", "pre", "table", "tr", "br", "hr", "figure", "figcaption"]
    private static let voidTags: Set<String> = ["img", "input", "br", "hr", "meta", "link", "wbr", "source"]
    private static let excludedClasses: Set<String> = ["front-matter", "footnote-ref", "footnote-backref", "diagram", "math", "toc", "md2-broken-image", "md2-line-gutter"]
    // HTML5 named references, generated from Python's standard html.entities.
    // Decode in one pass: &amp;lt; is visible as &lt;, not as <.
    private static let entities: [String: String] = {
        guard let url = MD2CoreResources.bundle.url(forResource: "html-entities", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }()
    private static let entityPattern = try! NSRegularExpression(pattern: #"&(#(?:[xX][0-9a-fA-F]+|[0-9]+)|[A-Za-z][A-Za-z0-9]+);"#)

    private static func decodeEntities(_ text: String) -> String {
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in entityPattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let key = source.substring(with: match.range(at: 1))
            let literal = source.substring(with: match.range)
            result += key.hasPrefix("#") ? HTMLSafety.decodeEntities(literal) : (entities[key] ?? literal)
            cursor = NSMaxRange(match.range)
        }
        return result + source.substring(from: cursor)
    }

    public static func extract(from body: String) -> String {
        let source = body as NSString
        var output = ""
        var cursor = 0
        var excluded: [String] = []
        for token in tokens.matches(in: body, range: NSRange(location: 0, length: source.length)) {
            if excluded.isEmpty {
                output += source.substring(with: NSRange(location: cursor, length: token.range.location - cursor))
            }
            let tag = source.substring(with: token.range)
            cursor = NSMaxRange(token.range)
            if tag.hasPrefix("<!--") { continue }
            let closing = tag.hasPrefix("</")
            let name = String(tag.dropFirst(closing ? 2 : 1).prefix { $0.isLetter || $0.isNumber }).lowercased()
            if closing {
                if let index = excluded.lastIndex(of: name) { excluded.removeSubrange(index...) }
            } else if !voidTags.contains(name), !tag.hasSuffix("/>") {
                let ns = tag as NSString
                let classes = classAttribute.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length))
                    .map { Set(ns.substring(with: $0.range(at: 1)).split(separator: " ").map(String.init)) } ?? []
                if !excluded.isEmpty || ["script", "style", "template"].contains(name) || !classes.isDisjoint(with: excludedClasses) {
                    excluded.append(name)
                }
            }
            if excluded.isEmpty {
                if blocks.contains(name), !output.hasSuffix("\n"), !output.isEmpty { output += "\n" }
                else if ["td", "th"].contains(name), closing { output += "\t" }
            }
        }
        if excluded.isEmpty { output += source.substring(from: cursor) }
        return decodeEntities(output).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
