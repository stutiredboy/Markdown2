import Foundation
import MD2Core

enum ImageFileHandling: String, CaseIterable, Sendable {
    case copy, link
}

/// Value-only results cross back to the main actor; no UI or pasteboard objects
/// enter the worker. A failed source adoption never deletes completed files.
enum AttachmentCollection {
    enum Job: Sendable {
        case insert([ImageAttachmentSource], ImageFileHandling, Destination?)
        case collect(String, Destination)
        func run() -> Output {
            switch self {
            case .insert(let sources, let handling, let destination):
                return AttachmentCollection.insert(sources, handling: handling, destination: destination)
            case .collect(let text, let destination):
                return AttachmentCollection.collect(text, destination: destination)
            }
        }
    }
    struct Issue: Sendable {
        let name: String
        let reason: L10nKey
    }
    struct Output: Sendable {
        var text: String
        var written = 0
        var references = 0
        var issues: [Issue] = []
    }
    struct Destination: Sendable {
        let documentDirectory: URL
        let folder: String
        let approvedExternalDirectory: URL?
    }

    static func insert(_ sources: [ImageAttachmentSource], handling: ImageFileHandling,
                       destination: Destination?, limits: LocalImageValidator.Limits = .init()) -> Output {
        var output = Output(text: "")
        guard sources.count <= MarkdownImageReferences.maximumCandidates else {
            output.issues.append(Issue(name: "", reason: .attachmentScanLimit)); return output
        }
        var remainingBytes = limits.totalBytes
        var remainingPixels = limits.totalPixels
        var snippets: [String] = []
        var copied: [URL: WrittenImageAttachment] = [:]
        for source in sources {
            var name = ""
            do {
                switch source {
                case .file(let url):
                    name = url.lastPathComponent
                    let key = ImageAttachmentManager.physicalURL(url)
                    if let prior = copied[key] {
                        snippets.append(reference(prior)); continue
                    }
                    let image = try LocalImageValidator.read(url, limits: limits,
                        remainingBytes: &remainingBytes, remainingPixels: &remainingPixels)
                    if handling == .link {
                        snippets.append(ImageAttachmentManager.directImageReference(forFile: url))
                    } else if let destination {
                        let written = try write(image, source: url, destination: destination)
                        copied[key] = written
                        output.written += 1
                        snippets.append(reference(written))
                    }
                case .imageData(let data):
                    name = ""
                    guard data.count <= remainingBytes else { throw LocalImageValidator.ImageFailure.resourceLimit }
                    remainingBytes -= data.count
                    let validated = try LocalImageValidator.validate(data, extensionHint: "tiff", limits: limits,
                        remainingPixels: &remainingPixels)
                    guard let png = ImageAttachmentManager.encodePNG(from: validated), png.count <= limits.fileBytes else {
                        throw LocalImageValidator.ImageFailure.resourceLimit
                    }
                    if let destination {
                        let written = try ImageAttachmentManager().writeValidatedData(png,
                            stem: ImageAttachmentManager.timestampStem(), ext: "png", alt: "image",
                            toFolder: destination.folder, documentDirectory: destination.documentDirectory,
                            approvedExternalDirectory: destination.approvedExternalDirectory)
                        output.written += 1
                        snippets.append(reference(written))
                    }
                }
            } catch {
                switch source { case .file(let url): name = url.lastPathComponent; case .imageData: name = "" }
                output.issues.append(Issue(name: name, reason: reason(error)))
            }
        }
        if let destination {
            let resolved = ImageAttachmentManager.destination(toFolder: destination.folder, documentDirectory: destination.documentDirectory)
            if resolved.isExternal { output.issues.append(Issue(name: resolved.directory.path, reason: .attachmentExternalNotPortable)) }
        }
        output.references = snippets.count
        output.text = snippets.joined(separator: "\n")
        return output
    }

    static func collect(_ text: String, destination: Destination,
                        limits: LocalImageValidator.Limits = .init()) -> Output {
        var output = Output(text: text)
        let scan = MarkdownImageReferences.scan(text)
        guard !scan.exceededLimit else {
            output.issues.append(Issue(name: "", reason: .attachmentScanLimit)); return output
        }
        output.issues = scan.unsupported.map { Issue(name: $0, reason: .attachmentUnsupportedSyntax) }
        if scan.excludedBlocks > 0 {
            output.issues.append(Issue(name: String(scan.excludedBlocks), reason: .attachmentExcludedBlocks))
        }
        var remainingBytes = limits.totalBytes
        var remainingPixels = limits.totalPixels
        let resolved = ImageAttachmentManager.destination(toFolder: destination.folder,
                                                          documentDirectory: destination.documentDirectory)
        if resolved.isExternal { output.issues.append(Issue(name: resolved.directory.path, reason: .attachmentExternalNotPortable)) }
        var copied: [URL: String] = [:]
        var failed: [URL: L10nKey] = [:]
        var edits: [(NSRange, String)] = []
        for item in scan.references {
            guard let url = localURL(item.destination, base: destination.documentDirectory) else {
                output.issues.append(Issue(name: item.destination, reason: .attachmentNonlocal)); continue
            }
            let key = ImageAttachmentManager.physicalURL(url)
            if let error = failed[key] {
                output.issues.append(Issue(name: item.destination, reason: error)); continue
            }
            do {
                let relative: String
                if let previous = copied[key] { relative = previous }
                else {
                    let image = try LocalImageValidator.read(url, limits: limits,
                        remainingBytes: &remainingBytes, remainingPixels: &remainingPixels)
                    if key.pathComponents.starts(with: resolved.directory.pathComponents) {
                        let suffix = key.pathComponents.dropFirst(resolved.directory.pathComponents.count).joined(separator: "/")
                        relative = resolved.relativeFolder + "/" + suffix
                    } else {
                        relative = try write(image, source: url, destination: destination).relativePath
                        output.written += 1
                    }
                    copied[key] = relative
                }
                edits.append((item.range, ImageAttachmentManager.markdownLinkPath(relative)))
                output.references += 1
            } catch {
                let failure = reason(error)
                failed[key] = failure
                output.issues.append(Issue(name: item.destination, reason: failure))
            }
        }
        let updated = NSMutableString(string: text)
        for (range, replacement) in edits.reversed() { updated.replaceCharacters(in: range, with: replacement) }
        output.text = updated as String
        return output
    }

    private static func write(_ image: LocalImageValidator.Image, source: URL,
                              destination: Destination) throws -> WrittenImageAttachment {
        let stem = ImageAttachmentManager.sanitizedStem(source.deletingPathExtension().lastPathComponent)
        return try ImageAttachmentManager().writeValidatedData(image.data, stem: stem,
            ext: image.fileExtension, alt: stem.isEmpty ? "image" : stem,
            toFolder: destination.folder, documentDirectory: destination.documentDirectory,
            approvedExternalDirectory: destination.approvedExternalDirectory)
    }

    private static func reference(_ written: WrittenImageAttachment) -> String {
        "![\(written.altText)](\(ImageAttachmentManager.markdownLinkPath(written.relativePath)))"
    }

    static func localURL(_ source: String, base: URL) -> URL? {
        guard !source.isEmpty, !source.hasPrefix("//"),
              !source.unicodeScalars.contains(where: { $0.value < 32 }) else { return nil }
        if source.lowercased().hasPrefix("file:") {
            guard let url = URL(string: source), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost",
                  url.query == nil, url.fragment == nil, !url.path.contains("\0") else { return nil }
            return url
        }
        // Any URI scheme is excluded, including data:, mailto: and unknown ones.
        if let colon = source.firstIndex(of: ":"),
           !source[..<colon].contains("/") { return nil }
        guard let decoded = source.removingPercentEncoding, !decoded.contains("\0"), !decoded.hasPrefix("//") else { return nil }
        return decoded.hasPrefix("/") ? URL(fileURLWithPath: decoded)
            : base.appendingPathComponent(decoded).standardizedFileURL
    }

    private static func reason(_ error: Error) -> L10nKey {
        if let failure = error as? LocalImageValidator.ImageFailure {
            return failure == .resourceLimit ? .attachmentResourceLimit : .attachmentInvalidImage
        }
        if case ImageAttachmentManager.AttachmentError.externalDirectory = error { return .attachmentDestinationChanged }
        return .attachmentReadWriteFailed
    }
}
