import Foundation

/// Author HTML is data. Only formatting tags and explicitly inert attributes
/// survive; event handlers, CSS, DOM IDs and application metadata never do.
enum HTMLSafety {
    static func isSafeURL(_ value: String) -> Bool {
        // A restored fragment can splice markup into an href/src attribute; a
        // URL never contains *literal* angle brackets (U+003C/U+003E) or a
        // double quote (U+0022). Entity-encoded forms (`&quot;`, `&lt;`, `&gt;`)
        // stay safe in a quoted attribute and are handled by the scheme check.
        // Spaces stay allowed: angle-bracket destinations may contain them.
        guard !value.unicodeScalars.contains(where: {
            $0.value == 0x3C || $0.value == 0x3E || $0.value == 0x22
        }) else { return false }
        let decoded = decodeEntities(value)
        let normalized = String(decoded.unicodeScalars.filter { $0.value > 32 && $0.value != 127 }).lowercased()
        guard let colon = normalized.firstIndex(of: ":") else { return true }
        let prefix = normalized[..<colon]
        // A colon in a path/query is not a scheme.
        if prefix.contains("/") || prefix.contains("?") || prefix.contains("#") { return true }
        guard prefix.range(of: #"^[a-z][a-z0-9+.-]*$"#, options: .regularExpression) != nil else { return true }
        return ["http", "https", "mailto", "file"].contains(String(prefix))
    }

    static func sanitizeTag(_ source: String) -> String {
        let ns = source as NSString
        let tagRegex = try! NSRegularExpression(pattern: #"^<(\/?)([A-Za-z]+)"#)
        guard let match = tagRegex.firstMatch(in: source, range: NSRange(location: 0, length: ns.length)) else { return "" }
        let name = ns.substring(with: match.range(at: 2)).lowercased()
        if match.range(at: 1).length > 0 { return "</\(name)>" }
        let attrRegex = try! NSRegularExpression(pattern: #"\s+([A-Za-z][A-Za-z0-9_-]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?"#)
        var cursor = NSMaxRange(match.range)
        var attributes = ""
        var seen: Set<String> = []
        while cursor < ns.length {
            guard let attr = attrRegex.firstMatch(in: source, options: .anchored, range: NSRange(location: cursor, length: ns.length - cursor)) else { break }
            cursor = NSMaxRange(attr.range)
            let key = ns.substring(with: attr.range(at: 1)).lowercased()
            guard seen.insert(key).inserted else { continue }
            if name == "details", key == "open" { attributes += " open"; continue }
            guard key == "title" || (name == "img" && ["src", "alt", "width", "height"].contains(key)) else { continue }
            guard let group = (2...4).first(where: { attr.range(at: $0).location != NSNotFound }) else { continue }
            let value = decodeEntities(ns.substring(with: attr.range(at: group)))
            if key == "src", !isSafeURL(value) { continue }
            if ["width", "height"].contains(key), Int(value).map({ $0 > 0 && $0 <= 100_000 }) != true { continue }
            attributes += " \(key)=\"\(HTMLEscaping.escapeAttribute(value))\""
        }
        return "<\(name)\(attributes)>"
    }

    /// HTML5 numeric-reference replacements for the C1 controls (U+0080–U+009F);
    /// unlisted C1 controls parse as U+FFFD. A browser applies these before it
    /// renders the text, so the continuation guard must too.
    private static let c1Replacements: [UInt32: UInt32] = [
        0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026,
        0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160,
        0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018, 0x92: 0x2019,
        0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
        0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153,
        0x9E: 0x017E, 0x9F: 0x0178
    ]

    static func decodeEntities(_ source: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"&#(?:[xX]([0-9a-fA-F]+)|([0-9]+));?|&(colon|Tab|NewLine|amp|quot|apos|lt|gt);"#)
        let names = ["colon": ":", "Tab": "\t", "NewLine": "\n", "amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">"]
        let ns = source as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if match.range(at: 3).location != NSNotFound {
                result += names[ns.substring(with: match.range(at: 3))] ?? ""
            } else {
                let hex = match.range(at: 1).location != NSNotFound
                let digits = ns.substring(with: match.range(at: hex ? 1 : 2))
                if let value = UInt32(digits, radix: hex ? 16 : 10) {
                    if (0x80...0x9F).contains(value) {
                        if let mapped = c1Replacements[value].flatMap(Unicode.Scalar.init) {
                            result += String(mapped)
                        } else {
                            result += "\u{FFFD}"
                        }
                    } else if let scalar = Unicode.Scalar(value) {
                        result += String(scalar)
                    } else {
                        result += "\u{FFFD}"
                    }
                } else {
                    result += "\u{FFFD}"
                }
            }
            cursor = NSMaxRange(match.range)
        }
        result += ns.substring(from: cursor)
        return result
    }

    // Full HTML5 named references, generated from Python's standard
    // html.entities. `decodeEntities` stays narrow because renderer output
    // preserves authored entity spellings; text that a browser renders (the
    // bare-URL continuation guard) must see every named form.
    private static let namedEntities: [String: String] = {
        guard let url = MD2CoreResources.bundle.url(forResource: "html-entities", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }()

    private static let allEntityPattern = try! NSRegularExpression(
        pattern: #"&(#(?:[xX][0-9a-fA-F]+|[0-9]+)|[A-Za-z][A-Za-z0-9]+);"#)

    /// False when the bundled table failed to load; the bare-URL continuation
    /// guard fails closed rather than trusting an opaque named spelling.
    static var hasNamedEntityTable: Bool { !namedEntities.isEmpty }

    /// Decodes numeric and full HTML5 named references in one pass:
    /// `&amp;lt;` is visible as `&lt;`, not as `<`.
    static func decodeAllEntities(_ source: String) -> String {
        let ns = source as NSString
        var result = ""
        var cursor = 0
        for match in allEntityPattern.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let key = ns.substring(with: match.range(at: 1))
            let literal = ns.substring(with: match.range)
            result += key.hasPrefix("#") ? decodeEntities(literal) : (namedEntities[key] ?? literal)
            cursor = NSMaxRange(match.range)
        }
        return result + ns.substring(from: cursor)
    }
}
