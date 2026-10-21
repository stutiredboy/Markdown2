import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import MD2App
@testable import MD2Core

final class ReadingImprovementsGUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1", "Requires AppKit and WebKit")
    }

    @MainActor func testEditorSelectionZoomAndUndo() throws {
        let host = ReadingWindow("# 标题\n\n中文 **正文** [链接](https://example.com/path)")
        defer { host.close() }
        let editor = try XCTUnwrap(host.store.editorSession.textView)
        let coordinator = try XCTUnwrap(Mirror(reflecting: host.store.editorSession).children.first { $0.label == "coordinator" }?.value as? MarkdownEditorView.Coordinator)
        var selection: String?
        let onSelection = coordinator.onSelectionChange
        coordinator.onSelectionChange = { selection = $0; onSelection($0) }
        let text = editor.string
        let selected = (text as NSString).range(of: "中文 **正文** [链接](https://example.com/path)")
        editor.setSelectedRange(selected)
        host.spin(0.35)
        XCTAssertEqual(DocumentStats(markdown: try XCTUnwrap(selection)).words, 6)

        host.settings.typography.editorFont = .monospaced
        host.settings.typography.fontSize = 20
        host.settings.zoomIn()
        host.spin(0.4)
        XCTAssertEqual(editor.string, text)
        XCTAssertEqual(editor.selectedRange(), selected)
        XCTAssertFalse(host.store.undoManager.canUndo)
        let font = try XCTUnwrap(editor.textStorage?.attribute(.font, at: selected.location, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 22, accuracy: 0.01)
        let latinFont = try XCTUnwrap(editor.textStorage?.attribute(.font, at: (text as NSString).range(of: "https").location, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(latinFont.familyName, NSFont.monospacedSystemFont(ofSize: 22, weight: .regular).familyName)
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        coordinator.onSelectionChange = { selection = $0; onSelection($0) }
        coordinator.reportSelection(in: editor)
        host.spin(0.2)
        XCTAssertNil(selection)
        editor.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        host.spin(0.15)
        host.store.undoManager.undo()
        host.spin(0.15)
        XCTAssertEqual(editor.string, text)
    }

    @MainActor func testReadSelectionAndLiveTypography() throws {
        let host = ReadingWindow("# 标题\n\n中文 **正文** [链接](https://example.com/path) ![image](missing.png)", mode: .read)
        defer { host.close() }
        let webView = try host.preview()
        let coordinator = try XCTUnwrap(webView.navigationDelegate as? MarkdownPreviewView.Coordinator)
        var selection: String?
        let onSelection = coordinator.onSelectionChange
        coordinator.onSelectionChange = { selection = $0; onSelection($0) }
        _ = try evaluate("""
        (function () {
            var range = document.createRange(); range.selectNodeContents(document.querySelector('main > p'));
            var selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
        })();
        """, in: webView)
        host.spin(0.4)
        XCTAssertEqual(DocumentStats(plainText: RenderedPlainText.extract(from: try XCTUnwrap(selection))).words, 6)
        XCTAssertEqual(try evaluate("getComputedStyle(document.querySelector('main')).maxWidth", in: webView) as? String, "800px")
        host.settings.typography.readingWidth = .narrow
        host.settings.typography.readingFont = .serif
        host.settings.typography.fontSize = 20
        host.settings.zoomIn()
        host.spin(0.4)
        XCTAssertEqual(try evaluate("getComputedStyle(document.body).fontSize", in: webView) as? String, "22px")
        XCTAssertEqual(try evaluate("getComputedStyle(document.querySelector('main')).maxWidth", in: webView) as? String, "880px")
        XCTAssertTrue((try evaluate("getComputedStyle(document.body).fontFamily", in: webView) as? String)?.contains("serif") == true)
        _ = try evaluate("window.getSelection().removeAllRanges()", in: webView)
        host.spin(0.25)
        // SwiftUI refreshes callback closures when typography changes.
        coordinator.onSelectionChange = { selection = $0; onSelection($0) }
        _ = try evaluate("document.dispatchEvent(new Event('selectionchange'))", in: webView)
        host.spin(0.2)
        XCTAssertNil(selection)
        XCTAssertFalse(host.store.rendered.html.contains("md2-typography"))
    }

    @MainActor func testOutlinePersistsAfterJumpAndFollowsBothSurfaces() throws {
        let paragraph = String(repeating: "A long paragraph with enough text to wrap and make each section scroll. ", count: 50)
        let markdown = "# First\n\n\(paragraph)\n\n# Second\n\n\(paragraph)\n\n# Third\n\n\(paragraph)"
        let host = ReadingWindow(markdown, mode: .read)
        defer { host.close() }
        let webView = try host.preview()
        let headings = host.store.rendered.outline
        XCTAssertEqual(headings.count, 3)
        let list = try XCTUnwrap(host.find(NSTableView.self))
        // XCTest-hosted WebKit may throttle animation frames for its window.
        _ = try evaluate("window.requestAnimationFrame = function (callback) { return setTimeout(callback, 16); }; void 0;", in: webView)
        host.store.jump(to: headings[1])
        host.spin(1.5)
        XCTAssertNil(host.store.jumpHeadingID)
        let afterJump = try evaluate("JSON.stringify({anchor:window.__md2CaptureAnchor(), y:window.scrollY, height:window.innerHeight})", in: webView)
        XCTAssertEqual(list.selectedRow, 1, String(describing: afterJump))
        _ = try evaluate("window.scrollTo(0, document.getElementById('third').offsetTop + 80)", in: webView)
        host.spin(0.3)
        let afterScroll = try evaluate("JSON.stringify({anchor:window.__md2CaptureAnchor(), y:window.scrollY, height:window.innerHeight})", in: webView)
        XCTAssertEqual(list.selectedRow, 2, String(describing: afterScroll))
        host.store.requestMode(.write)
        host.spin(0.6)
        let editor = try XCTUnwrap(host.store.editorSession.textView)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        host.spin(0.3)
        XCTAssertEqual(try XCTUnwrap(host.find(NSTableView.self)).selectedRow, 0)
    }

    @MainActor func testOutlineClickKeepsAdjacentParentSelectedUntilPreviewScroll() throws {
        let paragraph = String(repeating: "Detailed section text that makes the preview scrollable. ", count: 80)
        let markdown: String
        if let fixturePath = ProcessInfo.processInfo.environment["MD2_OUTLINE_REPRO_FILE"] {
            markdown = try String(contentsOfFile: fixturePath, encoding: .utf8)
        } else {
            markdown = """
            # Introduction

            \(paragraph)

            ### 3.1　运维质量改进项目界定

            #### 3.1.1　利益相关方识别与客户需求调研

            \(paragraph)

            #### 3.1.2　核心质量指标、目标与安全约束

            \(paragraph)
            """
        }
        let host = ReadingWindow(markdown, mode: .read)
        defer { host.close() }
        let webView = try host.preview()
        let headings = host.store.rendered.outline
        let parent = try XCTUnwrap(headings.first { $0.title.contains("3.1　") })
        let child = try XCTUnwrap(headings.first { $0.title.contains("3.1.1　") })
        let list = try XCTUnwrap(host.find(NSTableView.self))
        let parentRow = try XCTUnwrap(headings.firstIndex(of: parent))
        let childRow = try XCTUnwrap(headings.firstIndex(of: child))
        _ = try evaluate("window.requestAnimationFrame = function (callback) { return setTimeout(callback, 16); }; void 0;", in: webView)
        // A prior preview click is not a scroll gesture. It must not make the
        // later programmatic outline jump look user initiated.
        _ = try evaluate("window.dispatchEvent(new MouseEvent('mousedown', {bubbles: true}));", in: webView)

        list.scrollRowToVisible(parentRow)
        host.spin(0.2)
        list.selectRowIndexes(IndexSet(integer: parentRow), byExtendingSelection: false)
        host.spin(1.5)
        XCTAssertEqual(list.selectedRow, parentRow, "A click should keep its selected heading until the reader scrolls (rows: \(list.numberOfRows), parent: \(parentRow))")

        if ProcessInfo.processInfo.environment["MD2_OUTLINE_REPRO_FILE"] == nil {
            _ = try evaluate("window.dispatchEvent(new WheelEvent('wheel', {deltaY: 100, bubbles: true})); window.scrollTo(0, document.getElementById('\(child.id)').offsetTop + 80);", in: webView)
            host.spin(0.3)
            let afterScroll = try evaluate("JSON.stringify({anchor:window.__md2CaptureAnchor(), y:window.scrollY, target:document.getElementById('\(child.id)').offsetTop})", in: webView)
            XCTAssertEqual(list.selectedRow, childRow, String(describing: afterScroll))
        }
    }

    @MainActor private func evaluate(_ script: String, in webView: WKWebView) throws -> Any? {
        let done = expectation(description: "JavaScript")
        var output: Any?
        var failure: Error?
        webView.evaluateJavaScript(script) { value, error in output = value; failure = error; done.fulfill() }
        wait(for: [done], timeout: 5)
        if let failure { throw failure }
        return output
    }
}

@MainActor private final class ReadingWindow: NSObject, NSWindowDelegate {
    let suite = "ReadingImprovementsGUITests-\(UUID())"
    let store = DocumentStore()
    let settings: AppSettings
    let window: NSWindow
    let hosting: NSHostingView<ContentView>

    init(_ text: String, mode: EditorMode = .write) {
        _ = NSApplication.shared
        settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.language = .english
        settings.newDocumentMode = mode
        store.text = text
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        hosting = NSHostingView(rootView: ContentView(document: store, settings: settings, onOpen: {}))
        super.init()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        spin(0.6)
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { store.undoManager }

    func find<T: NSView>(_ type: T.Type, in view: NSView? = nil) -> T? {
        let view = view ?? hosting
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }

    func preview() throws -> WKWebView {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let web = find(WKWebView.self), !web.isLoading, web.url != nil { spin(0.3); return web }
            spin(0.05)
        }
        return try XCTUnwrap(find(WKWebView.self))
    }

    func spin(_ duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.delegate = nil
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}
