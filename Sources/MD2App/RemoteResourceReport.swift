import Darwin
import Foundation
import MD2Core

/// A static inventory of image declarations in the renderer's body. It never
/// instantiates WebKit content, resolves a hostname, or follows a redirect.
struct RemoteResourceReport: Equatable, Sendable {
    struct Origin: Equatable, Sendable {
        let displayName: String
        let referenceCount: Int
    }

    let origins: [Origin]
    let isPartial: Bool

    private static let maxBodyBytes = 2 * 1024 * 1024
    private static let maxSourceLength = 8_192
    private static let maxOrigins = 128

    var hasRemoteImages: Bool { isPartial || !origins.isEmpty }

    // Scan complete tags rather than matching attribute names inside a title.
    // Renderer-escaped code and links are not image declarations. The style
    // alternative keeps CSS in its own grammar instead of treating it as HTML.
    private static let markup = try! NSRegularExpression(pattern:
        #"(?is)<!--.*?(?:-->|\z)|<style(?=[\s/>])(?:"[^"]*"|'[^']*'|[^"'<>]++)*+>(.*?)</style\s*>|<([a-z][a-z0-9:-]*)(?=[\s/>])((?:"[^"]*"|'[^']*'|[^"'<>]++)*+)>"#)
    private static let attributes = try! NSRegularExpression(pattern:
        #"\s+([^\s/=>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?"#)

    // The renderer emits diagram source as escaped text. Inspect recognizable
    // image syntax in these placeholders only, not in generic fenced code.
    private static let diagramSource = try! NSRegularExpression(pattern:
        #"(?s)<div class="\#(PreviewClass.diagram) (?:\#(PreviewClass.diagramMermaid)|\#(PreviewClass.diagramFlow)|\#(PreviewClass.diagramSequence)) \#(PreviewClass.diagramPending)"[^>]*>([^<]*)</div>"#)
    private static let diagramStyles = try! NSRegularExpression(pattern:
        #"(?m)^[\t ]*(?:classDef|style|linkStyle)\b([^\r\n]+)"#)

    private static let svgImageProperties: Set<String> = [
        "fill", "stroke", "filter", "clip-path", "mask", "cursor", "marker", "marker-start", "marker-mid", "marker-end"
    ]

    private static let cssTokens: NSRegularExpression = {
        let escape = #"\\(?:[0-9a-f]{1,6}(?:\r\n|[\t\n\f\r\x20])?|.)"#
        let doubleQuoted = #"(?:\#(escape)|[^"\\]++)*+"#
        let singleQuoted = #"(?:\#(escape)|[^'\\]++)*+"#
        let unquoted = #"(?:\#(escape)|[^\s"'()\\]++)++"#
        return try! NSRegularExpression(pattern: #"""
        (?isx)
        /\*.*?(?:\*/|\z)|@import\b[^;]*|@font-face\s*\{[^}]*\}
        |"\#(doubleQuoted)"|'\#(singleQuoted)'
        |(?<![a-z0-9_-])((?:[a-z]|\#(escape)){3})\(\s*(?:"(\#(doubleQuoted))"|'(\#(singleQuoted))'|(\#(unquoted)))\s*\)
        """#)
    }()
    private static let cssEscape = try! NSRegularExpression(pattern:
        #"(?s)\\(?:([0-9a-fA-F]{1,6})(?:\r\n|[\t\n\f\r ])?|(\r\n|[\n\r\f])|(.))"#)

    private static let asciiPadding = CharacterSet(charactersIn: Unicode.Scalar(0)!...Unicode.Scalar(32)!)
    private static let urlWhitespace = CharacterSet(charactersIn: "\t\n\r")

    static func inspect(body: String) -> Self {
        guard body.utf8.count <= maxBodyBytes, !Task.isCancelled else {
            return Self(origins: [], isPartial: true)
        }
        let inspection = Inspection()
        inspection.scanMarkup(body)
        inspection.matches(diagramSource, in: body) { match, html in
            let source = decodeAttribute(html.substring(with: match.range(at: 1)))
            inspection.scanMarkup(source)
            inspection.matches(diagramStyles, in: source) { style, diagram in
                inspection.scanCSS(diagram.substring(with: style.range(at: 1)))
            }
        }
        return Self(origins: inspection.counts.sorted { $0.key < $1.key }.map {
            Origin(displayName: $0.key, referenceCount: $0.value)
        }, isPartial: inspection.isPartial)
    }

    private final class Inspection {
        var counts: [String: Int] = [:]
        var isPartial = false

        func matches(_ expression: NSRegularExpression, in source: String,
                     visit: (NSTextCheckingResult, NSString) -> Void) {
            let text = source as NSString
            expression.enumerateMatches(in: source, options: .reportCompletion,
                                        range: NSRange(location: 0, length: text.length)) { match, flags, stop in
                if Task.isCancelled {
                    stop.pointee = true
                    isPartial = true
                    return
                }
                if flags.contains(.internalError) { isPartial = true }
                if let match { visit(match, text) }
            }
        }

        func scanMarkup(_ source: String) {
            matches(markup, in: source) { match, html in
                if match.range(at: 1).location != NSNotFound {
                    scanCSS(html.substring(with: match.range(at: 1)))
                    return
                }
                guard match.range(at: 2).location != NSNotFound, match.range(at: 3).length > 0 else { return }
                let tag = html.substring(with: match.range(at: 2)).lowercased()
                let attributeText = html.substring(with: match.range(at: 3))
                scanAttributes(attributeText, on: tag)
            }
        }

        private func scanAttributes(_ source: String, on tag: String) {
            let svgImage = tag == "image" || tag == "feimage"
            var xlink: String?
            var seen: Set<String> = []
            matches(attributes, in: source) { match, text in
                let key = text.substring(with: match.range(at: 1)).lowercased()
                guard seen.insert(key).inserted,
                      let group = (2...4).first(where: { match.range(at: $0).location != NSNotFound }) else { return }
                let range = match.range(at: group)
                if (key == "src" && tag == "img") || (key == "poster" && tag == "video")
                    || (key == "href" && svgImage) {
                    record(decodeAttribute(text.substring(with: range)))
                } else if key == "srcset", tag == "img" || tag == "source" {
                    scanSourceSet(decodeAttribute(text.substring(with: range)))
                } else if key == "xlink:href", svgImage {
                    xlink = decodeAttribute(text.substring(with: range))
                } else if key == "style" || svgImageProperties.contains(key) {
                    scanCSS(decodeAttribute(text.substring(with: range)))
                }
            }
            if !seen.contains("href"), let xlink { record(xlink) }
        }

        /// Each candidate starts with a URL token ending at HTML whitespace.
        /// Commas inside that token belong to the URL (including data URLs).
        private func scanSourceSet(_ source: String) {
            var remaining = source.utf8[...]
            let comma = UInt8(ascii: ",")
            while !remaining.isEmpty, !Task.isCancelled {
                remaining = remaining.drop { $0 == comma || isHTMLSpace($0) }
                let token = remaining.prefix { !isHTMLSpace($0) }
                let url = token.reversed().drop { $0 == comma }.reversed()
                if !url.isEmpty { record(String(decoding: url, as: UTF8.self)) }
                remaining = remaining.dropFirst(token.count)
                if token.count != url.count { continue }
                var depth = 0
                remaining = remaining.drop {
                    if $0 == UInt8(ascii: "(") { depth += 1 }
                    if $0 == UInt8(ascii: ")") { depth = max(0, depth - 1) }
                    return depth > 0 || $0 != comma
                }
            }
        }

        func scanCSS(_ source: String) {
            matches(cssTokens, in: source) { match, text in
                let function = match.range(at: 1)
                guard function.location != NSNotFound, decodeCSSEscapes(text.substring(with: function)).lowercased() == "url",
                      let group = (2...4).first(where: { match.range(at: $0).location != NSNotFound }) else { return }
                let url = text.substring(with: match.range(at: group))
                record(decodeCSSEscapes(url))
            }
        }

        private func record(_ source: String) {
            // The URL parser strips ASCII padding and embedded tabs/newlines.
            // HTML nulls are replacement characters, never removable padding.
            let value = source.replacingOccurrences(of: "\0", with: "\u{FFFD}")
                .trimmingCharacters(in: asciiPadding)
                .components(separatedBy: urlWhitespace).joined()
            let prefix = String(decoding: value.utf8.prefix(8), as: UTF8.self).lowercased().utf8
            guard prefix.starts(with: "https:".utf8) || prefix.starts(with: "http:".utf8) else { return }
            guard source.utf16.count <= maxSourceLength, let origin = origin(of: value, prefix: prefix),
                  counts[origin] != nil || counts.count < maxOrigins else { isPartial = true; return }
            counts[origin, default: 0] += 1
        }
    }

    private static func isHTMLSpace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 10 || byte == 12 || byte == 13
    }

    private static func decodeAttribute(_ source: String) -> String {
        source.utf8.contains(UInt8(ascii: "&")) ? HTMLSafety.decodeHTMLAttributeEntities(source) : source
    }

    private static func decodeCSSEscapes(_ source: String) -> String {
        guard source.utf8.contains(UInt8(ascii: "\\")) else { return source }
        let text = source as NSString
        var result = ""
        var start = 0
        for escape in cssEscape.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            result += text.substring(with: NSRange(location: start, length: escape.range.location - start))
            let digits = escape.range(at: 1)
            let character = escape.range(at: 3)
            if digits.location != NSNotFound {
                let value = UInt32(text.substring(with: digits), radix: 16) ?? 0
                result.unicodeScalars.append(value == 0 ? "\u{FFFD}" : Unicode.Scalar(value) ?? "\u{FFFD}")
            } else if character.location != NSNotFound {
                result += text.substring(with: character)
            }
            start = NSMaxRange(escape.range)
        }
        return result + text.substring(from: start)
    }

    /// Accept authorities whose browser interpretation we can determine
    /// without making a request. Unusual spellings yield an incomplete report.
    private static func origin(of url: String, prefix: String.UTF8View) -> String? {
        let isHTTPS = prefix.starts(with: "https://".utf8)
        guard isHTTPS || prefix.starts(with: "http://".utf8) else { return nil }
        let scheme = isHTTPS ? "https" : "http"
        let remainder = url.utf8.dropFirst(scheme.utf8.count + 3)
        let authority = remainder.prefix {
            $0 != UInt8(ascii: "/") && $0 != UInt8(ascii: "?") && $0 != UInt8(ascii: "#")
        }
        // In special URLs a backslash can end the authority before an @.
        guard !authority.contains(UInt8(ascii: "\\")) else { return nil }
        let hostAndPort = authority.split(separator: UInt8(ascii: "@"), omittingEmptySubsequences: false).last ?? []
        let host: String
        let portSuffix: String
        if hostAndPort.first == UInt8(ascii: "[") {
            guard let close = hostAndPort.firstIndex(of: UInt8(ascii: "]")),
                  let address = ipv6(String(decoding: hostAndPort.dropFirst().prefix(upTo: close), as: UTF8.self)) else { return nil }
            host = "[\(address)]"
            portSuffix = String(decoding: hostAndPort.suffix(from: hostAndPort.index(after: close)), as: UTF8.self)
        } else {
            let hostBytes = hostAndPort.prefix { $0 != UInt8(ascii: ":") }
            guard hostBytes.allSatisfy({ $0 < 128 }) else { return nil }
            host = String(decoding: hostBytes, as: UTF8.self).lowercased()
            guard isSupportedHost(host) else { return nil }
            portSuffix = String(decoding: hostAndPort.dropFirst(hostBytes.count), as: UTF8.self)
        }

        if portSuffix.isEmpty || portSuffix == ":" { return "\(scheme)://\(host)" }
        guard portSuffix.hasPrefix(":"), portSuffix.utf8.dropFirst().allSatisfy(isDigit),
              let port = UInt16(portSuffix.dropFirst()) else { return nil }
        let isDefaultPort = port == (isHTTPS ? 443 : 80)
        return "\(scheme)://\(host)" + (isDefaultPort ? "" : ":\(port)")
    }

    private static func isSupportedHost(_ host: String) -> Bool {
        let withoutTrailingDot = host.hasSuffix(".") ? host.dropLast() : host[...]
        let labels = withoutTrailingDot.split(separator: ".", omittingEmptySubsequences: false)
        guard let last = labels.last, withoutTrailingDot.utf8.count <= 253,
              labels.allSatisfy({ label in
                  (1...63).contains(label.utf8.count) && !label.hasPrefix("xn--")
                      && label.utf8.allSatisfy { isDigit($0) || (97...122).contains($0) || $0 == UInt8(ascii: "-") }
              }) else { return false }
        let isNumeric = last.utf8.allSatisfy(isDigit) || (last.hasPrefix("0x")
            && last.utf8.dropFirst(2).allSatisfy { isDigit($0) || (97...102).contains($0) })
        guard isNumeric else { return true }
        // The browser interprets a numeric final label as IPv4 (including
        // shortened, octal and hexadecimal forms). Report only dotted decimal.
        return !host.hasSuffix(".") && labels.count == 4 && labels.allSatisfy {
            $0.utf8.allSatisfy(isDigit) && UInt8($0).map { String($0) } == String($0)
        }
    }

    private static func isDigit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }

    private static func ipv6(_ literal: String) -> String? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, literal, &address) == 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}
