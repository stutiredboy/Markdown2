import Foundation

/// Author HTML is data. Only formatting tags and explicitly inert attributes
/// survive; event handlers, CSS, DOM IDs and application metadata never do.
enum HTMLSafety {
    static func isSafeURL(_ value: String) -> Bool {
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
                if let value = UInt32(digits, radix: hex ? 16 : 10), let scalar = UnicodeScalar(value) { result += String(scalar) }
                else { result += "\u{FFFD}" }
            }
            cursor = NSMaxRange(match.range)
        }
        result += ns.substring(from: cursor)
        return result
    }
}
