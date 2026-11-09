import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One descriptor read and bounded complete image decoding, shared by HTML
/// export and portable attachments. Never trusts a filename as image content.
enum LocalImageValidator {
    struct Image: Sendable {
        let data: Data
        let mime: String
        let fileExtension: String
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
    struct Limits: Sendable {
        var fileBytes = 32 * 1024 * 1024
        var totalBytes = 128 * 1024 * 1024
        var dimension = 16_384
        var pixels = 40_000_000
        var frames = 256
        var totalPixels = 160_000_000
    }

    static func read(_ fileURL: URL, limits: Limits, remainingBytes: inout Int,
                     remainingPixels: inout Int) throws -> Image {
        guard fileURL.isFileURL, !fileURL.path.contains("\0"),
              fileURL.host == nil || fileURL.host == "" || fileURL.host == "localhost",
              isSupportedImageFile(fileURL) else { throw ImageFailure.invalidImage }
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

        return try validate(data, extensionHint: fileURL.pathExtension, limits: limits,
                            remainingPixels: &remainingPixels)
    }

    static func validate(_ data: Data, extensionHint: String, limits: Limits,
                         remainingPixels: inout Int) throws -> Image {
        guard !data.isEmpty else { throw ImageFailure.invalidImage }
        guard data.count <= limits.fileBytes else { throw ImageFailure.resourceLimit }
        let mime: String
        if extensionHint.lowercased() == "svg" {
            guard SVGValidator.validate(data) else { throw ImageFailure.invalidImage }
            mime = "image/svg+xml"
        } else {
            mime = try validatedRasterMIME(data, limits: limits, remainingPixels: &remainingPixels)
        }
        return Image(data: data, mime: mime, fileExtension: UTType(mimeType: mime)?.preferredFilenameExtension ?? "img")
    }

    static func isSupportedImageFile(_ url: URL) -> Bool {
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

}
