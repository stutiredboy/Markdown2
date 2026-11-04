import Foundation
import UniformTypeIdentifiers

/// Produces a single HTML document by inlining every locally-stored image
/// referenced by an `<img>` tag as a base64 `data:` URI, so the exported file is
/// portable and opens with no sidecar files. Styles and the math/diagram engines
/// are already inlined by `MarkdownRenderer`, so images are the only remaining
/// external dependency.
///
/// An image that stays outside the file is left untouched and reported in
/// `Output`: a remote `http(s)` image keeps its URL, and a local reference that
/// cannot be embedded stays as written rather than failing the export. That covers
/// a missing, unreadable, or non-image file, and a relative path when `baseURL` is
/// nil (an unsaved document). Already-inlined `data:` URIs need nothing. An image a
/// diagram's own source loads when the page is displayed is out of reach: here that
/// source is escaped text, so it is neither inlined nor reported. This complements
/// `LocalImageHTMLRewriter` (which serves absolute local images to the
/// offscreen PDF web view) by also resolving *relative* paths against the document
/// directory and emitting portable data URIs.
enum SelfContainedHTMLBuilder {
    /// The exported page and the images it still depends on. Names are for
    /// showing to the user, in document order, each listed once.
    struct Output {
        let html: String
        /// Remote sources left as URLs; they need the network to display.
        let remoteImages: [String]
        /// Local references left as written; they may show as broken images.
        let unembeddedLocalImages: [String]
    }

    private static let imgTagPattern = #"<img\b[^>]*\bsrc\s*=\s*(['"])(.*?)\1[^>]*>"#

    /// Returns `html` with each `<img>` that points at a local image file replaced
    /// by an inlined `data:` URI, and reports the images it left outside the page.
    static func build(html: String, baseURL: URL?) -> Output {
        guard let regex = try? NSRegularExpression(pattern: imgTagPattern, options: [.caseInsensitive]) else {
            return Output(html: html, remoteImages: [], unembeddedLocalImages: [])
        }

        let matches = regex.matches(in: html, range: NSRange(contentRange(in: html), in: html))

        var result = html
        var remoteImages: [String] = []
        var localImages: [String] = []
        // Replace right-to-left so earlier ranges stay valid as later text changes.
        for match in matches.reversed() {
            guard let sourceRange = Range(match.range(at: 2), in: result) else { continue }
            let source = htmlUnescaped(String(result[sourceRange]))
            let lower = source.lowercased()

            guard !source.isEmpty, !lower.hasPrefix("data:") else { continue }

            if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
                remoteImages.append(source)
            } else if let fileURL = localImageFileURL(fromSource: source, baseURL: baseURL),
                      let dataURI = dataURI(for: fileURL) {
                result.replaceSubrange(sourceRange, with: dataURI)
            } else {
                localImages.append(source.removingPercentEncoding ?? source)
            }
        }
        return Output(
            html: result,
            remoteImages: uniqued(remoteImages.reversed()),
            unembeddedLocalImages: uniqued(localImages.reversed())
        )
    }

    /// The content of `<main>`, which holds the whole rendered document. Everything
    /// after it is app script: the inlined engines contain `<img src=` string
    /// literals (KaTeX's is in every export) that must not be reported as images.
    /// An authored `</main>` cannot end this early, because raw HTML allows only
    /// formatting tags. A fragment with no `<main>` is all content.
    private static func contentRange(in html: String) -> Range<String.Index> {
        guard let open = html.range(of: "<main>"),
              let close = html.range(of: "</main>", range: open.upperBound..<html.endIndex) else {
            return html.startIndex..<html.endIndex
        }
        return open.upperBound..<close.lowerBound
    }

    private static func uniqued(_ names: some Sequence<String>) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// Resolves a local `<img src>` value, already unescaped, to an image file URL,
    /// or nil if it is an unsupported/non-image file or unresolvable (a relative
    /// path with no `baseURL`, or a missing file).
    private static func localImageFileURL(fromSource source: String, baseURL: URL?) -> URL? {
        let candidate: URL?
        if source.lowercased().hasPrefix("file://"), let parsed = URL(string: source), parsed.isFileURL {
            candidate = parsed
        } else if source.hasPrefix("/") {
            candidate = URL(fileURLWithPath: source.removingPercentEncoding ?? source)
        } else if source.contains("://") {
            // Some other scheme (e.g. the app's local-image scheme) is not a path.
            candidate = nil
        } else if let baseURL {
            // Append to the document directory (robust whether or not `baseURL`
            // carries a trailing slash); `standardizedFileURL` resolves `.`/`..`.
            let relativePath = source.removingPercentEncoding ?? source
            candidate = baseURL.appendingPathComponent(relativePath).standardizedFileURL
        } else {
            candidate = nil
        }

        guard let url = candidate,
              isSupportedImageFile(url),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    private static func dataURI(for fileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return "data:\(mimeType(for: fileURL));base64,\(data.base64EncodedString())"
    }

    private static func isSupportedImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    private static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    private static func htmlUnescaped(_ source: String) -> String {
        source
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
