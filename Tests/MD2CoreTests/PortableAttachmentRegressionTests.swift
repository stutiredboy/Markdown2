import Foundation
import ImageIO
import Testing
@testable import MD2App
@testable import MD2Core

/// Exact source/assets copied from the coordinator's independent acceptance
/// fixture. No simplified Markdown substitute: angle paths, CRLF, shared
/// definitions, literal code, missing/fake/remote references coexist here.
struct PortableAttachmentRegressionTests {
    private func fixtureURL() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["MD2_ATTACHMENT_ACCEPTANCE_FIXTURE"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return try #require(Bundle.module.url(forResource: "portable-attachments", withExtension: nil, subdirectory: "Corpus"))
    }

    @Test func independentFixtureAngleImageSurvivesMovingOnlyNotesAndRemovingShared() throws {
        let input = try fixtureURL()
        let root = ImageAttachmentManager.physicalURL(FileManager.default.temporaryDirectory.appendingPathComponent("md2-attachment-regression-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: input, to: root)
        let notes = root.appendingPathComponent("notes")
        let shared = root.appendingPathComponent("shared")
        let document = notes.appendingPathComponent("daily-writing.md")
        let originalData = try Data(contentsOf: document)
        let original = try #require(String(data: originalData, encoding: .utf8))
        #expect(original.contains("\r\n"))
        let destination = AttachmentCollection.Destination(documentDirectory: notes, folder: "assets", approvedExternalDirectory: nil)
        let result = AttachmentCollection.collect(original, destination: destination)
        #expect(result.written == 1)
        #expect(result.references == 2)
        #expect(result.issues.contains { $0.reason == .attachmentInvalidImage })
        #expect(result.issues.contains { $0.reason == .attachmentReadWriteFailed })
        #expect(result.issues.contains { $0.reason == .attachmentNonlocal })
        #expect(result.issues.contains { $0.reason == .attachmentUnsupportedSyntax })
        let main = try #require(MarkdownImageReferences.scan(original).references.first { $0.destination == "../shared/图片 sample.png" })
        let newDestination = ImageAttachmentManager.markdownLinkPath("assets/图片-sample.png")
        let expected = NSMutableString(string: original)
        expected.replaceCharacters(in: main.range, with: newDestination)
        // Exactly one destination changed; brackets, spaces, title, attributes,
        // definitions, shared normal link and every CRLF remain literal.
        #expect(Data(result.text.utf8) == Data((expected as String).utf8))
        let second = AttachmentCollection.collect(result.text, destination: destination)
        #expect(second.written == 0)
        #expect(second.references == 2)
        #expect(Data(second.text.utf8) == Data(result.text.utf8))
        try Data(result.text.utf8).write(to: document)
        let expectedImages = ["existing.png": try Data(contentsOf: notes.appendingPathComponent("assets/existing.png")),
                              "图片-sample.png": try Data(contentsOf: shared.appendingPathComponent("图片 sample.png"))]
        let moved = root.appendingPathComponent("moved-notes")
        try FileManager.default.moveItem(at: notes, to: moved)
        try FileManager.default.removeItem(at: shared)
        #expect(!FileManager.default.fileExists(atPath: notes.path))
        #expect(!FileManager.default.fileExists(atPath: shared.path))
        let reopened = try String(contentsOf: moved.appendingPathComponent("daily-writing.md"), encoding: .utf8)
        let rendered = MarkdownRenderer().render(reopened)
        let resolved = LocalImageHTMLRewriter.rewrite(rendered.body, baseURL: moved)
        #expect(resolved.allowedImages.count == 2)
        for servedURL in resolved.allowedImages.values {
            // Foundation may emit /var for a /private/var base. Check the real
            // containing directory, while keeping exact image bytes/decoding.
            let url = URL(fileURLWithPath: ImageAttachmentManager.physicalURL(servedURL).path)
            #expect(url.pathComponents.starts(with: moved.pathComponents))
            let bytes = try Data(contentsOf: url)
            #expect(bytes == expectedImages[url.lastPathComponent])
            let image = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
            #expect(CGImageSourceGetStatus(image) == .statusComplete)
            #expect(CGImageSourceCreateImageAtIndex(image, 0, nil) != nil)
        }
        #expect(!rendered.body.contains("DUMMY-NONIMAGE-CONTENT-DO-NOT-COPY"))
    }

    @Test func attributesRemainLiteralAndBlankSeparatedListIsCountedAsExcluded() throws {
        let input = try fixtureURL()
        let root = ImageAttachmentManager.physicalURL(FileManager.default.temporaryDirectory.appendingPathComponent("md2-attachment-blocks-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: input, to: root)
        let notes = root.appendingPathComponent("notes")
        let shared = root.appendingPathComponent("shared")
        let png = try Data(contentsOf: shared.appendingPathComponent("图片 sample.png"))
        try png.write(to: shared.appendingPathComponent("real.png"))
        try png.write(to: shared.appendingPathComponent("literal.png"))
        let attributes = #"{width=31 note="![literal](../shared/literal.png)"}"#
        let text = "![real](../shared/real.png)" + attributes + "\r\n\r\n- list item\r\n\r\n  ![nested](../shared/literal.png)\r\n\r\n- sibling\r\n"
        let result = AttachmentCollection.collect(text, destination: .init(documentDirectory: notes, folder: "assets", approvedExternalDirectory: nil))
        #expect(result.written == 1)
        #expect(result.references == 1)
        #expect(result.text == text.replacingOccurrences(of: "![real](../shared/real.png)", with: "![real](assets/real.png)"))
        #expect(result.text.contains(attributes))
        #expect(result.issues.contains { $0.reason == .attachmentExcludedBlocks })
        #expect(!FileManager.default.fileExists(atPath: notes.appendingPathComponent("assets/literal.png").path))
    }

    @Test func angleImageRendererRetainsEscapingAndRejectsActiveSchemes() {
        let renderer = MarkdownRenderer()
        let normal = renderer.render(#"![图 &amp; "quoted"](<图片 sample.png> "标题 &amp; &quot;"){width=31}"#).body
        #expect(normal.contains(#"src="图片 sample.png""#))
        #expect(normal.contains(#"alt="图 &amp; &quot;quoted&quot;""#))
        #expect(normal.contains(#"title="标题 &amp; &quot;""#))
        #expect(normal.contains(#"width="31""#))
        #expect(!normal.contains("src=\"&lt;"))
        for scheme in ["javascript:", "javascript&#58;", "vbscript:"] {
            let unsafe = renderer.render("![unsafe](<\(scheme)alert(1)>)").body
            #expect(!unsafe.contains("<img"))
            #expect(!unsafe.contains("src="))
        }
    }
}
