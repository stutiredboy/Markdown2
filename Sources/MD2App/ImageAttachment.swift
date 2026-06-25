import AppKit
import Foundation

/// One image the editor wants to reference. An existing file (dropped, or a
/// pasted file URL) is linked in place at its current location; raw bitmap data
/// from the clipboard (a screenshot) has no location, so it is saved into the
/// document-relative attachment folder as PNG.
enum ImageAttachmentSource {
    case file(URL)
    case imageData(Data)
}

/// The relative path and alt text of raw image data written into the attachment
/// folder, ready to be turned into a Markdown image reference.
struct WrittenImageAttachment: Equatable {
    /// POSIX relative path from the document directory, e.g. `assets/image-…​.png`.
    let relativePath: String
    /// Alt text for the inserted reference.
    let altText: String
}

/// Document-relative image attachment storage and link generation: folder
/// normalization, collision-safe filenames, link-safe Markdown paths, direct
/// references to existing files, and PNG writes for raw clipboard data. The pure
/// helpers are `static` so they can be unit-tested without the filesystem.
struct ImageAttachmentManager {
    static let defaultFolder = "assets"

    var fileManager: FileManager = .default

    enum AttachmentError: LocalizedError {
        case unsupportedImageData

        var errorDescription: String? {
            switch self {
            case .unsupportedImageData:
                return "The pasted image data could not be encoded."
            }
        }
    }

    // MARK: - Folder normalization

    /// Normalizes a user-configured attachment folder to a safe, document-relative
    /// POSIX path. Absolute paths, `~` expansion, and any `..` traversal collapse
    /// back to the default so an attachment can never be written outside the
    /// document directory. An empty/whitespace value also falls back to the default.
    static func normalizedFolder(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultFolder }

        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return defaultFolder
        }

        let segments = trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        var safe: [String] = []
        for segment in segments {
            let piece = String(segment)
            if piece == "." { continue }
            if piece == ".." { return defaultFolder }
            safe.append(piece)
        }

        guard !safe.isEmpty else { return defaultFolder }
        return safe.joined(separator: "/")
    }

    // MARK: - Filename generation

    /// Sanitizes a filename stem (no extension) into a link-safe token: collapses
    /// whitespace to single hyphens and drops characters outside a conservative
    /// set, while preserving Unicode letters/digits (so CJK names survive on disk).
    /// Returns an empty string when nothing usable remains.
    static func sanitizedStem(_ raw: String) -> String {
        var result = ""
        var pendingHyphen = false
        for scalar in raw.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == "_" || scalar == "-" {
                pendingHyphen = !result.isEmpty
                continue
            }
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "." {
                if pendingHyphen {
                    result.append("-")
                    pendingHyphen = false
                }
                result.unicodeScalars.append(scalar)
            } else {
                pendingHyphen = !result.isEmpty
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
    }

    /// A timestamped fallback stem (`image-20260625-153012`) for raw clipboard data.
    static func timestampStem(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "image-\(formatter.string(from: date))"
    }

    /// Picks a filename `stem.ext` that does not collide with an existing entry,
    /// appending `-2`, `-3`, … until `exists` reports the name is free.
    static func uniqueFilename(stem: String, ext: String, exists: (String) -> Bool) -> String {
        let safeStem = stem.isEmpty ? timestampStem() : stem
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let first = "\(safeStem)\(suffix)"
        if !exists(first) { return first }
        var index = 2
        while true {
            let candidate = "\(safeStem)-\(index)\(suffix)"
            if !exists(candidate) { return candidate }
            index += 1
        }
    }

    // MARK: - Markdown path encoding

    /// Percent-encodes a relative or absolute POSIX path so it parses as a
    /// Markdown image link target. Each path segment is encoded individually
    /// (keeping `/` separators literal), which escapes spaces, CJK, and other
    /// reserved characters the renderer's `(\S+?)` image regex would choke on.
    static func markdownLinkPath(_ path: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { segment in
                segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? String(segment)
            }
            .joined(separator: "/")
    }

    // MARK: - References

    /// A Markdown image reference that links an existing file at its current
    /// location (the file is not copied). The path is absolute and link-safe; alt
    /// text comes from the filename.
    static func directImageReference(forFile url: URL) -> String {
        let stem = sanitizedStem(url.deletingPathExtension().lastPathComponent)
        let alt = stem.isEmpty ? "image" : stem
        return "![\(alt)](\(markdownLinkPath(url.path)))"
    }

    /// Encodes raw clipboard bitmap data as PNG and writes it into `folder` beside
    /// the document (creating the folder if needed), returning the relative path
    /// and alt text for the Markdown reference.
    func writeImageData(
        _ data: Data,
        toFolder folder: String,
        documentDirectory: URL
    ) throws -> WrittenImageAttachment {
        guard let png = Self.encodePNG(from: data) else {
            throw AttachmentError.unsupportedImageData
        }

        let normalizedFolder = Self.normalizedFolder(folder)
        let folderURL = documentDirectory.appendingPathComponent(normalizedFolder, isDirectory: true)
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let filename = Self.uniqueFilename(stem: Self.timestampStem(), ext: "png") { candidate in
            fileManager.fileExists(atPath: folderURL.appendingPathComponent(candidate).path)
        }

        try png.write(to: folderURL.appendingPathComponent(filename), options: .atomic)

        let relativePath = normalizedFolder.isEmpty ? filename : "\(normalizedFolder)/\(filename)"
        return WrittenImageAttachment(relativePath: relativePath, altText: "image")
    }

    /// Encodes arbitrary bitmap data (TIFF from the pasteboard) as PNG. Returns
    /// `nil` when the data is not a decodable image.
    static func encodePNG(from data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
