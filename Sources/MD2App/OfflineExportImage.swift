import Foundation

/// A narrower boundary for portable HTML only. It does not change the local
/// image/attachment policy: a file that cannot be proven self-contained is
/// reported and replaced by a readable placeholder in this artifact.
enum OfflineExportImage {
    static func read(_ url: URL, limits: LocalImageValidator.Limits,
                     remainingBytes: inout Int, remainingPixels: inout Int) throws -> LocalImageValidator.Image {
        let image = try LocalImageValidator.read(url, limits: limits,
            remainingBytes: &remainingBytes, remainingPixels: &remainingPixels)
        try checkSVG(image)
        return image
    }

    static func decodeDataURI(_ source: String, limits: LocalImageValidator.Limits,
                              remainingBytes: inout Int, remainingPixels: inout Int) throws -> LocalImageValidator.Image {
        let maximum = max(0, min(limits.fileBytes, remainingBytes))
        guard source.utf8.count <= maximum * 4 + 4096,
              let comma = source.firstIndex(of: ",") else { throw LocalImageValidator.ImageFailure.resourceLimit }
        let header = source[..<comma].lowercased().split(separator: ";").map(String.init)
        guard let mime = header.first, mime.hasPrefix("data:image/") else {
            throw LocalImageValidator.ImageFailure.invalidImage
        }
        let encoded = String(source[source.index(after: comma)...])
        let data: Data?
        if header.last == "base64" {
            data = Data(base64Encoded: encoded)
        } else {
            data = encoded.removingPercentEncoding.map { Data($0.utf8) }
        }
        guard let data, !data.isEmpty else { throw LocalImageValidator.ImageFailure.invalidImage }
        guard data.count <= maximum else { throw LocalImageValidator.ImageFailure.resourceLimit }
        remainingBytes -= data.count
        let image = try LocalImageValidator.validate(data,
            extensionHint: mime == "data:image/svg+xml" ? "svg" : "img",
            limits: limits, remainingPixels: &remainingPixels)
        try checkSVG(image)
        return image
    }

    private static func checkSVG(_ image: LocalImageValidator.Image) throws {
        if image.mime == "image/svg+xml", !OfflineSVG.validate(image.data) {
            throw LocalImageValidator.ImageFailure.invalidImage
        }
    }

    private final class OfflineSVG: NSObject, XMLParserDelegate {
        private var valid = true
        private var styleDepth: Int?
        private var depth = 0
        private var style = ""
        // Static vectors and fragment references have no subsidiary fetch. SVG
        // image/foreignObject/animation and unknown extensions fail closed.
        private static let elements: Set<String> = [
            "svg", "g", "defs", "symbol", "use", "a", "title", "desc", "metadata",
            "path", "rect", "circle", "ellipse", "line", "polyline", "polygon",
            "text", "tspan", "textPath", "linearGradient", "radialGradient", "stop",
            "clipPath", "mask", "marker", "pattern", "style"
        ]

        static func validate(_ data: Data) -> Bool {
            let delegate = OfflineSVG()
            let parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = true
            parser.shouldResolveExternalEntities = false
            parser.externalEntityResolvingPolicy = .never
            parser.delegate = delegate
            return parser.parse() && delegate.valid
        }

        private func reject(_ parser: XMLParser) { valid = false; parser.abortParsing() }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributes: [String: String]) {
            depth += 1
            guard Self.elements.contains(elementName),
                  namespaceURI == nil || namespaceURI == "" || namespaceURI == "http://www.w3.org/2000/svg" else {
                reject(parser); return
            }
            for (name, value) in attributes {
                let name = name.lowercased()
                if name.hasPrefix("on") || name == "xml:base" { reject(parser); return }
                if name == "href" || name.hasSuffix(":href") {
                    if elementName != "a", !Self.fragment(value) { reject(parser); return }
                    if elementName == "a", !Self.safeAnchor(value) { reject(parser); return }
                }
                if name == "style", !OfflineSVGStyle.declarations(value) { reject(parser); return }
                if ["fill", "stroke", "filter", "clip-path", "mask", "marker", "marker-start", "marker-mid", "marker-end", "cursor"].contains(name),
                   !OfflineSVGStyle.value(value) { reject(parser); return }
            }
            if elementName == "style" { styleDepth = depth; style = "" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if styleDepth != nil { style += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if styleDepth != nil { style += String(decoding: CDATABlock, as: UTF8.self) }
        }

        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
            reject(parser)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if styleDepth == depth {
                if !OfflineSVGStyle.stylesheet(style) { reject(parser) }
                styleDepth = nil
            }
            depth -= 1
        }

        static func fragment(_ value: String) -> Bool {
            value.range(of: #"^#[A-Za-z_][A-Za-z0-9_.:-]*$"#, options: .regularExpression) != nil
        }

        private static func safeAnchor(_ value: String) -> Bool {
            let normalized = String(value.unicodeScalars.filter { $0.value > 32 && $0.value != 127 }).lowercased()
            guard let colon = normalized.firstIndex(of: ":") else { return true }
            let prefix = normalized[..<colon]
            if prefix.contains("/") || prefix.contains("?") || prefix.contains("#") { return true }
            return ["http", "https", "mailto", "file"].contains(String(prefix))
        }
    }
}

/// Deliberately small CSS grammar for exported SVG. Ambiguous CSS is rejected,
/// never rewritten with a claim to parse the full language. It supports static
/// vector styles and local gradient/marker references, not imports or fonts.
enum OfflineSVGStyle {
    private static let properties: Set<String> = [
        "fill", "fill-opacity", "fill-rule", "stroke", "stroke-width", "stroke-opacity",
        "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset",
        "opacity", "color", "stop-color", "stop-opacity", "flood-color", "flood-opacity",
        "font-family", "font-size", "font-style", "font-weight", "text-anchor", "dominant-baseline",
        "alignment-baseline", "baseline-shift", "letter-spacing", "word-spacing", "text-decoration",
        "display", "visibility", "overflow", "paint-order", "vector-effect", "shape-rendering",
        "clip-path", "mask", "marker", "marker-start", "marker-mid", "marker-end", "filter"
    ]

    static func value(_ source: String) -> Bool {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.range(of: #"^url\(\s*(['"]?)#[A-Za-z_][A-Za-z0-9_.:-]*\1\s*\)$"#,
                        options: [.regularExpression, .caseInsensitive]) != nil { return true }
        if source.range(of: #"^rgba?\([0-9., %/]+\)$"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return !source.isEmpty && source.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || " #.,%+-'\"_".unicodeScalars.contains($0)
        }
    }

    static func declarations(_ source: String) -> Bool {
        for declaration in source.split(separator: ";", omittingEmptySubsequences: true) {
            guard let colon = declaration.firstIndex(of: ":") else { return false }
            let property = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard properties.contains(property), value(String(declaration[declaration.index(after: colon)...])) else { return false }
        }
        return true
    }

    static func stylesheet(_ source: String) -> Bool {
        var remaining = source[...]
        while !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let open = remaining.firstIndex(of: "{"), let close = remaining.firstIndex(of: "}"), open < close else { return false }
            let selector = remaining[..<open]
            guard !selector.isEmpty, selector.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0) || " #.,:>+~_*-[=]\"'\n\t\r".unicodeScalars.contains($0)
            }), declarations(String(remaining[remaining.index(after: open)..<close])) else { return false }
            remaining = remaining[remaining.index(after: close)...]
        }
        return true
    }
}
