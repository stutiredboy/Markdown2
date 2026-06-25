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
