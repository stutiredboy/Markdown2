import Darwin
import Foundation
import ImageIO
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
    struct Output: Sendable {
        let html: String
        /// Remote sources left as URLs; they need the network to display.
        let remoteImages: [String]
        /// Local references left as written; they may show as broken images.
        let unembeddedLocalImages: [String]
        /// Content/size rejections have a specific explanation in the export notice.
        var localImageFailures: [String: ImageFailure] = [:]
    }

    enum ImageFailure: Error, Sendable {
        case invalidImage, resourceLimit

        var noticeKey: L10nKey {
            switch self {
            case .invalidImage: .alertHTMLExportInvalidImage
            case .resourceLimit: .alertHTMLExportImageLimit
            }
        }
    }

    /// Bound both input bytes and image decoding before allocating raster buffers.
    /// Internal so tests can exercise every boundary with small fixtures.
    struct Limits {
        var fileBytes = 32 * 1024 * 1024
        var totalBytes = 128 * 1024 * 1024
        var dimension = 16_384
        var pixels = 40_000_000
        var frames = 256
        var totalPixels = 160_000_000
    }

    private static let imgTagPattern = #"<img\b[^>]*\bsrc\s*=\s*(['"])(.*?)\1[^>]*>"#

    /// Returns `html` with each `<img>` that points at a local image file replaced
    /// by an inlined `data:` URI, and reports the images it left outside the page.
    static func build(html: String, baseURL: URL?, limits: Limits = Limits()) -> Output {
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
            guard let sourceRange = Range(match.range(at: 2), in: result) else { continue }
            let source = htmlUnescaped(String(result[sourceRange]))
            let lower = source.lowercased()

            guard !source.isEmpty, !lower.hasPrefix("data:") else { continue }

            if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
                remoteImages.append(source)
            } else {
                let name = source.removingPercentEncoding ?? source
                if let fileURL = localImageFileURL(fromSource: source, baseURL: baseURL) {
                    do {
                        let uri = try dataURI(for: fileURL, limits: limits, remainingBytes: &remainingBytes, remainingPixels: &remainingPixels)
                        result.replaceSubrange(sourceRange, with: uri)
                        continue
                    } catch let failure as ImageFailure {
                        failures[name] = failure
                    } catch {
                        // Missing/unreadable files retain the existing generic notice.
                    }
                }
                localImages.append(name)
            }
        }
        return Output(
            html: result,
            remoteImages: uniqued(remoteImages.reversed()),
            unembeddedLocalImages: uniqued(localImages.reversed()),
            localImageFailures: failures
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

    private static func dataURI(for fileURL: URL, limits: Limits, remainingBytes: inout Int,
                                remainingPixels: inout Int) throws -> String {
        // Open once, then inspect and read that descriptor. A symlink to a genuine
        // image is supported; a FIFO/device must never block or be read as an image.
        let fd = open(fileURL.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw ImageFailure.invalidImage
        }
        let byteLimit = max(0, min(limits.fileBytes, remainingBytes))
        guard info.st_size > 0 else { throw ImageFailure.invalidImage }
        guard info.st_size <= byteLimit else { throw ImageFailure.resourceLimit }
        // A file can grow after fstat. The extra byte detects that without an
        // unbounded Data(contentsOf:) allocation or a second path lookup.
        let data = try handle.read(upToCount: byteLimit + 1) ?? Data()
        guard data.count <= byteLimit else { throw ImageFailure.resourceLimit }
        guard !data.isEmpty else { throw ImageFailure.invalidImage }
        remainingBytes -= data.count

        let mime: String
        if fileURL.pathExtension.lowercased() == "svg" {
            guard SVGValidator.validate(data) else { throw ImageFailure.invalidImage }
            mime = "image/svg+xml"
        } else {
            mime = try validatedRasterMIME(data, limits: limits, remainingPixels: &remainingPixels)
        }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    private static func isSupportedImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    private static func validatedRasterMIME(_ data: Data, limits: Limits,
                                            remainingPixels: inout Int) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData,
                                                      [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String), type.conforms(to: .image),
              let mime = type.preferredMIMEType,
              CGImageSourceGetStatus(source) == .statusComplete else {
            throw ImageFailure.invalidImage
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw ImageFailure.invalidImage }
        guard count <= limits.frames else { throw ImageFailure.resourceLimit }
        var imagePixels = 0
        // Check all frames before decoding any of them, including animated images.
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0 else { throw ImageFailure.invalidImage }
            guard width <= limits.dimension, height <= limits.dimension,
                  width <= min(limits.pixels - imagePixels, remainingPixels) / height else { throw ImageFailure.resourceLimit }
            imagePixels += width * height
            remainingPixels -= width * height
        }
        for index in 0..<count {
            let decoded = autoreleasepool {
                CGImageSourceCreateImageAtIndex(source, index,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil
            }
            guard decoded, CGImageSourceGetStatusAtIndex(source, index) == .statusComplete else {
                throw ImageFailure.invalidImage
            }
        }
        // MIME comes from the decoded format, never the authored filename.
        return mime
    }

    /// SVG is XML rather than an ImageIO raster format. Check the complete XML
    /// document and its root without loading DTDs or resolving entities. This is
    /// format validation, not a new policy for SVG's authored resource links.
    private final class SVGValidator: NSObject, XMLParserDelegate {
        private var hasRoot = false
        private var valid = true
        private var depth = 0
        private var elements = 0

        static func validate(_ data: Data) -> Bool {
            let delegate = SVGValidator()
            let parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = true
            // Report external entity declarations so the delegate can reject them;
            // the independent .never policy prevents any file/network resolution.
            parser.shouldResolveExternalEntities = true
            parser.externalEntityResolvingPolicy = .never
            parser.delegate = delegate
            return parser.parse() && delegate.valid && delegate.hasRoot && delegate.depth == 0
        }

        private func reject(_ parser: XMLParser) {
            valid = false
            parser.abortParsing()
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            if !hasRoot {
                hasRoot = true
                guard elementName == "svg", namespaceURI == nil || namespaceURI == "" ||
                        namespaceURI == "http://www.w3.org/2000/svg" else { reject(parser); return }
            }
            depth += 1
            elements += 1
            if depth > 128 || elements > 100_000 { reject(parser) }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) { depth -= 1 }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            reject(parser)
        }

        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
                    publicID: String?, systemID: String?) { reject(parser) }

        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
            reject(parser)
            return nil
        }
    }

    private static func htmlUnescaped(_ source: String) -> String {
        source
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
