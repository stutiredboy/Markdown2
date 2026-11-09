import AppKit
import Foundation
import Testing
@testable import MD2App

@MainActor
struct DocumentStoreImageAttachmentTests {
    // MARK: - Dropped / pasted files link in place (no copy, no save)

    @Test func fileDropLinksDirectlyWithoutSaving() {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("photo.png")

        var pickerCalls = 0
        let store = DocumentStore(saveLocationPicker: { _ in
            pickerCalls += 1
            return nil
        })

        let result = store.insertImageAttachments([.file(source)], folder: "assets")

        #expect(result == ImageAttachmentManager.directImageReference(forFile: source))
        #expect(pickerCalls == 0) // an existing file needs no save
        #expect(store.fileURL == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("assets").path))
    }

    @Test func multiFileDropLinksEachInOrder() {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("one.png")
        let second = directory.appendingPathComponent("two.png")

        let store = DocumentStore()
        let result = store.insertImageAttachments([.file(first), .file(second)], folder: "assets")

        let expected = ImageAttachmentManager.directImageReference(forFile: first)
            + "\n" + ImageAttachmentManager.directImageReference(forFile: second)
        #expect(result == expected)
    }

    // MARK: - Raw clipboard data writes to the attachment folder (needs a save)

    @Test func cancellingSaveInsertsNothingForClipboardImage() {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var pickerCalls = 0
        let store = DocumentStore(saveLocationPicker: { _ in
            pickerCalls += 1
            return nil // user cancels
        })

        let result = store.insertImageAttachments([.imageData(Self.makeTIFFData())], folder: "assets")

        #expect(result == nil)
        #expect(pickerCalls == 1)
        #expect(store.fileURL == nil)
    }

    @Test func savesUntitledThenWritesClipboardImageToAssets() {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let savedDocument = directory.appendingPathComponent("notes.md")

        var pickerCalls = 0
        let store = DocumentStore(saveLocationPicker: { _ in
            pickerCalls += 1
            return savedDocument
        })

        let result = store.insertImageAttachments([.imageData(Self.makeTIFFData())], folder: "assets")

        #expect(pickerCalls == 1)
        #expect(store.fileURL == savedDocument)
        #expect(result?.hasPrefix("![image](assets/image-") == true)
        #expect(result?.hasSuffix(".png)") == true)
    }

    @Test func clipboardWriteFailureSurfacesAlertAndInsertsNothing() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("notes.md")
        try "# Notes\n".write(to: documentURL, atomically: true, encoding: .utf8)

        let store = DocumentStore()
        store.open(documentURL)

        let result = store.insertImageAttachments([.imageData(Data("not an image".utf8))], folder: "assets")

        #expect(result == nil)
        #expect(store.alert != nil)
    }

    @Test func externalFolderRequiresDeliberateChoiceAndCachesOnlyExactDestination() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("document")
        let shared = directory.appendingPathComponent("shared")
        let other = directory.appendingPathComponent("other")
        for url in [document, shared, other] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let source = document.appendingPathComponent("notes.md")
        try "# Notes".write(to: source, atomically: true, encoding: .utf8)
        let link = document.appendingPathComponent("assets")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: shared)
        var choices: [URL] = []
        var allow = false
        let store = DocumentStore(confirmExternalAttachmentDirectory: { url in
            choices.append(url)
            return allow
        })
        store.open(source)
        #expect(store.insertImageAttachments([.imageData(Self.makeTIFFData())], folder: "assets") == nil)
        #expect(choices.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: shared.path).isEmpty)
        allow = true
        #expect(store.insertImageAttachments([.imageData(Self.makeTIFFData())], folder: "assets") != nil)
        #expect(store.insertImageAttachments([.imageData(Self.makeTIFFData())], folder: "assets") != nil)
        #expect(choices.count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: shared.path).count == 2)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        allow = false
        #expect(store.insertImageAttachments([.imageData(Self.makeTIFFData())], folder: "assets") == nil)
        #expect(choices.count == 3)
        #expect(choices[0] != choices[2])
        #expect(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
    }

    @Test func localPastesNeverPromptAndRetargetDuringConfirmationCannotEscapeApproval() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("document")
        let shared = directory.appendingPathComponent("shared")
        let other = directory.appendingPathComponent("other")
        for url in [document, shared, other] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let source = document.appendingPathComponent("notes.md")
        try "# Notes".write(to: source, atomically: true, encoding: .utf8)
        let link = document.appendingPathComponent("shared-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: shared)
        var prompts = 0
        let store = DocumentStore(confirmExternalAttachmentDirectory: { _ in
            prompts += 1
            try! FileManager.default.removeItem(at: link)
            try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
            return true
        })
        store.open(source)
        #expect(store.insertImageAttachments([.imageData(Self.makeTIFFData())], folder: "assets") != nil)
        #expect(prompts == 0)
        #expect(store.insertImageAttachments([.imageData(Self.makeTIFFData())], folder: "shared-link") == nil)
        #expect(prompts == 1)
        #expect(store.alert != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: shared.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
    }

    // MARK: - Helpers

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("md2-store-attach-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makeTIFFData() -> Data {
        NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!.representation(using: .tiff, properties: [:])!
    }
}
