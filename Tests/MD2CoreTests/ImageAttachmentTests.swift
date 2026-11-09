import AppKit
import Foundation
import Testing
@testable import MD2App

struct ImageAttachmentTests {
    // MARK: - Folder normalization

    @Test func normalizesEmptyAndWhitespaceToDefault() {
        #expect(ImageAttachmentManager.normalizedFolder("") == "assets")
        #expect(ImageAttachmentManager.normalizedFolder("   ") == "assets")
    }

    @Test func keepsRelativeNestedFolder() {
        #expect(ImageAttachmentManager.normalizedFolder("assets") == "assets")
        #expect(ImageAttachmentManager.normalizedFolder("images/screenshots") == "images/screenshots")
        #expect(ImageAttachmentManager.normalizedFolder("images/./screenshots") == "images/screenshots")
    }

    @Test func rejectsAbsoluteHomeAndTraversalPaths() {
        #expect(ImageAttachmentManager.normalizedFolder("/etc") == "assets")
        #expect(ImageAttachmentManager.normalizedFolder("~/Pictures") == "assets")
        #expect(ImageAttachmentManager.normalizedFolder("../escape") == "assets")
        #expect(ImageAttachmentManager.normalizedFolder("images/../../escape") == "assets")
    }

    // MARK: - Filename sanitization

    @Test func sanitizesWhitespaceAndUnsafeCharacters() {
        #expect(ImageAttachmentManager.sanitizedStem("my screenshot") == "my-screenshot")
        #expect(ImageAttachmentManager.sanitizedStem("a/b:c*d") == "a-b-c-d")
        #expect(ImageAttachmentManager.sanitizedStem("  spaced out  ") == "spaced-out")
        #expect(ImageAttachmentManager.sanitizedStem("()[]{}") == "")
    }

    @Test func sanitizePreservesCJKAndDigits() {
        #expect(ImageAttachmentManager.sanitizedStem("图表 1") == "图表-1")
        #expect(ImageAttachmentManager.sanitizedStem("diagram2") == "diagram2")
    }

    // MARK: - Collision-safe filenames

    @Test func appendsNumericSuffixOnCollision() {
        var existing: Set<String> = ["image-1.png"]
        let first = ImageAttachmentManager.uniqueFilename(stem: "image-1", ext: "png") { existing.contains($0) }
        #expect(first == "image-1-2.png")

        existing.insert("image-1-2.png")
        let second = ImageAttachmentManager.uniqueFilename(stem: "image-1", ext: "png") { existing.contains($0) }
        #expect(second == "image-1-3.png")
    }

    @Test func usesTimestampStemWhenNameSanitizesEmpty() {
        let name = ImageAttachmentManager.uniqueFilename(stem: "", ext: "png") { _ in false }
        #expect(name.hasPrefix("image-"))
        #expect(name.hasSuffix(".png"))
    }

    // MARK: - Markdown link encoding

    @Test func percentEncodesSpacesAndCJKButKeepsSeparators() {
        #expect(ImageAttachmentManager.markdownLinkPath("assets/my file.png") == "assets/my%20file.png")
        let cjk = ImageAttachmentManager.markdownLinkPath("assets/图表.png")
        #expect(cjk.hasPrefix("assets/"))
        #expect(!cjk.contains("图"))
        #expect(cjk.hasSuffix(".png"))
    }

    @Test func keepsLeadingSlashOnAbsolutePath() {
        #expect(ImageAttachmentManager.markdownLinkPath("/Users/x/My Photos/a.png") == "/Users/x/My%20Photos/a.png")
    }

    @Test func leavesPlainPathUnchanged() {
        #expect(ImageAttachmentManager.markdownLinkPath("assets/diagram.png") == "assets/diagram.png")
    }

    // MARK: - Direct file references (drag / pasted file URL)

    @Test func directImageReferenceLinksToAbsolutePathWithoutCopying() {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("sunset.png")

        let reference = ImageAttachmentManager.directImageReference(forFile: source)

        #expect(reference == "![sunset](\(ImageAttachmentManager.markdownLinkPath(source.path)))")
        #expect(reference.contains(source.deletingLastPathComponent().path))
        // The original file is referenced in place; nothing is copied or created.
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("assets").path))
    }

    @Test func directImageReferenceFallsBackToImageAltForOddName() {
        let reference = ImageAttachmentManager.directImageReference(forFile: URL(fileURLWithPath: "/tmp/()[].png"))
        #expect(reference.hasPrefix("![image]("))
    }

    // MARK: - Local image HTML rewriting

    @Test func rewritesOnlyExistingAbsoluteImageSourcesToLocalScheme() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("external image.png")
        try Self.makeTIFFData().write(to: imageURL)
        let linkPath = ImageAttachmentManager.markdownLinkPath(imageURL.path)
        let html = #"<p><img src="\#(linkPath)" alt="external"><img src="assets/local.png" alt="relative"></p>"#

        let rewritten = LocalImageHTMLRewriter.rewrite(html)

        #expect(rewritten.html.contains(#"src="md2-local-image://image/"#))
        #expect(rewritten.html.contains(#"src="assets/local.png""#))
        #expect(rewritten.allowedImages.values.contains(imageURL))
    }

    @Test func rewritesParentRelativeImageSourcesAgainstDocumentDirectory() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let documentDirectory = root.appendingPathComponent("docs", isDirectory: true)
        let imageDirectory = root.appendingPathComponent("tmp/pdfs", isDirectory: true)
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let imageURL = imageDirectory.appendingPathComponent("beer-01.png")
        try Self.makeTIFFData().write(to: imageURL)
        let html = #"<p><img src="../tmp/pdfs/beer-01.png" alt="beer"></p>"#

        let rewritten = LocalImageHTMLRewriter.rewrite(html, baseURL: documentDirectory)

        #expect(rewritten.html.contains(#"src="md2-local-image://image/"#))
        #expect(!rewritten.html.contains(#"src="../tmp/pdfs/beer-01.png""#))
        #expect(rewritten.allowedImages.values.contains(imageURL.standardizedFileURL))
    }

    /// A live preview update keeps a block whose HTML did not change, so an
    /// image must get the same URL from every rewrite of the same body.
    @Test func localImageTokensAreStablePerFileAndHideThePath() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.png")
        let second = directory.appendingPathComponent("second.png")
        try Self.makeTIFFData().write(to: first)
        try Self.makeTIFFData().write(to: second)
        let html = #"<p><img src="first.png"><img src="second.png"><img src="first.png"></p>"#

        let once = LocalImageHTMLRewriter.rewrite(html, baseURL: directory)
        let again = LocalImageHTMLRewriter.rewrite(html, baseURL: directory)

        #expect(once.html == again.html)
        #expect(once.allowedImages == again.allowedImages)
        #expect(Set(once.allowedImages.values) == [first.standardizedFileURL, second.standardizedFileURL])
        let firstToken = LocalImageHTMLRewriter.token(for: first.standardizedFileURL)
        let secondToken = LocalImageHTMLRewriter.token(for: second.standardizedFileURL)
        #expect(firstToken != secondToken)
        #expect(once.html.components(separatedBy: "md2-local-image://image/\(firstToken)").count == 3)
        #expect(!once.html.contains("first.png"))
        #expect(!once.html.contains(directory.lastPathComponent))
    }

    @Test func localImageRewriterIgnoresMissingAndNonImageAbsoluteSources() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let textURL = directory.appendingPathComponent("secret.txt")
        try "not an image".write(to: textURL, atomically: true, encoding: .utf8)
        let html = #"<p><img src="\#(ImageAttachmentManager.markdownLinkPath(textURL.path))"><img src="/tmp/missing-image.png"></p>"#

        let rewritten = LocalImageHTMLRewriter.rewrite(html)

        #expect(!rewritten.html.contains("md2-local-image://"))
        #expect(rewritten.allowedImages.isEmpty)
    }

    // MARK: - Writing raw clipboard data

    @Test func encodesRawImageDataAsPNG() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let written = try ImageAttachmentManager().writeImageData(
            Self.makeTIFFData(),
            toFolder: "assets",
            documentDirectory: directory
        )

        #expect(written.altText == "image")
        #expect(written.relativePath.hasPrefix("assets/image-"))
        #expect(written.relativePath.hasSuffix(".png"))
        let savedData = try Data(contentsOf: directory.appendingPathComponent(written.relativePath))
        // PNG magic number, proving the TIFF was re-encoded.
        #expect(savedData.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func writesImageDataIntoConfiguredNestedFolder() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let written = try ImageAttachmentManager().writeImageData(
            Self.makeTIFFData(),
            toFolder: "images/screenshots",
            documentDirectory: directory
        )

        #expect(written.relativePath.hasPrefix("images/screenshots/"))
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(written.relativePath).path
        ))
    }

    @Test func writeImageDataRejectsNonImageData() {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: (any Error).self) {
            try ImageAttachmentManager().writeImageData(
                Data("not an image".utf8),
                toFolder: "assets",
                documentDirectory: directory
            )
        }
    }

    @Test func rejectsAttachmentFolderSymlinkOutsideDocumentWithoutWriting() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("document")
        let external = directory.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: document, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: document.appendingPathComponent("assets"),
                                                  withDestinationURL: external)

        #expect(throws: (any Error).self) {
            try ImageAttachmentManager().writeImageData(Self.makeTIFFData(), toFolder: "assets",
                                                        documentDirectory: document)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
    }

    @Test func rejectsNestedSymlinkBeforeCreatingExternalSubdirectory() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("document")
        let external = directory.appendingPathComponent("document-neighbor")
        try FileManager.default.createDirectory(at: document, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: document.appendingPathComponent("images"),
                                                  withDestinationURL: external)
        #expect(throws: (any Error).self) {
            try ImageAttachmentManager().writeImageData(Self.makeTIFFData(), toFolder: "images/screenshots",
                                                        documentDirectory: document)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
    }

    @Test func permitsInternalSymlinkAndSymlinkedDocumentDirectory() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("document")
        let images = document.appendingPathComponent("real-images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: document.appendingPathComponent("assets"), withDestinationURL: images)
        let alias = directory.appendingPathComponent("document-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: document)
        let written = try ImageAttachmentManager().writeImageData(Self.makeTIFFData(), toFolder: "assets",
                                                                 documentDirectory: alias)
        #expect(written.relativePath.hasPrefix("assets/"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: images.path).count == 1)
        #expect(FileManager.default.fileExists(atPath: alias.appendingPathComponent(written.relativePath).path))
    }

    @Test func explicitApprovalWritesToSharedDirectoryButDoesNotApproveAnotherTarget() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("document")
        let shared = directory.appendingPathComponent("shared")
        let other = directory.appendingPathComponent("other")
        for url in [document, shared, other] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let link = document.appendingPathComponent("assets")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: shared)
        let approved = ImageAttachmentManager.destination(toFolder: "assets", documentDirectory: document).directory
        let written = try ImageAttachmentManager().writeImageData(Self.makeTIFFData(), toFolder: "assets",
            documentDirectory: document, approvedExternalDirectory: approved)
        #expect(FileManager.default.fileExists(atPath: document.appendingPathComponent(written.relativePath).path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: shared.path).count == 1)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        #expect(throws: (any Error).self) {
            try ImageAttachmentManager().writeImageData(Self.makeTIFFData(), toFolder: "assets",
                documentDirectory: document, approvedExternalDirectory: approved)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
    }

    // MARK: - Helpers

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("md2-attach-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeTIFFData() -> Data {
        NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!.representation(using: .tiff, properties: [:])!
    }
}
