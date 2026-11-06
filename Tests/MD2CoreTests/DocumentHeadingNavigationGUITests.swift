import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

/// Exercises the real ContentView's editor and preview consumers. The document
/// model tests alone cannot prove that a jump survives initial view mounting.
final class DocumentHeadingNavigationGUITests: XCTestCase, RenderedPageTesting {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 to run this document-heading GUI test.")
    }

    @MainActor func testNewlyOpenedLinkRevealsHeadingInEditor() throws {
        try withDocument(mode: .write, fragment: "target") { store, host in
            XCTAssertTrue(spin(15) {
                guard let editor = self.descendant(host, as: MarkdownSourceTextView.self) else { return false }
                return self.targetIsVisible(in: editor)
            }, "the new editor did not reveal the linked heading")
            let editor = try XCTUnwrap(descendant(host, as: MarkdownSourceTextView.self))
            XCTAssertGreaterThan(editor.visibleRect.minY, 500, "a top-of-document view is not a successful jump")
            XCTAssertFalse(store.isDirty)
        }
    }

    @MainActor func testExistingUnsavedDocumentRevealsHeadingWithoutReloading() throws {
        try withDocument(mode: .write, fragment: nil) { store, host in
            XCTAssertTrue(spin(10) { self.descendant(host, as: MarkdownSourceTextView.self)?.string == store.text })
            let editor = try XCTUnwrap(descendant(host, as: MarkdownSourceTextView.self))
            XCTAssertFalse(targetIsVisible(in: editor), "positive control: target starts off screen")
            store.text = "Unsaved prefix\n\n" + store.text
            store.requestHeadingNavigation("target")
            XCTAssertTrue(spin(15) { editor.string == store.text && self.targetIsVisible(in: editor) })
            XCTAssertTrue(store.text.hasPrefix("Unsaved prefix"))
            XCTAssertTrue(store.isDirty)
            // Repeating a link is an action even after the first request was consumed.
            editor.scroll(NSPoint.zero)
            editor.enclosingScrollView?.reflectScrolledClipView(editor.enclosingScrollView!.contentView)
            XCTAssertFalse(targetIsVisible(in: editor))
            store.requestHeadingNavigation("target")
            XCTAssertTrue(spin(10) { self.targetIsVisible(in: editor) })
        }
    }

    @MainActor func testNewlyOpenedLinkRevealsHeadingInPreview() throws {
        try withDocument(mode: .read, fragment: "target") { store, host in
            XCTAssertTrue(spin(15) { self.descendant(host, as: WKWebView.self) != nil })
            let preview = try XCTUnwrap(descendant(host, as: WKWebView.self))
            XCTAssertTrue(spin(20) { !preview.isLoading && (try? self.evaluate("document.readyState === 'complete' && !!document.getElementById('target')", in: preview)) as? Bool == true })
            XCTAssertTrue(spin(10) {
                (try? self.evaluate("""
                    (() => {
                      const h = document.getElementById('target');
                      if (!h) return false;
                      const y = h.getBoundingClientRect().top;
                      return window.scrollY > 500 && y >= -8 && y < window.innerHeight / 2;
                    })()
                    """, in: preview)) as? Bool == true
            }, "the new preview did not land at the linked heading")
            XCTAssertFalse(store.isDirty)
        }
    }

    @MainActor private func withDocument(
        mode: EditorMode, fragment: String?,
        body: (DocumentStore, NSView) throws -> Void
    ) throws {
        _ = NSApplication.shared
        let suite = "DocumentHeadingNavigationGUITests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.defaultMode = mode
        settings.newDocumentMode = mode
        settings.showsOutlineByDefault = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("target.md")
        let paragraphs = (0..<90).map { "Paragraph \($0): text before and after the target.\n" }.joined(separator: "\n")
        let markdown = "# Start\n\n" + paragraphs + "\n# Target\n\n" + paragraphs
        try markdown.write(to: file, atomically: true, encoding: .utf8)
        var target = URLComponents(url: file, resolvingAgainstBaseURL: false)!
        target.fragment = fragment
        let store = DocumentStore()
        store.open(try XCTUnwrap(target.url))
        defer { _ = store.closeDocument(discardRecovery: false) }
        let host = NSHostingView(rootView: ContentView(document: store, settings: settings, onOpen: {}))
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 980, height: 680),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        try body(store, host)
    }

    @MainActor private func targetIsVisible(in editor: MarkdownSourceTextView) -> Bool {
        let range = (editor.string as NSString).range(of: "# Target")
        guard range.location != NSNotFound,
              let manager = editor.layoutManager, let container = editor.textContainer else { return false }
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rectangle = manager.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
        return editor.visibleRect.intersects(rectangle)
    }

    @MainActor private func descendant<T: NSView>(_ root: NSView, as type: T.Type) -> T? {
        if let view = root as? T { return view }
        return root.subviews.lazy.compactMap { self.descendant($0, as: type) }.first
    }
}
