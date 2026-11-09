import AppKit
import SwiftUI
import XCTest
@testable import MD2App

/// Focused real native paste coverage. This suite owns windows and the general
/// pasteboard, so run only with the coordinator's exclusive GUI lease.
final class PortableAttachmentGUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 to run portable attachment GUI tests.")
    }

    @MainActor
    func testNativeFilePasteUsesCopyDefaultAndExplicitLinkWithUndo() throws {
        let saved = preservePasteboard()
        defer { restorePasteboard(saved) }
        for handling in [ImageFileHandling.copy, .link] {
            let harness = try AttachmentWindow(handling: handling)
            defer { harness.close() }
            NSPasteboard.general.clearContents()
            XCTAssertTrue(NSPasteboard.general.writeObjects([harness.imageURL as NSURL]))
            let editor = try XCTUnwrap(harness.store.editorSession.textView as? MarkdownSourceTextView)
            XCTAssertTrue(harness.window.makeFirstResponder(editor))
            editor.setSelectedRange(NSRange(location: 4, length: 0))
            editor.paste(nil)
            try harness.waitUntil { harness.store.text != "text" && !harness.store.isWorkingOnAttachments }
            let inserted = harness.store.text
            XCTAssertTrue(inserted.hasPrefix("text!["))
            if handling == .copy {
                XCTAssertTrue(inserted.contains("(assets/"))
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: harness.documentDirectory.appendingPathComponent("assets").path).count, 1)
            } else {
                XCTAssertTrue(inserted.contains(ImageAttachmentManager.markdownLinkPath(harness.imageURL.path)))
                XCTAssertFalse(FileManager.default.fileExists(atPath: harness.documentDirectory.appendingPathComponent("assets").path))
            }
            harness.store.undoManager.undo()
            try harness.waitUntil { harness.store.text == "text" }
            harness.store.undoManager.redo()
            try harness.waitUntil { harness.store.text == inserted }
        }
    }

    @MainActor
    func testNativeBitmapPasteAndCollectionUseRetainedEditorUndo() throws {
        let saved = preservePasteboard()
        defer { restorePasteboard(saved) }
        let harness = try AttachmentWindow(handling: .link)
        defer { harness.close() }
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setData(try Data(contentsOf: harness.imageURL), forType: .png))
        let editor = try XCTUnwrap(harness.store.editorSession.textView as? MarkdownSourceTextView)
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        editor.paste(nil)
        try harness.waitUntil { harness.store.text.contains("(assets/") && !harness.store.isWorkingOnAttachments }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: harness.documentDirectory.appendingPathComponent("assets").path).count, 1)
        harness.store.undoManager.undo()
        try harness.waitUntil { harness.store.text == "text" }
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        let original = "text\n" + ImageAttachmentManager.directImageReference(forFile: harness.imageURL)
        editor.insertText("\n" + ImageAttachmentManager.directImageReference(forFile: harness.imageURL), replacementRange: NSRange(location: 4, length: 0))
        try harness.waitUntil { harness.store.text == original }
        Task { await harness.store.collectLocalImages(folder: "assets") }
        try harness.waitUntil { harness.store.alert != nil && !harness.store.isWorkingOnAttachments }
        XCTAssertTrue(harness.store.text.contains("(assets/"))
        harness.store.alert = nil
        harness.store.undoManager.undo()
        try harness.waitUntil { harness.store.text == original }
    }

    @MainActor
    private func preservePasteboard() -> [[(NSPasteboard.PasteboardType, Data)]] {
        NSPasteboard.general.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
    }

    @MainActor
    private func restorePasteboard(_ saved: [[(NSPasteboard.PasteboardType, Data)]]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(saved.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        })
    }
}

@MainActor
private final class AttachmentWindow: NSObject, NSWindowDelegate {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("md2-attach-gui-\(UUID())")
    let suite = "md2-attach-gui-\(UUID())"
    let store = DocumentStore()
    let window: NSWindow
    var documentDirectory: URL { root.appendingPathComponent("document") }
    var imageURL: URL { root.appendingPathComponent("source.png") }

    init(handling: ImageFileHandling) throws {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 650),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: imageURL)
        let document = documentDirectory.appendingPathComponent("notes.md")
        try "text".write(to: document, atomically: true, encoding: .utf8)
        store.open(document)
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.defaultMode = .write
        settings.showsOutlineByDefault = false
        settings.imageFileHandling = handling
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.delegate = self
        let hosting = NSHostingView(rootView: ContentView(document: store, settings: settings, onOpen: {}))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 650)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        try waitUntil {
            guard let editor = self.store.editorSession.textView else { return false }
            return editor.window === self.window && editor.bounds.width > 0 && editor.string == "text"
        }
        XCTAssertTrue(window.makeFirstResponder(store.editorSession.textView))
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { store.undoManager }

    func waitUntil(_ predicate: () -> Bool, timeout: TimeInterval = 5) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            autoreleasepool { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }
        guard predicate() else { throw NSError(domain: "AttachmentWindow.readiness", code: 1) }
    }

    func close() {
        _ = store.closeDocument(discardRecovery: true)
        window.orderOut(nil)
        window.contentView = nil
        window.delegate = nil
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
