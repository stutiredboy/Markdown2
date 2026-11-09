import AppKit
import Darwin
import Foundation

/// Pasteboard values captured on the main actor, then validated/copied off it.
/// File sources follow the copy/link preference; raw bitmap data becomes PNG.
enum ImageAttachmentSource: Sendable {
    case file(URL)
    case imageData(Data)
}

/// The relative path and alt text of raw image data written into the attachment
/// folder, ready to be turned into a Markdown image reference.
struct WrittenImageAttachment: Equatable, Sendable {
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

    enum AttachmentError: LocalizedError {
        case unsupportedImageData
        case externalDirectory(URL)

        var errorDescription: String? {
            switch self {
            case .unsupportedImageData:
                return "The pasted image data could not be encoded."
            case .externalDirectory(let url):
                return "The attachment folder points outside this document’s directory: \(url.path). Choose this location explicitly before saving an image there."
            }
        }
    }

    // MARK: - Folder normalization

    /// Normalizes a user-configured attachment folder to a safe, document-relative
    /// POSIX path. Absolute paths, `~` expansion, and any `..` traversal collapse
    /// back to the default. The write boundary separately checks actual resolved
    /// directories, including symlinks. Empty/whitespace also uses the default.
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

    struct Destination: Sendable {
        let documentDirectory: URL
        let directory: URL
        let relativeFolder: String
        let isExternal: Bool
    }

    /// Resolve every existing symlink before any directory creation or file write.
    /// Compare path components, not a textual prefix (`notes-other` is outside).
    static func destination(toFolder folder: String, documentDirectory: URL) -> Destination {
        let root = physicalURL(documentDirectory)
        let normalized = normalizedFolder(folder)
        let directory = physicalURL(root.appendingPathComponent(normalized, isDirectory: true))
        let rootParts = root.pathComponents
        return Destination(documentDirectory: root, directory: directory, relativeFolder: normalized,
            isExternal: !directory.pathComponents.starts(with: rootParts))
    }

    /// Foundation deliberately preserves macOS aliases such as /var. Use
    /// realpath for the existing prefix so O_NOFOLLOW can walk its physical path;
    /// retain missing suffixes for document-local directory creation.
    static func physicalURL(_ url: URL) -> URL {
        var prefix = url.resolvingSymlinksInPath()
        var suffix: [String] = []
        while true {
            if let resolved = realpath(prefix.path, nil) {
                defer { free(resolved) }
                var result = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
                for component in suffix.reversed() { result.appendPathComponent(component, isDirectory: true) }
                return result
            }
            guard errno == ENOENT, prefix.path != "/" else { return url.resolvingSymlinksInPath() }
            suffix.append(prefix.lastPathComponent)
            prefix.deleteLastPathComponent()
        }
    }

    /// Raw clipboard data is saved beside the document by default. An external
    /// symlink target needs explicit approval of that exact resolved directory.
    /// Approval is checked anew on every write so retargeting a link cannot reuse it.
    func writeImageData(
        _ data: Data,
        toFolder folder: String,
        documentDirectory: URL,
        approvedExternalDirectory: URL? = nil
    ) throws -> WrittenImageAttachment {
        guard let png = Self.encodePNG(from: data) else {
            throw AttachmentError.unsupportedImageData
        }
        return try writeValidatedData(png, stem: Self.timestampStem(), ext: "png", alt: "image",
            toFolder: folder, documentDirectory: documentDirectory,
            approvedExternalDirectory: approvedExternalDirectory)
    }

    /// Call only with content from LocalImageValidator or validated PNG encoding.
    func writeValidatedData(_ data: Data, stem: String, ext: String, alt: String,
                            toFolder folder: String, documentDirectory: URL,
                            approvedExternalDirectory: URL? = nil) throws -> WrittenImageAttachment {
        let destination = Self.destination(toFolder: folder, documentDirectory: documentDirectory)
        guard !destination.isExternal || approvedExternalDirectory?.path == destination.directory.path else {
            throw AttachmentError.externalDirectory(destination.directory)
        }

        // Walk the resolved path with O_NOFOLLOW, pinning each directory as we
        // descend. A link changed after the check fails instead of redirecting IO.
        let root = destination.isExternal ? URL(fileURLWithPath: "/") : destination.documentDirectory
        let rootFD = try Self.openDirectory(root)
        defer { close(rootFD) }
        let components = Array(destination.directory.pathComponents.dropFirst(root.pathComponents.count))
        let directoryFD = try Self.descend(from: rootFD, components: components, create: true)
        defer { close(directoryFD) }

        // Create a new file exclusively relative to the pinned directory. This
        // also treats dangling symlinks as collisions, and works on shared/removable
        // filesystems without requiring hard-link support. Only a completed write
        // returns a Markdown reference; a failed new file is removed.
        let stem = Self.sanitizedStem(stem).isEmpty ? Self.timestampStem() : Self.sanitizedStem(stem)
        var index = 1
        while true {
            let filename = index == 1 ? "\(stem).\(ext)" : "\(stem)-\(index).\(ext)"
            let fileFD = openat(directoryFD, filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fileFD < 0 {
                guard errno == EEXIST else { throw Self.posixError() }
                index += 1
                continue
            }
            let handle = FileHandle(fileDescriptor: fileFD, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? handle.close()
                unlinkat(directoryFD, filename, 0)
                throw error
            }
            return WrittenImageAttachment(relativePath: "\(destination.relativeFolder)/\(filename)", altText: alt)
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func openDirectory(_ directory: URL) throws -> Int32 {
        let rootFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { throw posixError() }
        defer { close(rootFD) }
        return try descend(from: rootFD, components: Array(directory.pathComponents.dropFirst()), create: false)
    }

    private static func descend(from rootFD: Int32, components: [String], create: Bool) throws -> Int32 {
        var current = dup(rootFD)
        guard current >= 0 else { throw posixError() }
        do {
            for component in components {
                var next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, create {
                    guard mkdirat(current, component, 0o755) == 0 || errno == EEXIST else { throw posixError() }
                    next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw posixError() }
                close(current)
                current = next
            }
            return current
        } catch {
            close(current)
            throw error
        }
    }

    /// Encodes arbitrary bitmap data (TIFF from the pasteboard) as PNG. Returns
    /// `nil` when the data is not a decodable image.
    static func encodePNG(from data: Data) -> Data? {
        var remainingPixels = LocalImageValidator.Limits().totalPixels
        guard let image = try? LocalImageValidator.validate(data, extensionHint: "tiff",
                  limits: .init(), remainingPixels: &remainingPixels) else { return nil }
        return encodePNG(from: image)
    }

    static func encodePNG(from image: LocalImageValidator.Image) -> Data? {
        guard let rep = NSBitmapImageRep(data: image.data),
              let png = rep.representation(using: .png, properties: [:]),
              png.count <= LocalImageValidator.Limits().fileBytes else { return nil }
        return png
    }
}
