import AppKit
import Darwin
import Foundation
import ImageIO
import MD2Core
import Testing
@testable import MD2App

@MainActor
struct SelfContainedHTMLExportTests {
    /// A 1×1 PNG, used as a real on-disk image to inline.
    private static let pngBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("md2-html-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writePNG(named name: String, into dir: URL) throws {
        let data = Data(base64Encoded: Self.pngBase64)!
        try data.write(to: dir.appendingPathComponent(name))
    }

    // MARK: - Builder: image inlining

    @Test func inlinesRelativeLocalImageAsDataURI() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePNG(named: "pic.png", into: dir)

        let html = #"<main><img src="pic.png" alt="x"></main>"#
        let result = SelfContainedHTMLBuilder.build(html: html, baseURL: dir).html

        #expect(result.contains("data:image/png;base64,"))
        #expect(!result.contains(#"src="pic.png""#))
    }

    @Test func inlinesSingleQuotedImageSources() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePNG(named: "pic.png", into: dir)

        let html = #"<main><img alt="x" src = 'pic.png'></main>"#
        let result = SelfContainedHTMLBuilder.build(html: html, baseURL: dir).html

        #expect(result.contains("data:image/png;base64,"))
        #expect(!result.contains(#"src = 'pic.png'"#))
    }

    @Test func inlinesAbsoluteLocalImageAsDataURI() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePNG(named: "abs.png", into: dir)
        let absolutePath = dir.appendingPathComponent("abs.png").path

        let html = "<img src=\"\(absolutePath)\">"
        let result = SelfContainedHTMLBuilder.build(html: html, baseURL: nil).html

        #expect(result.contains("data:image/png;base64,"))
        #expect(!result.contains(absolutePath))
    }

    @Test func remoteImagesBecomeInertPlaceholders() {
        let html = #"<img src="https://example.com/pic.png">"#
        let result = SelfContainedHTMLBuilder.build(html: html, baseURL: nil).html
        #expect(result.contains("md2-export-image-placeholder"))
        #expect(!result.contains("<img"))
    }

    @Test func invalidExistingDataURIBecomesInertPlaceholder() {
        let html = #"<img src="data:image/gif;base64,R0lGODlhAQ==">"#
        let result = SelfContainedHTMLBuilder.build(html: html, baseURL: nil).html
        #expect(result.contains("md2-export-image-placeholder"))
        #expect(!result.contains("<img"))
    }

    @Test func untitledDocumentMakesRelativeImageInert() {
        // No baseURL: a relative path cannot be resolved, so it is left as-is
        // rather than failing the export.
        let html = #"<main><img src="pic.png"></main>"#
        let result = SelfContainedHTMLBuilder.build(html: html, baseURL: nil).html
        #expect(result.contains("md2-export-image-placeholder"))
        #expect(!result.contains("<img"))
    }

    @Test func missingRelativeFileBecomesInert() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let html = #"<img src="does-not-exist.png">"#
        let result = SelfContainedHTMLBuilder.build(html: html, baseURL: dir).html
        #expect(result.contains("md2-export-image-placeholder"))
        #expect(!result.contains("<img"))
    }

    // MARK: - Builder: report of images left outside the page

    @Test func reportsRemoteImageURLsAsInertText() {
        let html = #"<main><img src="https://example.com/a.png"><img src="HTTP://example.com/b.png"></main>"#
        let output = SelfContainedHTMLBuilder.build(html: html, baseURL: nil)

        #expect(output.html.contains("md2-export-image-placeholder"))
        #expect(!output.html.contains("<img"))
        #expect(output.remoteImages == ["https://example.com/a.png", "HTTP://example.com/b.png"])
        #expect(output.unembeddedLocalImages.isEmpty)
    }

    @Test func reportsMissingLocalFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let html = #"<main><img src="missing.png"><img src="/no/such/dir/abs.png"></main>"#
        let output = SelfContainedHTMLBuilder.build(html: html, baseURL: dir)

        #expect(output.html.contains("md2-export-image-placeholder"))
        #expect(!output.html.contains("<img"))
        #expect(output.remoteImages.isEmpty)
        #expect(output.unembeddedLocalImages == ["missing.png", "/no/such/dir/abs.png"])
    }

    @Test func reportsRelativeImageWithNoBaseURLEvenWhenTheFileExists() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePNG(named: "pic.png", into: dir)

        let html = #"<main><img src="pic.png"></main>"#
        let output = SelfContainedHTMLBuilder.build(html: html, baseURL: nil)

        #expect(output.html.contains("md2-export-image-placeholder"))
        #expect(!output.html.contains("<img"))
        #expect(output.unembeddedLocalImages == ["pic.png"])
    }

    @Test func reportsExistingFileThatIsNotAnImage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "not an image".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let output = SelfContainedHTMLBuilder.build(html: #"<main><img src="notes.txt"></main>"#, baseURL: dir)

        #expect(output.unembeddedLocalImages == ["notes.txt"])
    }

    @Test func reportsImageFileThatCannotBeRead() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A directory passes the path and extension checks, then fails to read.
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("folder.png"),
            withIntermediateDirectories: true
        )

        let output = SelfContainedHTMLBuilder.build(html: #"<main><img src="folder.png"></main>"#, baseURL: dir)

        #expect(output.unembeddedLocalImages == ["folder.png"])
    }

    @Test func inlinedImagesAndDataURIsAreNotReported() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePNG(named: "pic.png", into: dir)

        let html = "<main><img src=\"pic.png\"><img src=\"DATA:image/png;base64,\(Self.pngBase64)\"></main>"
        let output = SelfContainedHTMLBuilder.build(html: html, baseURL: dir)

        #expect(output.html.contains("data:image/png;base64,"))
        #expect(output.remoteImages.isEmpty)
        #expect(output.unembeddedLocalImages.isEmpty)
    }

    @Test func reportListsEachImageOnceInDocumentOrder() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePNG(named: "pic.png", into: dir)

        let html = """
        <main><img src="first.png"><img src="https://a.example/1.png"><img src="pic.png">\
        <img src="second.png"><img src="https://b.example/2.png"><img src="third.png">\
        <img src="https://c.example/3.png"><img src="first.png"><img src="https://a.example/1.png"></main>
        """
        let output = SelfContainedHTMLBuilder.build(html: html, baseURL: dir)

        #expect(output.remoteImages == ["https://a.example/1.png", "https://b.example/2.png", "https://c.example/3.png"])
        #expect(output.unembeddedLocalImages == ["first.png", "second.png", "third.png"])
        // The embedded image sits between sources that stay, so inlining it must
        // not disturb them.
        #expect(output.html.contains("data:image/png;base64,"))
        #expect(!output.html.contains(#"<img src="second.png">"#))
        #expect(output.html.contains("second.png</span>"))
    }

    @Test func reportNamesAreReadableNotEscaped() {
        let html = #"<main><img src="my%20pic&amp;co.png"><img src="https://example.com/a%20b.png?x=1&amp;y=2"></main>"#
        let output = SelfContainedHTMLBuilder.build(html: html, baseURL: nil)

        #expect(output.unembeddedLocalImages == ["my pic&co.png"])
        // A URL keeps its percent escapes: they are part of the address.
        #expect(output.remoteImages == ["https://example.com/a%20b.png?x=1&y=2"])
    }

    // MARK: - Content validation (untrusted local references)

    @Test func rejectsDisguisedTextAndSymlinkTargetWithoutEmbeddingTheirBytes() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let secret = Data("dummy-secret-only-for-export-regression".utf8)
        try secret.write(to: dir.appendingPathComponent("secret.txt"))
        try secret.write(to: dir.appendingPathComponent("disguised.png"))
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("innocent.png"),
            withDestinationURL: dir.appendingPathComponent("secret.txt")
        )
        let html = #"<main><img src="disguised.png"><img src="innocent.png"></main>"#

        let output = SelfContainedHTMLBuilder.build(html: html, baseURL: dir)

        #expect(output.html.contains("md2-export-image-placeholder"))
        #expect(!output.html.contains("<img"))
        #expect(!output.html.contains(secret.base64EncodedString()))
        #expect(output.unembeddedLocalImages == ["disguised.png", "innocent.png"])
    }

    @Test func exportOfSymlinkToTextShowsNoticeWithoutLeakingTarget() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let secret = Data("dummy-private-text-for-test".utf8)
        try secret.write(to: dir.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("innocent.png"),
            withDestinationURL: dir.appendingPathComponent("secret.txt")
        )
        let source = dir.appendingPathComponent("notes.md")
        try "![image](innocent.png)".write(to: source, atomically: true, encoding: .utf8)
        let destination = dir.appendingPathComponent("notes.html")
        let store = DocumentStore(htmlDestinationPicker: { _ in destination })
        store.open(source)

        await store.exportHTML()

        let exported = try String(contentsOf: destination, encoding: .utf8)
        #expect(!exported.contains(secret.base64EncodedString()))
        #expect(!exported.contains(String(decoding: secret, as: UTF8.self)))
        let alert = try #require(store.alert)
        #expect(alert.detail.contains("innocent.png — not a valid supported image"))
    }

    @Test func rejectsMalformedOrNonSVGDocuments() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let examples = ["not an image", "<notes>dummy</notes>", "<svg><g></svg>",
                        #"<!DOCTYPE svg [<!ENTITY secret SYSTEM "file:///dummy-test-only">]><svg>&secret;</svg>"#]
        for (index, contents) in (examples + [#"<!DOCTYPE svg [<!ENTITY a "text">]><svg>&a;</svg>"#]).enumerated() {
            let name = "bad-\(index).svg"
            try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            let html = "<img src=\"\(name)\">"
            let output = SelfContainedHTMLBuilder.build(html: html, baseURL: dir)
            #expect(output.html.contains("md2-export-image-placeholder"))
        #expect(!output.html.contains("<img"))
            #expect(output.unembeddedLocalImages == [name])
            // XML declarations/entities cannot bypass validation through UTF-16.
            try contents.data(using: .utf16)!.write(to: dir.appendingPathComponent(name))
            let utf16 = SelfContainedHTMLBuilder.build(html: html, baseURL: dir)
            #expect(utf16.html.contains("md2-export-image-placeholder"))
        #expect(!utf16.html.contains("<img"))
            #expect(utf16.unembeddedLocalImages == [name])
        }
    }

    @Test func preservesValidParentAndSymlinkedImagesAndSVG() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let child = dir.appendingPathComponent("document")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try writePNG(named: "parent.png", into: dir)
        try FileManager.default.createSymbolicLink(at: child.appendingPathComponent("shared.png"),
                                                  withDestinationURL: dir.appendingPathComponent("parent.png"))
        try #"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" width="2" height="2"><rect width="2" height="2"/></svg>"#
            .write(to: child.appendingPathComponent("drawing.svg"), atomically: true, encoding: .utf8)
        let html = #"<img src="../parent.png"><img src="shared.png"><img src="drawing.svg">"#
        let output = SelfContainedHTMLBuilder.build(html: html, baseURL: child)
        #expect(output.unembeddedLocalImages.isEmpty)
        #expect(output.html.components(separatedBy: "data:image/png;base64,").count == 3)
        #expect(output.html.contains("data:image/svg+xml;base64,"))
    }

    @Test func rasterMIMEComesFromContentAndCommonFormatsStillEmbed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let cases: [(NSBitmapImageRep.FileType, String, String)] = [
            (.png, "png", "image/png"), (.jpeg, "jpeg", "image/jpeg"),
            (.gif, "gif", "image/gif"), (.tiff, "tiff", "image/tiff"), (.bmp, "bmp", "image/bmp")
        ]
        for (format, ext, mime) in cases {
            let bytes = try #require(bitmap.representation(using: format, properties: [:]))
            let name = "image.\(ext)"
            try bytes.write(to: dir.appendingPathComponent(name))
            let output = SelfContainedHTMLBuilder.build(html: "<img src=\"\(name)\">", baseURL: dir)
            #expect(output.unembeddedLocalImages.isEmpty)
            #expect(output.html.contains("data:\(mime);base64,"))
        }
        try bitmap.representation(using: .jpeg, properties: [:])!.write(to: dir.appendingPathComponent("wrong.png"))
        let renamed = SelfContainedHTMLBuilder.build(html: #"<img src="wrong.png">"#, baseURL: dir)
        #expect(renamed.html.contains("data:image/jpeg;base64,"))
    }

    @Test func enforcesFileTotalBytesDimensionsPixelsAndFrameLimits() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bitmap.representation(using: .png, properties: [:])!
        try png.write(to: dir.appendingPathComponent("image.png"))
        var cases: [SelfContainedHTMLBuilder.Limits] = []
        var bytes = SelfContainedHTMLBuilder.Limits(); bytes.fileBytes = png.count - 1; cases.append(bytes)
        var total = SelfContainedHTMLBuilder.Limits(); total.totalBytes = png.count - 1; cases.append(total)
        var dimension = SelfContainedHTMLBuilder.Limits(); dimension.dimension = 1; cases.append(dimension)
        var pixels = SelfContainedHTMLBuilder.Limits(); pixels.pixels = 3; cases.append(pixels)
        var totalPixels = SelfContainedHTMLBuilder.Limits(); totalPixels.totalPixels = 3; cases.append(totalPixels)
        var frames = SelfContainedHTMLBuilder.Limits(); frames.frames = 0; cases.append(frames)
        let html = #"<img src="image.png">"#
        for limits in cases {
            let output = SelfContainedHTMLBuilder.build(html: html, baseURL: dir, limits: limits)
            #expect(output.html.contains("md2-export-image-placeholder"))
        #expect(!output.html.contains("<img"))
            #expect(output.localImageFailures["image.png"] == .resourceLimit)
        }
        total.totalBytes = png.count
        let repeated = SelfContainedHTMLBuilder.build(html: html + html, baseURL: dir, limits: total)
        #expect(repeated.html.components(separatedBy: "data:image/png;base64,").count == 2)
        #expect(repeated.unembeddedLocalImages == ["image.png"])
        totalPixels.totalPixels = 4
        let decodedOnce = SelfContainedHTMLBuilder.build(html: html + html, baseURL: dir, limits: totalPixels)
        #expect(decodedOnce.html.components(separatedBy: "data:image/png;base64,").count == 2)
        #expect(decodedOnce.unembeddedLocalImages == ["image.png"])
    }

    @Test func rejectsTruncatedImageAndFIFOWithoutBlocking() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = Data(base64Encoded: Self.pngBase64)!
        try png.prefix(32).write(to: dir.appendingPathComponent("truncated.png"))
        #expect(mkfifo(dir.appendingPathComponent("pipe.png").path, 0o600) == 0)
        let html = #"<img src="truncated.png"><img src="pipe.png">"#
        let output = SelfContainedHTMLBuilder.build(html: html, baseURL: dir)
        #expect(output.html.contains("md2-export-image-placeholder"))
        #expect(!output.html.contains("<img"))
        #expect(output.unembeddedLocalImages == ["truncated.png", "pipe.png"])
    }

    // MARK: - Builder: scan scope

    @Test func imageTagTextInScriptsIsNeitherReportedNorRewritten() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePNG(named: "pic.png", into: dir)

        let script = #"<script>var a = '<img src="pic.png">', b = '<img src="ghost.png">';</script>"#
        let html = #"<body><main><p>text</p></main>"# + script + "</body>"
        let output = SelfContainedHTMLBuilder.build(html: html, baseURL: dir)

        #expect(output.html == html)
        #expect(output.remoteImages.isEmpty)
        #expect(output.unembeddedLocalImages.isEmpty)
    }

    @Test func authoredMainTagDoesNotEndTheScan() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePNG(named: "pic.png", into: dir)

        let rendered = MarkdownRenderer().render("</main>\n\n<main>\n\n![pic](pic.png)\n\n![gone](gone.png)\n")
        let output = SelfContainedHTMLBuilder.build(html: rendered.html, baseURL: dir)

        #expect(output.html.contains("data:image/png;base64,"))
        #expect(output.unembeddedLocalImages == ["gone.png"])
    }

    @Test func renderedPageWithNoImagesReportsNothing() {
        // KaTeX is inlined into every page and its script holds an `<img src=`
        // literal, so a scan of the whole page would report a phantom image here.
        let rendered = MarkdownRenderer().render("# Title\n\nNo images.\n")
        #expect(rendered.html.contains("<img src="))

        let output = SelfContainedHTMLBuilder.build(html: rendered.html, baseURL: nil)

        #expect(output.remoteImages.isEmpty)
        #expect(output.unembeddedLocalImages.isEmpty)
    }

    @Test func imageInDiagramSourceIsNeitherInlinedNorReported() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePNG(named: "pic.png", into: dir)

        // A stated limit: Mermaid creates this `<img>` only when the page is
        // displayed, so here it is escaped text that the builder cannot see.
        let rendered = MarkdownRenderer().render("```mermaid\ngraph TD\n  A[\"<img src='pic.png'>\"]\n```\n")
        let output = SelfContainedHTMLBuilder.build(html: rendered.html, baseURL: dir)

        #expect(output.html == rendered.html)
        #expect(output.remoteImages.isEmpty)
        #expect(output.unembeddedLocalImages.isEmpty)
    }

    @Test func exportImageBuilderRunsOffMainActorWhileInputCanContinue() async {
        let heartbeat = DispatchSemaphore(value: 0)
        let snapshot = DocumentRenderSnapshot(text: "# Export", baseURL: nil,
            citationStyle: .authorYear, numberAllEquations: false)
        // A blocking decoder is deliberate: a main-actor builder would prevent
        // the queued input callback from releasing it and hit the timeout.
        let result = await DocumentRenderWorker().renderSelfContainedHTML(snapshot) { html, baseURL in
            #expect(!Thread.isMainThread)
            DispatchQueue.main.async { heartbeat.signal() }
            #expect(heartbeat.wait(timeout: .now() + 2) == .success)
            return SelfContainedHTMLBuilder.build(html: html, baseURL: baseURL)
        }
        #expect(result.html.contains("Export"))
    }

    @Test(arguments: ["mermaid", "Mermaid", "flow", "sequence"])
    func offlineWorkerRecognizesGeneratedDiagramMarkers(kind: String) async {
        let snapshot = DocumentRenderSnapshot(text: "```\(kind)\nA-->B\n```", baseURL: nil,
            citationStyle: .authorYear, numberAllEquations: false)
        let worker = DocumentRenderWorker()
        let output = await worker.renderSelfContainedHTML(snapshot)
        #expect(output.containsDiagrams)
        #expect(output.remoteImages.isEmpty && output.unembeddedLocalImages.isEmpty)
        let injected = await worker.renderSelfContainedHTML(snapshot) { html, _ in
            #expect(!Thread.isMainThread)
            return SelfContainedHTMLBuilder.Output(html: html, remoteImages: [], unembeddedLocalImages: [])
        }
        #expect(injected.containsDiagrams)
    }

    @Test(arguments: [
        "# Plain\n\nNo diagram.",
        "$x^2$",
        "diagram-mermaid diagram-flow diagram-sequence",
        "```text\n<div class=\"diagram diagram-mermaid diagram-pending\">A-->B</div>\n```",
        "    <div class=\"diagram diagram-flow diagram-pending\">A-->B</div>",
        "<div class=\"diagram diagram-sequence diagram-pending\">A-->B</div>"
    ])
    func offlineWorkerDoesNotTreatTextOrCodeAsDiagrams(source: String) async {
        let snapshot = DocumentRenderSnapshot(text: source, baseURL: nil,
            citationStyle: .authorYear, numberAllEquations: false)
        let output = await DocumentRenderWorker().renderSelfContainedHTML(snapshot)
        #expect(!output.containsDiagrams)
    }

    // MARK: - DocumentStore.exportHTML integration

    @Test func exportHTMLWritesSelfContainedFileAndPreservesDocumentState() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePNG(named: "pic.png", into: dir)

        let sourceURL = dir.appendingPathComponent("notes.md")
        try "# Doc\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let destination = dir.appendingPathComponent("notes.html")

        let store = DocumentStore(htmlDestinationPicker: { _ in destination })
        store.open(sourceURL)
        store.text = """
        # Title

        Inline math $E = mc^2$ and a diagram:

        ```mermaid
        graph TD; A-->B;
        ```

        ![pic](pic.png)
        """

        let fileURLBefore = store.fileURL
        let dirtyBefore = store.isDirty
        await store.exportHTML()

        // Document state is untouched (derived artifact).
        #expect(store.fileURL == fileURLBefore)
        #expect(store.isDirty == dirtyBefore)
        #expect(store.alert?.message == "notes.html was exported as offline HTML.")
        #expect(store.alert?.detail == "Images generated inside diagrams are not embedded in offline HTML. Unsupported resource styles may be omitted; ordinary vector geometry is retained.")

        let exported = try String(contentsOf: destination, encoding: .utf8)
        // Image inlined; no remaining relative reference.
        #expect(exported.contains("data:image/png;base64,"))
        #expect(!exported.contains(#"src="pic.png""#))
        // Math and diagram engines are embedded (so it renders offline).
        #expect(exported.contains("__md2RenderMath"))
        #expect(exported.contains("__md2RenderDiagrams"))
        #expect(!exported.contains("md2-app://"))
        #expect(!exported.contains("<script src="))
    }

    @Test func exportHTMLNamesRemoteAndMissingImagesAfterWritingTheFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = dir.appendingPathComponent("notes.md")
        try "# Doc\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let destination = dir.appendingPathComponent("notes.html")

        let store = DocumentStore(htmlDestinationPicker: { _ in destination })
        store.open(sourceURL)
        store.text = "![remote](https://example.com/r.png)\n\n![missing](missing.png)\n"
        await store.exportHTML()

        let exported = try String(contentsOf: destination, encoding: .utf8)
        #expect(!exported.contains(#"src="https://example.com/r.png""#))
        #expect(!exported.contains(#"src="missing.png""#))

        let alert = try #require(store.alert)
        #expect(alert.message == "notes.html was exported as offline HTML with some images omitted.")
        let expected = """
        Remote images were replaced with inactive placeholders:
        https://example.com/r.png

        These local images could not be embedded and were replaced with inactive placeholders:
        missing.png
        """
        #expect(alert.detail == expected)
    }

    @Test func exportHTMLNoticeOmitsAGroupWithNoImages() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("remote.html")

        let store = DocumentStore(htmlDestinationPicker: { _ in destination })
        store.text = "![remote](https://example.com/r.png)\n"
        await store.exportHTML()

        let alert = try #require(store.alert)
        let expected = """
        Remote images were replaced with inactive placeholders:
        https://example.com/r.png
        """
        #expect(alert.detail == expected)
    }

    @Test func exportHTMLShowsNoNoticeWhenEveryImageIsEmbedded() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePNG(named: "pic.png", into: dir)
        let sourceURL = dir.appendingPathComponent("notes.md")
        try "# Doc\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let destination = dir.appendingPathComponent("notes.html")

        let store = DocumentStore(htmlDestinationPicker: { _ in destination })
        store.open(sourceURL)
        // Authored data: Markdown URLs are rejected by the renderer's scheme
        // boundary. Use real local images to exercise successful embedding here;
        // builder-level tests separately validate existing data image bytes.
        store.text = "![pic](pic.png)\n\n![inline](pic.png)\n"
        await store.exportHTML()

        #expect(store.alert == nil)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let exported = try String(contentsOf: destination, encoding: .utf8)
        #expect(exported.contains("<img src=\"data:image/png;base64,\(Self.pngBase64)\" alt=\"inline\">"))
        #expect(!exported.contains("md2-export-image-placeholder"))
    }

    @Test(arguments: ["# Plain", "# Plain\n\n$x^2$", "```text\n<div class=\"diagram diagram-mermaid diagram-pending\">A-->B</div>\n```"])
    func exportHTMLShowsNoNoticeForADocumentWithNoImagesOrDiagrams(source: String) async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("plain.html")

        let store = DocumentStore(htmlDestinationPicker: { _ in destination })
        store.text = source
        await store.exportHTML()

        #expect(store.alert == nil)
    }

    @Test(arguments: [false, true])
    func exportHTMLExplainsDiagramBoundaryWithoutClaimingAnObservedOmission(chinese: Bool) async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("diagram.html")
        let store = DocumentStore(htmlDestinationPicker: { _ in destination },
                                  alertTextProvider: { L10n.text($0, language: chinese ? .zhHans : .english) })
        defer { store.closeDocument(discardRecovery: true) }
        store.text = "```mermaid\ngraph TD\n  A[\"<img src='https://example.invalid/diagram.png'>\"]\n```\n"
        store.setRemoteImagesAllowed(true)
        await store.exportHTML()

        let alert = try #require(store.alert)
        #expect(alert.message == (chinese ? "diagram.html 已导出为离线 HTML。" : "diagram.html was exported as offline HTML."))
        #expect(alert.detail == (chinese
            ? "离线 HTML 不会嵌入图表内部生成的图片；不支持的资源样式可能被省略，普通矢量图形会保留。"
            : "Images generated inside diagrams are not embedded in offline HTML. Unsupported resource styles may be omitted; ordinary vector geometry is retained."))
        // The worker detects a diagram, but does not claim to enumerate its future images.
        #expect(!alert.detail.contains("diagram.png"))
        let exported = try String(contentsOf: destination, encoding: .utf8)
        #expect(exported.contains("img-src data:;"))
        #expect(!exported.contains("img-src data: http:"))
        #expect(exported.contains("__md2RenderDiagrams"))
        #expect(exported.contains("md2OfflineDiagram"))
        #expect(!exported.contains("<img src='https://example.invalid/diagram.png'>"))
    }

    @Test func exportHTMLAddsDiagramBoundaryToKnownImageOmissionsDespiteSessionGrant() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("mixed.html")
        let store = DocumentStore(htmlDestinationPicker: { _ in destination })
        defer { store.closeDocument(discardRecovery: true) }
        store.text = "![remote](https://example.invalid/image.png)\n\n```mermaid\ngraph TD; A-->B;\n```\n"
        store.setRemoteImagesAllowed(true)
        await store.exportHTML()

        let exported = try String(contentsOf: destination, encoding: .utf8)
        #expect(exported.contains("img-src data:;"))
        #expect(!exported.contains("img-src data: http:"))
        #expect(exported.contains("md2-export-image-placeholder"))
        #expect(exported.contains("Remote image omitted from offline HTML"))
        #expect(!exported.contains(#"src="https://example.invalid/image.png""#))
        let alert = try #require(store.alert)
        #expect(alert.message == "mixed.html was exported as offline HTML with some images omitted.")
        #expect(alert.detail == """
        Remote images were replaced with inactive placeholders:
        https://example.invalid/image.png

        Images generated inside diagrams are not embedded in offline HTML. Unsupported resource styles may be omitted; ordinary vector geometry is retained.
        """)
    }

    @Test func exportHTMLCapsEachGroupOfTheNotice() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("many.html")

        let store = DocumentStore(htmlDestinationPicker: { _ in destination })
        let remote = (1...8).map { "![r](https://example.com/\($0).png)" }
        store.text = (remote + ["![one](one.png)"]).joined(separator: "\n\n") + "\n"
        await store.exportHTML()

        let alert = try #require(store.alert)
        let expected = """
        Remote images were replaced with inactive placeholders:
        https://example.com/1.png
        https://example.com/2.png
        https://example.com/3.png
        https://example.com/4.png
        https://example.com/5.png
        …and 3 more

        These local images could not be embedded and were replaced with inactive placeholders:
        one.png
        """
        #expect(alert.detail == expected)
    }

    @Test func exportHTMLListsExactlyTheCapWithNoSummaryLine() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("five.html")

        let store = DocumentStore(htmlDestinationPicker: { _ in destination })
        store.text = (1...5).map { "![l](\($0).png)" }.joined(separator: "\n\n") + "\n"
        await store.exportHTML()

        let alert = try #require(store.alert)
        #expect(alert.detail.contains("5.png"))
        #expect(!alert.detail.contains("more"))
    }

    @Test func exportHTMLNoticeFollowsTheAppLanguage() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("notes.html")

        let store = DocumentStore(
            htmlDestinationPicker: { _ in destination },
            alertTextProvider: { L10n.text($0, language: .zhHans) }
        )
        store.text = (1...6).map { "![r](https://example.com/\($0).png)" }.joined(separator: "\n\n")
            + "\n\n![missing](missing.png)\n"
        await store.exportHTML()

        let alert = try #require(store.alert)
        #expect(alert.message == "notes.html 已导出为离线 HTML，部分图片已省略。")
        #expect(alert.detail.hasPrefix("以下远程图片已替换为不可加载的占位提示：\n"))
        #expect(alert.detail.contains("另有 1 张未列出"))
        #expect(alert.detail.hasSuffix("以下本地图片无法嵌入，已替换为不可加载的占位提示：\nmissing.png"))
    }

    @Test func exportHTMLFailureReportsTheFailureInsteadOfTheNotice() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("no-such-folder/notes.html")

        let store = DocumentStore(htmlDestinationPicker: { _ in destination })
        store.text = "![remote](https://example.com/r.png)\n"
        await store.exportHTML()

        let alert = try #require(store.alert)
        #expect(alert.message == "Could not export notes.html.")
        #expect(!alert.detail.contains("https://example.com/r.png"))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func exportHTMLOnUntitledDocumentSucceedsWithoutInliningImages() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("untitled.html")

        // A fresh store has no file location (untitled).
        let store = DocumentStore(htmlDestinationPicker: { _ in destination })
        store.text = "# Untitled\n\n![pic](pic.png)\n"

        #expect(store.fileURL == nil)
        await store.exportHTML()

        #expect(FileManager.default.fileExists(atPath: destination.path))
        let exported = try String(contentsOf: destination, encoding: .utf8)
        // The relative reference is preserved (cannot be resolved without a dir)
        // and named in the notice, because it is not in the file.
        #expect(!exported.contains(#"src="pic.png""#))
        let alert = try #require(store.alert)
        #expect(alert.detail.contains("pic.png"))
    }
}
