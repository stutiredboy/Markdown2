import Foundation
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
        let result = SelfContainedHTMLBuilder.build(html: html, baseURL: dir)

        #expect(result.contains("data:image/png;base64,"))
        #expect(!result.contains(#"src="pic.png""#))
    }

    @Test func inlinesSingleQuotedImageSources() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePNG(named: "pic.png", into: dir)

        let html = #"<main><img alt="x" src = 'pic.png'></main>"#
        let result = SelfContainedHTMLBuilder.build(html: html, baseURL: dir)

        #expect(result.contains("data:image/png;base64,"))
        #expect(!result.contains(#"src = 'pic.png'"#))
    }

    @Test func inlinesAbsoluteLocalImageAsDataURI() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writePNG(named: "abs.png", into: dir)
        let absolutePath = dir.appendingPathComponent("abs.png").path

        let html = "<img src=\"\(absolutePath)\">"
        let result = SelfContainedHTMLBuilder.build(html: html, baseURL: nil)

        #expect(result.contains("data:image/png;base64,"))
        #expect(!result.contains(absolutePath))
    }

    @Test func leavesRemoteImagesUntouched() {
        let html = #"<img src="https://example.com/pic.png">"#
        let result = SelfContainedHTMLBuilder.build(html: html, baseURL: nil)
        #expect(result == html)
    }

    @Test func leavesExistingDataURIUntouched() {
        let html = #"<img src="data:image/gif;base64,R0lGODlhAQ==">"#
        let result = SelfContainedHTMLBuilder.build(html: html, baseURL: nil)
        #expect(result == html)
    }

    @Test func untitledDocumentLeavesRelativeImageAsIs() {
        // No baseURL: a relative path cannot be resolved, so it is left as-is
        // rather than failing the export.
        let html = #"<main><img src="pic.png"></main>"#
        let result = SelfContainedHTMLBuilder.build(html: html, baseURL: nil)
        #expect(result == html)
    }

    @Test func missingRelativeFileIsLeftAsIs() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let html = #"<img src="does-not-exist.png">"#
        let result = SelfContainedHTMLBuilder.build(html: html, baseURL: dir)
        #expect(result == html)
    }

    // MARK: - DocumentStore.exportHTML integration

    @Test func exportHTMLWritesSelfContainedFileAndPreservesDocumentState() throws {
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
        store.exportHTML()

        // Document state is untouched (derived artifact).
        #expect(store.fileURL == fileURLBefore)
        #expect(store.isDirty == dirtyBefore)
        #expect(store.alert == nil)

        let exported = try String(contentsOf: destination, encoding: .utf8)
        // Image inlined; no remaining relative reference.
        #expect(exported.contains("data:image/png;base64,"))
        #expect(!exported.contains(#"src="pic.png""#))
        // Math and diagram engines are embedded (so it renders offline).
        #expect(exported.contains("__md2RenderMath"))
        #expect(exported.contains("__md2RenderDiagrams"))
    }

    @Test func exportHTMLOnUntitledDocumentSucceedsWithoutInliningImages() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("untitled.html")

        // A fresh store has no file location (untitled).
        let store = DocumentStore(htmlDestinationPicker: { _ in destination })
        store.text = "# Untitled\n\n![pic](pic.png)\n"

        #expect(store.fileURL == nil)
        store.exportHTML()

        #expect(store.alert == nil)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let exported = try String(contentsOf: destination, encoding: .utf8)
        // The relative reference is preserved (cannot be resolved without a dir).
        #expect(exported.contains(#"src="pic.png""#))
    }
}
