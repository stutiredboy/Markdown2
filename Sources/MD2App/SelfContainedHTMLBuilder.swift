import Foundation
import UniformTypeIdentifiers

/// Produces a single self-contained HTML document by inlining every locally-stored
/// image referenced by an `<img>` tag as a base64 `data:` URI, so the exported file
/// is portable and opens with no sidecar files and no network. Styles and the
/// math/diagram engines are already inlined by `MarkdownRenderer`, so images are
/// the only remaining external dependency.
///
/// Remote `http(s)` images, already-inlined `data:` URIs, and unresolvable
/// references are left untouched. When `baseURL` is nil (an unsaved document)
/// relative paths cannot be resolved and are left as-is rather than failing the
/// export. This complements `LocalImageHTMLRewriter` (which serves absolute local
/// images to the offscreen PDF web view) by also resolving *relative* paths against
/// the document directory and emitting portable data URIs.
enum SelfContainedHTMLBuilder {
    private static let imgTagPattern = #"<img\b[^>]*\bsrc\s*=\s*(['"])(.*?)\1[^>]*>"#

    /// Returns `html` with each `<img>` that points at a local image file replaced
    /// by an inlined `data:` URI. Non-local and unresolvable sources are unchanged.
    static func build(html: String, baseURL: URL?) -> String {
        guard let regex = try? NSRegularExpression(pattern: imgTagPattern, options: [.caseInsensitive]) else {
            return html
        }

        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: nsRange)
        guard !matches.isEmpty else { return html }

        var result = html
        // Replace right-to-left so earlier ranges stay valid as later text changes.
        for match in matches.reversed() {
            guard let sourceRange = Range(match.range(at: 2), in: result) else { continue }
            let original = String(result[sourceRange])
            guard let fileURL = localImageFileURL(fromHTMLSource: original, baseURL: baseURL),
                  let dataURI = dataURI(for: fileURL) else {
                continue
            }
            result.replaceSubrange(sourceRange, with: dataURI)
        }
        return result
    }

    /// Resolves an `<img src>` value to a local image file URL, or nil if it is a
    /// remote reference, already a data URI, an unsupported/non-image file, or
    /// unresolvable (a relative path with no `baseURL`, or a missing file).
    private static func localImageFileURL(fromHTMLSource source: String, baseURL: URL?) -> URL? {
        let unescaped = htmlUnescaped(source)
        let lower = unescaped.lowercased()

        // Remote or already-inlined references are left untouched.
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("data:") {
            return nil
        }

        let candidate: URL?
        if lower.hasPrefix("file://"), let parsed = URL(string: unescaped), parsed.isFileURL {
            candidate = parsed
        } else if unescaped.hasPrefix("/") {
            candidate = URL(fileURLWithPath: unescaped.removingPercentEncoding ?? unescaped)
        } else if unescaped.contains("://") {
            // Some other scheme (e.g. the app's local-image scheme) is not a path.
            candidate = nil
        } else if let baseURL {
            // Append to the document directory (robust whether or not `baseURL`
            // carries a trailing slash); `standardizedFileURL` resolves `.`/`..`.
            let relativePath = unescaped.removingPercentEncoding ?? unescaped
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
