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

    // Renderer-owned and sanitized HTML uses lowercase image tags and
    // double-quoted attributes. Skip complete preceding attributes so title
    // text cannot look like a source. Code and diagram source are escaped.
    private static let imageSources = try! NSRegularExpression(
        pattern: #"<img(?: [a-z][a-z0-9-]*="[^"]*")*? src="([^"]*)""#)
    private static let asciiPadding = CharacterSet(charactersIn: Unicode.Scalar(0)!...Unicode.Scalar(32)!)
    private static let urlWhitespace = CharacterSet(charactersIn: "\t\n\r")

    static func inspect(body: String) -> Self {
        guard body.utf8.count <= maxBodyBytes, !Task.isCancelled else {
            return Self(origins: [], isPartial: true)
        }
        let html = body as NSString
        var counts: [String: Int] = [:]
        var isPartial = false
        imageSources.enumerateMatches(in: body, options: .reportCompletion,
                                      range: NSRange(location: 0, length: html.length)) { match, flags, stop in
            if Task.isCancelled { stop.pointee = true; return }
            if flags.contains(.internalError) { isPartial = true }
            guard let match else { return }
            let source = match.range(at: 1)
            guard source.length <= maxSourceLength else { isPartial = true; return }
            let attribute = html.substring(with: source)
            let decoded = attribute.utf8.contains(UInt8(ascii: "&"))
                ? HTMLSafety.decodeHTMLAttributeEntities(attribute) : attribute
            // The URL parser strips ASCII padding and embedded tabs/newlines.
            // HTML nulls are replacement characters, never removable padding.
            let value = decoded.replacingOccurrences(of: "\0", with: "\u{FFFD}")
                .trimmingCharacters(in: asciiPadding)
                .components(separatedBy: urlWhitespace).joined()
            let prefix = value.prefix(8).lowercased()
            guard prefix.hasPrefix("https:") || prefix.hasPrefix("http:") else { return }
            guard let origin = origin(of: value, prefix: prefix) else { isPartial = true; return }
            guard counts[origin] != nil || counts.count < maxOrigins else { isPartial = true; return }
            counts[origin, default: 0] += 1
        }
        return Self(origins: counts.sorted { $0.key < $1.key }.map { Origin(displayName: $0.key, referenceCount: $0.value) },
                    isPartial: isPartial)
    }

    /// Accept authorities whose browser interpretation we can determine
    /// without making a request. Unusual spellings yield an incomplete report.
    private static func origin(of url: String, prefix: String) -> String? {
        let isHTTPS = prefix.hasPrefix("https://")
        guard isHTTPS || prefix.hasPrefix("http://") else { return nil }
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
