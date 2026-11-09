import AppKit
import Darwin
import Foundation
import Testing
@testable import MD2App
@testable import MD2Core

private struct AttachmentFixture {
    let root: URL
    let documentDirectory: URL
    let source: URL
    let document: URL
    init(text: String = "# Notes\n") throws {
        // Bookmark relocation returns physical paths; make the fixture equally
        // explicit instead of conflating macOS /var and /private/var aliases.
        root = ImageAttachmentManager.physicalURL(FileManager.default.temporaryDirectory.appendingPathComponent("md2-portable-\(UUID())"))
        documentDirectory = root.appendingPathComponent("document")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        source = outside.appendingPathComponent("图 image.png")
        document = documentDirectory.appendingPathComponent("notes.md")
        try Self.png.write(to: source)
        try text.write(to: document, atomically: true, encoding: .utf8)
    }
    var destination: AttachmentCollection.Destination {
        .init(documentDirectory: documentDirectory, folder: "assets", approvedExternalDirectory: nil)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    static var png: Data {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            .representation(using: .png, properties: [:])!
    }
}

struct PortableAttachmentTests {
    @Test func copyIsPortableAfterMovingDirectoryAndRemovingOriginals() throws {
        let fixture = try AttachmentFixture()
        defer { fixture.cleanup() }
        let path = ImageAttachmentManager.markdownLinkPath(fixture.source.path)
        let source = "😀 e\u{301}\r\n![中文](\(path) \"keep title\"){width=42 #fig:demo}\r\n![same](\(path))\r\n"
        let result = AttachmentCollection.collect(source, destination: fixture.destination)
        #expect(result.written == 1)
        #expect(result.references == 2)
        #expect(result.issues.isEmpty)
        let reference = try #require(MarkdownImageReferences.scan(result.text).references.first)
        let expected = source.replacingOccurrences(of: path, with: reference.destination)
        #expect((result.text as NSString).isEqual(to: expected))
        try result.text.write(to: fixture.document, atomically: true, encoding: .utf8)
        let moved = fixture.root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: fixture.documentDirectory, to: moved)
        try FileManager.default.removeItem(at: fixture.source.deletingLastPathComponent())
        let reopened = try String(contentsOf: moved.appendingPathComponent("notes.md"), encoding: .utf8)
        let rendered = MarkdownRenderer().render(reopened)
        let local = LocalImageHTMLRewriter.rewrite(rendered.body, baseURL: moved)
        #expect(local.allowedImages.count == 1)
        #expect(try Data(contentsOf: #require(local.allowedImages.values.first)) == AttachmentFixture.png)
        let again = AttachmentCollection.collect(reopened, destination: .init(documentDirectory: moved,
            folder: "assets", approvedExternalDirectory: nil))
        #expect(again.written == 0)
        #expect((again.text as NSString).isEqual(to: reopened))
    }

    @Test func explicitLinkDoesNotCopyAndDuplicateDropsCopyOnce() throws {
        let fixture = try AttachmentFixture()
        defer { fixture.cleanup() }
        let linked = AttachmentCollection.insert([.file(fixture.source)], handling: .link, destination: nil)
        #expect(linked.written == 0)
        #expect(linked.text == ImageAttachmentManager.directImageReference(forFile: fixture.source))
        #expect(!FileManager.default.fileExists(atPath: fixture.documentDirectory.appendingPathComponent("assets").path))
        let copied = AttachmentCollection.insert([.file(fixture.source), .file(fixture.source)],
            handling: .copy, destination: fixture.destination)
        #expect(copied.written == 1)
        #expect(copied.references == 2)
        #expect(!copied.text.contains(fixture.source.path))
    }

    @Test func failuresAndNonlocalImagesStayIntactWithoutFiles() throws {
        let fixture = try AttachmentFixture()
        defer { fixture.cleanup() }
        try Data("not a real image; secret".utf8).write(to: fixture.documentDirectory.appendingPathComponent("fake.png"))
        let fifo = fixture.documentDirectory.appendingPathComponent("pipe.png")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let text = "![fake](fake.png)\n![missing](missing.png)\n![fifo](pipe.png)\n![web](https://example.invalid/x.png)\n![data](data:image/png;base64,xx)\n![ref][shared]\n\n[shared]: fake.png \"leave\"\n\n[normal][shared]\n"
        let result = AttachmentCollection.collect(text, destination: fixture.destination)
        #expect(result.written == 0)
        #expect(result.text == text)
        #expect(result.issues.filter { $0.reason == .attachmentInvalidImage }.count == 2)
        #expect(result.issues.contains { $0.reason == .attachmentReadWriteFailed })
        #expect(result.issues.filter { $0.reason == .attachmentNonlocal }.count == 2)
        #expect(result.issues.contains { $0.reason == .attachmentUnsupportedSyntax })
        #expect(!FileManager.default.fileExists(atPath: fixture.documentDirectory.appendingPathComponent("assets").path))
    }

    @Test func sourceByteAndPixelLimitsRejectBeforeCopy() throws {
        let fixture = try AttachmentFixture()
        defer { fixture.cleanup() }
        for limits in [LocalImageValidator.Limits(fileBytes: 4), LocalImageValidator.Limits(pixels: 1),
                       LocalImageValidator.Limits(totalBytes: 4), LocalImageValidator.Limits(totalPixels: 1)] {
            let result = AttachmentCollection.insert([.file(fixture.source)], handling: .copy,
                destination: fixture.destination, limits: limits)
            #expect(result.written == 0)
            #expect(result.issues.first?.reason == .attachmentResourceLimit)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.documentDirectory.appendingPathComponent("assets").path))
    }

    @Test func exclusiveCreationPreservesExistingFileAndDanglingSymlink() throws {
        let fixture = try AttachmentFixture()
        defer { fixture.cleanup() }
        let folder = fixture.documentDirectory.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = folder.appendingPathComponent("图-image.png")
        let dangling = folder.appendingPathComponent("图-image-2.png")
        try Data("existing".utf8).write(to: existing)
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: fixture.root.appendingPathComponent("missing"))
        let result = AttachmentCollection.insert([.file(fixture.source)], handling: .copy, destination: fixture.destination)
        #expect(result.written == 1)
        #expect(result.text.contains("-3.png"))
        #expect(try String(contentsOf: existing, encoding: .utf8) == "existing")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dangling.path) == fixture.root.appendingPathComponent("missing").path)
    }

    @Test func approvedExternalDestinationCannotBeReusedAfterRetarget() throws {
        let fixture = try AttachmentFixture()
        defer { fixture.cleanup() }
        let outside = fixture.source.deletingLastPathComponent()
        let link = fixture.documentDirectory.appendingPathComponent("assets")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let approved = ImageAttachmentManager.destination(toFolder: "assets", documentDirectory: fixture.documentDirectory).directory
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root)
        let result = AttachmentCollection.insert([.file(fixture.source)], handling: .copy,
            destination: .init(documentDirectory: fixture.documentDirectory, folder: "assets", approvedExternalDirectory: approved))
        #expect(result.written == 0)
        #expect(result.issues.first?.reason == .attachmentDestinationChanged)
    }

    @Test func fileURLsAreLocalButRemoteHostsAndAllOtherSchemesAreExcluded() throws {
        let fixture = try AttachmentFixture()
        defer { fixture.cleanup() }
        #expect(AttachmentCollection.localURL(fixture.source.absoluteString, base: fixture.documentDirectory) == fixture.source)
        for path in ["//host/x.png", "file://remote/x.png", "data:image/png,xx", "ftp://host/x.png", "custom:x.png", "x%00.png", "bad%xy.png"] {
            #expect(AttachmentCollection.localURL(path, base: fixture.documentDirectory) == nil)
        }
    }
}

private actor AttachmentGate {
    private var paused: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        await withCheckedContinuation { continuation in
            paused = continuation
            for observer in observers { observer.resume() }
            observers.removeAll()
        }
    }
    func waitForPause() async {
        if paused != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { paused?.resume(); paused = nil }
}

@MainActor
struct PortableAttachmentStoreTests {
    @Test func defaultCopiesAndCancellationBeforeFirstSaveWritesNothing() async throws {
        let fixture = try AttachmentFixture()
        defer { fixture.cleanup() }
        let store = DocumentStore(saveLocationPicker: { _ in fixture.document })
        let snippet = await store.insertImageAttachments([.file(fixture.source)], folder: "assets")
        #expect(snippet?.contains("assets/") == true)
        #expect(store.fileURL == fixture.document)
        let cancelled = DocumentStore(saveLocationPicker: { _ in nil })
        #expect(await cancelled.insertImageAttachments([.file(fixture.source)], folder: "different") == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.documentDirectory.appendingPathComponent("different").path))
        _ = store.closeDocument(discardRecovery: true)
        _ = cancelled.closeDocument(discardRecovery: true)
    }

    @Test func collectionIsOneUndoRedoWithSourceAndCRLFPreserved() async throws {
        let fixture = try AttachmentFixture()
        defer { fixture.cleanup() }
        let path = ImageAttachmentManager.markdownLinkPath(fixture.source.path)
        let source = "😀\r\n![a](\(path) \"title\"){width=30}\r\n![b](\(path))\r\n"
        try source.write(to: fixture.document, atomically: true, encoding: .utf8)
        let store = DocumentStore()
        store.open(fixture.document)
        store.undoManager.groupsByEvent = false
        await store.collectLocalImages(folder: "assets")
        let collected = store.text
        #expect(collected.contains("assets/"))
        #expect(store.undoManager.canUndo)
        store.undoManager.undo()
        #expect((store.text as NSString).isEqual(to: source))
        #expect(!store.undoManager.canUndo)
        store.undoManager.redo()
        #expect((store.text as NSString).isEqual(to: collected))
        #expect(store.isDirty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.documentDirectory.appendingPathComponent("assets").path).count == 1)
        _ = store.closeDocument(discardRecovery: true)
    }

    @Test func staleRevisionAndCloseRefuseRewriteButReportCompletedFiles() async throws {
        for close in [false, true] {
            let fixture = try AttachmentFixture(text: "![a](../outside/图%20image.png)\n")
            defer { fixture.cleanup() }
            let store = DocumentStore()
            store.open(fixture.document)
            let original = store.text
            let gate = AttachmentGate()
            store.attachmentWorker = { job in
                let result = await Task.detached { job.run() }.value
                await gate.pause()
                return result
            }
            let task = Task { await store.collectLocalImages(folder: "assets") }
            await gate.waitForPause()
            if close { #expect(store.closeDocument(discardRecovery: true)) }
            else { store.text += "changed" }
            await gate.release()
            await task.value
            #expect(store.text == (close ? original : original + "changed"))
            #expect(store.alert?.detail.contains("1 new image files") == true)
            #expect(store.alert?.detail.contains("Source text was not changed") == true)
            #expect(!store.undoManager.canUndo)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.documentDirectory.appendingPathComponent("assets").path).count == 1)
            _ = store.closeDocument(discardRecovery: true)
        }
    }

    @Test func changedSelectionAndTaskCancellationRefuseDelayedInsertion() async throws {
        for cancel in [false, true] {
            let fixture = try AttachmentFixture(text: "hello")
            defer { fixture.cleanup() }
            let store = DocumentStore()
            store.open(fixture.document)
            let view = store.editorSession.loadTextView(text: store.text)
            view.setSelectedRange(NSRange(location: 0, length: 0))
            let gate = AttachmentGate()
            store.attachmentWorker = { job in
                let result = await Task.detached { job.run() }.value
                await gate.pause(); return result
            }
            let task = Task { await store.insertImageAttachments([.file(fixture.source)], folder: "assets",
                insertionRange: NSRange(location: 0, length: 0), expectedText: "hello") }
            await gate.waitForPause()
            if cancel { task.cancel() } else { view.setSelectedRange(NSRange(location: 2, length: 0)) }
            await gate.release()
            #expect(await task.value == nil)
            #expect(store.text == "hello")
            #expect(store.alert?.detail.contains("completed copies remain") == true)
            _ = store.closeDocument(discardRecovery: true)
        }
    }

    @Test func movedBackingFileRefusesDelayedRelativeRewrite() async throws {
        let fixture = try AttachmentFixture(text: "![a](../outside/图%20image.png)\n")
        defer { fixture.cleanup() }
        let store = DocumentStore()
        store.open(fixture.document)
        let original = store.text
        let gate = AttachmentGate()
        store.attachmentWorker = { job in
            let result = await Task.detached { job.run() }.value
            await gate.pause(); return result
        }
        let task = Task { await store.collectLocalImages(folder: "assets") }
        await gate.waitForPause()
        let moved = fixture.root.appendingPathComponent("moved.md")
        try FileManager.default.moveItem(at: fixture.document, to: moved)
        await gate.release()
        await task.value
        #expect(store.text == original)
        #expect(store.fileURL == moved)
        #expect(store.alert?.detail.contains("Source text was not changed") == true)
        #expect(!store.undoManager.canUndo)
        _ = store.closeDocument(discardRecovery: true)
    }

    @Test func markedTextPreventsIOAndAdoption() async throws {
        let fixture = try AttachmentFixture(text: "hello")
        defer { fixture.cleanup() }
        let store = DocumentStore()
        store.open(fixture.document)
        let view = store.editorSession.loadTextView(text: store.text)
        view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        #expect(view.hasMarkedText())
        let marked = store.text
        await store.collectLocalImages(folder: "assets")
        #expect(await store.insertImageAttachments([.file(fixture.source)], folder: "assets") == nil)
        #expect((store.text as NSString).isEqual(to: marked))
        #expect(!FileManager.default.fileExists(atPath: fixture.documentDirectory.appendingPathComponent("assets").path))
        view.unmarkText()
        _ = store.closeDocument(discardRecovery: true)
    }

    @Test func copyPreferenceDefaultsAndPersistsExplicitLinkChoice() {
        let name = "md2-portable-settings-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.imageFileHandling == .copy)
        settings.imageFileHandling = .link
        #expect(AppSettings(defaults: defaults).imageFileHandling == .link)
    }
}
