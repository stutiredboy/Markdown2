import Foundation
import MD2Core

struct OfflineHTMLLabels: Sendable {
    var remoteImageBlocked: String = "Remote image omitted from offline HTML"
    var localImageUnavailable: String = "Image could not be embedded in offline HTML"
}

/// Produces a single HTML document by inlining every locally-stored image
/// referenced by an `<img>` tag as a base64 `data:` URI, so the exported file is
/// portable and opens with no sidecar files. Styles and the math/diagram engines
/// are already inlined by `MarkdownRenderer`, so images are the only remaining
/// external dependency.
///
/// Every image that cannot be validated and embedded becomes inert readable
/// text, including remote images and unresolved relative paths. A session's
/// preview grant is never exported. The renderer's offline diagram boundary
/// handles images created later by bundled engines.
enum SelfContainedHTMLBuilder {
    /// The exported page and the images it still depends on. Names are for
    /// showing to the user, in document order, each listed once.
    struct Output: Sendable {
        let html: String
        /// Remote sources omitted from the artifact, shown only as inert text.
        let remoteImages: [String]
        /// Local/data references that could not be validated and embedded.
        let unembeddedLocalImages: [String]
        /// Content/size rejections have a specific explanation in the export notice.
        var localImageFailures: [String: ImageFailure] = [:]
    }

    typealias ImageFailure = LocalImageValidator.ImageFailure
    typealias Limits = LocalImageValidator.Limits

    private static let imgTagPattern = #"<img\b[^>]*\bsrc\s*=\s*(['"])(.*?)\1[^>]*>"#

    /// Rebuilds each rendered image from safe attributes: stale srcset/style
    /// attributes cannot survive beside an otherwise valid embedded src.
    static func build(html: String, baseURL: URL?, limits: Limits = Limits(),
                      labels: OfflineHTMLLabels = .init()) -> Output {
        guard let regex = try? NSRegularExpression(pattern: imgTagPattern, options: [.caseInsensitive]) else {
            return Output(html: html, remoteImages: [], unembeddedLocalImages: [])
        }

        let matches = regex.matches(in: html, range: NSRange(contentRange(in: html), in: html))

        var result = html
        var remoteImages: [String] = []
        var localImages: [String] = []
        var failures: [String: ImageFailure] = [:]
        var remainingBytes = limits.totalBytes
        var remainingPixels = limits.totalPixels
        // Replace right-to-left so earlier ranges stay valid as later text changes.
        for match in matches.reversed() {
            guard let sourceRange = Range(match.range(at: 2), in: result),
                  let tagRange = Range(match.range, in: result) else { continue }
            let tag = String(result[tagRange])
            let source = htmlUnescaped(String(result[sourceRange]))
            let lower = source.lowercased()
            let remote = lower.hasPrefix("http://") || lower.hasPrefix("https://") || source.hasPrefix("//")
            let name = lower.hasPrefix("data:") ? "Embedded image" : (source.removingPercentEncoding ?? source)
            if remote {
                remoteImages.append(source)
            } else {
                do {
                    let image: LocalImageValidator.Image
                    if lower.hasPrefix("data:") {
                        image = try OfflineExportImage.decodeDataURI(source, limits: limits,
                            remainingBytes: &remainingBytes, remainingPixels: &remainingPixels)
                    } else if let fileURL = localImageFileURL(fromSource: source, baseURL: baseURL) {
                        image = try OfflineExportImage.read(fileURL, limits: limits,
                            remainingBytes: &remainingBytes, remainingPixels: &remainingPixels)
                    } else {
                        throw CocoaError(.fileReadNoSuchFile)
                    }
                    let uri = "data:\(image.mime);base64,\(image.data.base64EncodedString())"
                    result.replaceSubrange(tagRange, with: embeddedTag(uri: uri, original: tag))
                    continue
                } catch let failure as ImageFailure {
                    failures[name] = failure
                } catch {
                    // Missing/unreadable images have a distinct generic notice.
                }
                localImages.append(name)
            }
            let label = remote ? labels.remoteImageBlocked : labels.localImageUnavailable
            let alt = attribute("alt", in: tag).map { $0.isEmpty ? "" : " — \($0)" } ?? ""
            result.replaceSubrange(tagRange, with:
                "<span class=\"md2-export-image-placeholder\" role=\"img\">\(escaped(label + alt)) " +
                "<span class=\"md2-export-image-source\">\(escaped(name))</span></span>")
        }
        return Output(
            html: result,
            remoteImages: uniqued(remoteImages.reversed()),
            unembeddedLocalImages: uniqued(localImages.reversed()),
            localImageFailures: failures
        )
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let regex = try! NSRegularExpression(pattern: "\\b" + name + #"\s*=\s*(['"])(.*?)\1"#, options: [.caseInsensitive])
        guard let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 2), in: tag) else { return nil }
        return htmlUnescaped(String(tag[range]))
    }

    private static func embeddedTag(uri: String, original: String) -> String {
        var result = "<img src=\"\(uri)\""
        for key in ["alt", "title", "width", "height"] {
            if let value = attribute(key, in: original) {
                if ["width", "height"].contains(key), Int(value).map({ $0 > 0 && $0 <= 100_000 }) != true { continue }
                result += " \(key)=\"\(escaped(value))\""
            }
        }
        return result + ">"
    }

    private static func escaped(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            switch scalar.value {
            case 38: "&amp;"
            case 60: "&lt;"
            case 62: "&gt;"
            case 34: "&quot;"
            case 39: "&#39;"
            default: String(scalar)
            }
        }.joined()
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

    private static func isSupportedImageFile(_ url: URL) -> Bool {
        LocalImageValidator.isSupportedImageFile(url)
    }

    private static func htmlUnescaped(_ source: String) -> String {
        HTMLSafety.decodeHTMLAttributeEntities(source)
    }
}
