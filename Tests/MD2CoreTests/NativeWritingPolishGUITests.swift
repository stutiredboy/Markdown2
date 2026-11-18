import AppKit
import PDFKit
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

final class NativeWritingPolishGUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 to run native writing GUI tests.")
    }

    @MainActor
    func testChangingTypewriterScrollingKeepsNativeFindEditingAtNarrowWidths() throws {
        for language in [AppLanguage.english, .zhHans] {
            let harness = InteractionTestWindow()
            defer { harness.close() }
            harness.settings.language = language
            harness.store.text = Self.markdown
            harness.host(ContentView(document: harness.store, settings: harness.settings, onOpen: {}),
                         width: DocumentLayoutMetrics.minimumWindowWidth(mode: .split, showsOutline: false))

            for mode in [EditorMode.write, .split, .read] {
                try switchMode(to: mode, in: harness)
                if mode == .split {
                    let split = try XCTUnwrap(harness.descendants(NSSplitView.self).first)
                    split.setPosition(DocumentLayoutMetrics.splitEditorMinWidth, ofDividerAt: 0)
                    harness.spin()
                }
                if let editor = harness.store.editorSession.textView, mode != .read {
                    XCTAssertTrue(harness.window.makeFirstResponder(editor))
                }
                harness.store.requestFind(.showReplace)
                let pane: SplitPane = mode == .read ? .preview : .editor
                harness.spin(until: { NativeFindFocus.pane(in: harness.window) == pane })
                XCTAssertEqual(NativeFindFocus.pane(in: harness.window), pane)
                try harness.enterQuery("needle")
                let query = try XCTUnwrap(harness.queryField)
                let fields: [(NSTextField, String)]
                if mode == .read {
                    let web = try XCTUnwrap(harness.descendants(WKWebView.self).first)
                    try harness.waitForPage(
                        "document.querySelectorAll('mark.md2-find').length === 2",
                        in: web,
                        context: "Read Find results have settled before changing the setting"
                    )
                    fields = [(query, "needle")]
                } else {
                    let replacement = try XCTUnwrap(harness.descendants(NSTextField.self).first {
                        $0.placeholderString == harness.settings.text(.replaceWith)
                    })
                    XCTAssertTrue(harness.window.makeFirstResponder(replacement))
                    try XCTUnwrap(replacement.currentEditor()).insertText("修订")
                    fields = [(query, "needle"), (replacement, "修订")]
                }
                for (field, value) in fields {
                    XCTAssertTrue(harness.window.makeFirstResponder(field))
                    let fieldEditor = try XCTUnwrap(field.currentEditor())
                    let selected = NSRange(location: 0, length: 1)
                    fieldEditor.selectedRange = selected
                    harness.spin()
                    let source = harness.store.editorSession.textView
                    let sourceSelection = source?.selectedRange()
                    let sourceViewport = source?.enclosingScrollView?.contentView.bounds
                    let preview = harness.descendants(WKWebView.self).first
                    let previewOffset = try preview.flatMap { try harness.js("scrollY", $0) as? Double }
                    for enabled in [true, false] {
                        harness.settings.usesTypewriterScrolling = enabled
                        harness.spin()
                        let context = "\(language.rawValue) / \(mode) / \(value) / \(enabled)"
                        XCTAssertTrue(harness.window.firstResponder === fieldEditor, context)
                        XCTAssertTrue(field.currentEditor() === fieldEditor, context)
                        XCTAssertEqual(NativeFindFocus.pane(in: harness.window), pane, context)
                        XCTAssertEqual(fieldEditor.string, value, context)
                        XCTAssertEqual(fieldEditor.selectedRange, selected, context)
                        XCTAssertEqual(source?.selectedRange(), sourceSelection, context)
                        XCTAssertEqual(source?.enclosingScrollView?.contentView.bounds, sourceViewport, context)
                        XCTAssertEqual(try preview.flatMap { try harness.js("scrollY", $0) as? Double }, previewOffset, context)
                    }
                }
                try harness.press(.closeFind)
            }
        }
    }

    @MainActor
    func testModesKeepWorkingSelectionAndDoNotRevealHiddenFindUntilExplicitNavigation() throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        harness.settings.usesTypewriterScrolling = true
        harness.store.text = Self.markdown
        harness.host(ContentView(document: harness.store, settings: harness.settings, onOpen: {}))
        let editor = try XCTUnwrap(harness.store.editorSession.textView)
        let nativeSource = editor.string as NSString
        let workingSelection = nativeSource.range(of: "🧭 修订位置")
        let firstMatch = nativeSource.range(of: "needle")
        let lastMatch = nativeSource.range(of: "needle", options: .backwards)
        XCTAssertNotEqual(workingSelection.location, NSNotFound)
        XCTAssertNotEqual(firstMatch, lastMatch)

        harness.store.requestFind(.show)
        harness.spin(until: { harness.queryField?.currentEditor() != nil })
        try harness.enterQuery("needle")
        harness.spin(until: { editor.selectedRange().location == NSMaxRange(firstMatch) })
        XCTAssertEqual(editor.selectedRange().location, NSMaxRange(firstMatch))
        try harness.press(.closeFind)

        XCTAssertTrue(harness.window.makeFirstResponder(editor))
        editor.setSelectedRange(workingSelection)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        let workingRect = harness.targetRect(workingSelection, in: editor)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: workingRect.minY - 20))
        scroll.reflectScrolledClipView(scroll.contentView)
        harness.spin()
        XCTAssertTrue(editor.visibleRect.intersects(harness.targetRect(workingSelection, in: editor)))
        XCTAssertGreaterThan(editor.visibleRect.minY, 500)
        let originalOffset = editor.visibleRect.minY
        try switchMode(to: .read, in: harness)
        try waitForHiddenPreviewQuery(in: harness)
        try switchMode(to: .write, in: harness)
        XCTAssertEqual(editor.visibleRect.minY, originalOffset, accuracy: 1,
                       "a passive same-width round trip must restore the wrapped editor viewport")
        XCTAssertEqual(editor.selectedRange(), workingSelection)

        for mode in [EditorMode.split, .read, .write] {
            try switchMode(to: mode, in: harness)
            XCTAssertEqual(editor.selectedRange(), workingSelection, "\(mode) displaced the working selection")
            if mode != .read {
                XCTAssertTrue(harness.store.editorSession.textView === editor)
                XCTAssertTrue(editor.visibleRect.intersects(harness.targetRect(workingSelection, in: editor)),
                              "\(mode) lost the working line")
            }
            XCTAssertNil(harness.queryField)
        }

        try switchMode(to: .read, in: harness)
        try waitForHiddenPreviewQuery(in: harness)
        let web = try XCTUnwrap(harness.descendants(WKWebView.self).first)
        XCTAssertEqual(try harness.js("""
            (() => {
                const target = Array.from(document.querySelectorAll('main > p')).find(
                    paragraph => paragraph.textContent === 'Ordinary draft paragraph 72.');
                if (!target) return false;
                const before = scrollY;
                const band = Math.min(64, innerHeight * 0.25);
                scrollTo(0, target.getBoundingClientRect().top + scrollY - band + 4);
                return scrollY > before + 300;
            })()
            """, web) as? Bool, true)
        // Request the switch straight away, before a debounced scroll report
        // can substitute for the fresh position of the live page.
        try switchMode(to: .write, in: harness)
        let destination = nativeSource.range(of: "Ordinary draft paragraph 72.")
        XCTAssertTrue(editor.visibleRect.intersects(harness.targetRect(destination, in: editor)),
                      "Read navigation must take precedence over the passive source bookmark")
        XCTAssertEqual(editor.selectedRange(), workingSelection,
                       "Read navigation changes the viewport while retaining the source selection")
        XCTAssertTrue(harness.window.firstResponder === editor)
        XCTAssertEqual(harness.store.text, Self.markdown)
        XCTAssertFalse(harness.store.undoManager.canUndo)

        harness.store.requestFind(.next)
        harness.spin(until: { [NSMaxRange(firstMatch), NSMaxRange(lastMatch)].contains(editor.selectedRange().location) })
        XCTAssertTrue([NSMaxRange(firstMatch), NSMaxRange(lastMatch)].contains(editor.selectedRange().location),
                      "explicit Find Next must still use the retained query")
    }

    @MainActor
    func testTypewriterPreferencePreservesSourceBytesAndHTMLAndPDFExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Writing.md")
        let html = directory.appendingPathComponent("Writing.html")
        let pdf = directory.appendingPathComponent("Writing.pdf")
        let bytes = Data("# Writing / 写作\r\n\r\nA **working draft** with bilingual prose. 中文例句。\r\n".utf8)
        try bytes.write(to: source)
        let store = DocumentStore(pdfDestinationPicker: { _ in pdf }, htmlDestinationPicker: { _ in html })
        store.open(source)
        defer { _ = store.closeDocument(discardRecovery: false) }
        let harness = InteractionTestWindow(store: store)
        defer { harness.close() }
        harness.host(ContentView(document: store, settings: harness.settings, onOpen: {}))
        let editor = try XCTUnwrap(store.editorSession.textView)
        let original = try export(store, html: html, pdf: pdf, in: harness)
        try FileManager.default.removeItem(at: pdf)
        try FileManager.default.removeItem(at: html)

        harness.settings.usesTypewriterScrolling = true
        harness.spin()
        let enabled = try export(store, html: html, pdf: pdf, in: harness)
        XCTAssertEqual(enabled.html, original.html)
        XCTAssertEqual(enabled.pdfText, original.pdfText)
        XCTAssertEqual(enabled.pdfPages, original.pdfPages)
        XCTAssertFalse(store.isDirty)
        XCTAssertFalse(store.undoManager.canUndo)
        XCTAssertEqual(Data(editor.string.utf8), bytes)
        XCTAssertTrue(store.save())
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    @MainActor
    private func switchMode(to mode: EditorMode, in harness: InteractionTestWindow) throws {
        harness.store.requestMode(mode)
        func mounted() -> Bool {
            let source = harness.store.editorSession.textView?.window === harness.window
            let preview = harness.descendants(WKWebView.self).first
            return source == (mode != .read) && (preview != nil) == (mode != .write)
        }
        harness.spin(until: mounted)
        XCTAssertTrue(mounted(), "surfaces for \(mode) did not mount")
        if mode != .write {
            let web = try XCTUnwrap(harness.descendants(WKWebView.self).first)
            try harness.waitForPage("document.querySelector('main')?.textContent.includes('修订位置')",
                                    in: web, context: "\(mode) preview loaded")
        }
        harness.spin()
    }

    @MainActor
    private func waitForHiddenPreviewQuery(in harness: InteractionTestWindow) throws {
        let web = try XCTUnwrap(harness.descendants(WKWebView.self).first)
        try harness.waitForPage(
            """
            (() => {
                const working = Array.from(document.querySelectorAll('main > p')).find(
                    paragraph => paragraph.textContent.includes('修订位置'));
                if (!working) return false;
                const rect = working.getBoundingClientRect();
                return document.querySelectorAll('mark.md2-find').length === 2
                    && scrollY > 500 && rect.bottom > 0 && rect.top < innerHeight;
            })()
            """,
            in: web, context: "a hidden Find query must build its matches without displacing the preview anchor"
        )
    }

    @MainActor
    private func export(_ store: DocumentStore, html: URL, pdf: URL, in harness: InteractionTestWindow) throws
        -> (html: Data, pdfText: String, pdfPages: Int) {
        let finished = expectation(description: "Started HTML and PDF export")
        Task {
            await store.exportHTML()
            await store.exportPDF()
            finished.fulfill()
        }
        wait(for: [finished], timeout: 15)
        harness.spin(until: { FileManager.default.fileExists(atPath: pdf.path) || store.alert != nil }, timeout: 35)
        XCTAssertNil(store.alert)
        let pageData = try Data(contentsOf: html)
        XCTAssertTrue(String(decoding: pageData, as: UTF8.self).contains("<strong>working draft</strong>"))
        let pdfDocument = try XCTUnwrap(PDFDocument(url: pdf))
        let pdfText = try XCTUnwrap(pdfDocument.string)
        XCTAssertTrue(pdfText.contains("working draft"))
        return (pageData, pdfText, pdfDocument.pageCount)
    }

    private static let markdown = (1...90).map { line in
        switch line {
        case 1, 90: "A needle on line \(line)."
        case 46: String(repeating: "The notes record the reasoning behind each change. ", count: 10)
            + "Keep the bilingual phrase 🧭 修订位置 selected while reviewing this section."
        default: "Ordinary draft paragraph \(line)."
        }
    }.joined(separator: "\n\n")
}
