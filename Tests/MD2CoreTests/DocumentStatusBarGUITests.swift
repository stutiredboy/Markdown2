import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import MD2App
@testable import MD2Core

final class DocumentStatusBarGUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1", "Requires AppKit and WebKit")
    }

    @MainActor func testPrimaryValuesInfoAndConversionAt720Points() throws {
        if try runInIsolatedNativeProcess(#function, childVariable: "MD2_STATUS_NATIVE_CASE") { return }
        defer { print("MD2_NATIVE_COMPLETED=\(#function)") }
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        defer { _ = app.setActivationPolicy(previousPolicy) }
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("StatusBar-\(UUID())")
        defer { try? files.removeItem(at: root) }
        let folder = root.appendingPathComponent(String(repeating: "Reading notes ", count: 10))
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("Review 📝.md")
        let markdown = "# Review\r\n\r\nFirst word\r\nSecond line\r\n"
        let format = MarkdownFileFormat(encoding: .utf8, hasBOM: true, lineEnding: .crlf)
        try XCTUnwrap(format.encode(markdown)).write(to: source)

        // Exercise the real cancellable converter and destination transaction.
        // The substitute executable pauses after staging so the button can be
        // pressed deterministically, including on hosts without Pandoc.
        let executable = root.appendingPathComponent("fixture-pandoc")
        try """
            #!/bin/sh
            if [ "$1" = "--version" ]; then echo 'pandoc 3.14'; exit; fi
            /usr/bin/touch started
            exec /bin/sleep 30
            """.write(to: executable, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let destination = folder.appendingPathComponent("Review.docx")
        let original = Data("Original file".utf8)
        try original.write(to: destination)
        let store = DocumentStore(documentConverterFactory: { PandocConverter(locatePandoc: { executable }) },
                                  pandocAvailabilityProvider: { true }, conversionDestinationPicker: { _, _ in destination })
        store.open(source)
        let host = InteractionTestWindow(store: store)
        defer { store.cancelConversion(); host.close() }
        host.settings.language = .english
        host.settings.defaultMode = .read
        host.host(ContentView(document: store, settings: host.settings, onOpen: {}), width: 720)
        let web = try XCTUnwrap(host.descendants(WKWebView.self).first)
        try host.waitForPage("document.querySelector('h1')?.textContent === 'Review'", in: web, context: "initial read")
        XCTAssertEqual(host.window.frame.width, 720, accuracy: 1)
        let readWords = try visible("document-word-count", text: "5 words", in: host)
        let readTime = try visible("document-reading-time", text: "1 min read", in: host)
        XCTAssertLessThanOrEqual(readWords.maxX, readTime.minX)
        try host.capture("status-720-read")

        let info = try find("document-info", in: host)
        XCTAssertEqual(AXUIElementPerformAction(info, kAXPressAction as CFString), .success)
        let path = try find("document-info-path", in: host)
        XCTAssertTrue(strings(of: path).contains(store.fileURL!.path), "Full path: \(strings(of: path))")
        XCTAssertTrue(strings(of: try find("document-info-encoding", in: host)).contains("UTF-8 BOM"))
        XCTAssertTrue(strings(of: try find("document-info-endings", in: host)).contains("CRLF"))
        host.window.makeKeyAndOrderFront(nil)
        if let popover = NSApp.windows.first(where: { $0 !== host.window && $0.isVisible && $0.className.contains("Popover") }) {
            popover.performClose(nil)
        }

        store.requestMode(.write)
        host.spin(until: { store.editorSession.textView?.window === host.window && store.editorJumpAnchor == nil })
        XCTAssertNil(store.editorJumpAnchor)
        let editor = try XCTUnwrap(store.editorSession.textView)
        host.window.makeFirstResponder(editor)
        let string = editor.string as NSString
        let start = NSMaxRange(string.range(of: "First "))
        let end = NSMaxRange(string.range(of: "Second"))
        editor.setSelectedRange(NSRange(location: start, length: end - start))
        let counted = DocumentStats(markdown: string.substring(with: editor.selectedRange()))
        let editPosition = try visible("document-caret-position", text: "Ln 3, Col 7 – Ln 4, Col 7", in: host)
        let editSelection = try visible("document-selection-count",
                                       text: "Selection: 2 / 5 words · \(counted.characters) chars", in: host)
        XCTAssertLessThanOrEqual(editPosition.maxX, editSelection.minX)
        try host.capture("status-720-write-selection")

        store.exportDOCX()
        let started = folder.appendingPathComponent("started")
        host.spin(until: { files.fileExists(atPath: started.path) })
        XCTAssertTrue(files.fileExists(atPath: started.path))
        let progress = try visible("document-export-progress", text: "Exporting DOCX…", in: host)
        let cancel = try find("cancel-export-conversion", in: host)
        let cancelFrame = try frame(cancel)
        XCTAssertTrue(try frame(documentWindow()).contains(cancelFrame))
        XCTAssertGreaterThan(cancelFrame.width, 20)
        XCTAssertLessThanOrEqual(progress.maxX, cancelFrame.minX)
        XCTAssertEqual(AXUIElementPerformAction(cancel, kAXPressAction as CFString), .success)
        host.spin(until: { store.convertingFormat == nil })
        XCTAssertNil(store.convertingFormat)
        XCTAssertNil(store.alert)
        XCTAssertEqual(try Data(contentsOf: destination), original)
        _ = try visible("document-caret-position", text: "Ln 3, Col 7 – Ln 4, Col 7", in: host)
    }

    @MainActor private func visible(_ id: String, text: String, in host: InteractionTestWindow) throws -> NSRect {
        let element = try find(id, text: text, in: host)
        let frame = try frame(element)
        XCTAssertTrue(try self.frame(documentWindow()).contains(frame), "\(text) outside window: \(frame)")
        let width = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width
        XCTAssertGreaterThanOrEqual(frame.width + 2, width, "\(text) truncated")
        return frame
    }

    private func attribute(_ key: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, key as CFString, &value)
        return value
    }

    private func strings(of element: AXUIElement) -> [String] {
        [kAXValueAttribute, kAXDescriptionAttribute, kAXTitleAttribute].compactMap { attribute($0, of: element) as? String }
    }

    private func documentWindow() throws -> AXUIElement {
        let app = AXUIElementCreateApplication(getpid())
        let windows = attribute(kAXWindowsAttribute, of: app) as? [AXUIElement] ?? []
        return try XCTUnwrap(windows.first { strings(of: $0).contains("Review 📝.md") })
    }

    private func frame(_ element: AXUIElement) throws -> CGRect {
        let pointValue = try XCTUnwrap(attribute(kAXPositionAttribute, of: element))
        let sizeValue = try XCTUnwrap(attribute(kAXSizeAttribute, of: element))
        var point = CGPoint.zero
        var size = CGSize.zero
        XCTAssertTrue(AXValueGetValue(pointValue as! AXValue, .cgPoint, &point))
        XCTAssertTrue(AXValueGetValue(sizeValue as! AXValue, .cgSize, &size))
        return CGRect(origin: point, size: size)
    }

    @MainActor private func find(_ id: String, text: String? = nil, in host: InteractionTestWindow) throws -> AXUIElement {
        let app = AXUIElementCreateApplication(getpid())
        var observed: [String] = []
        func search(_ element: AXUIElement) -> AXUIElement? {
            if attribute(kAXIdentifierAttribute, of: element) as? String == id {
                observed = strings(of: element)
                if text.map(observed.contains) ?? true { return element }
            }
            for child in attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? [] {
                if let result = search(child) { return result }
            }
            return nil
        }
        var found: AXUIElement?
        host.spin(until: {
            found = (attribute(kAXWindowsAttribute, of: app) as? [AXUIElement] ?? []).compactMap(search).first
            return found != nil
        })
        return try XCTUnwrap(found, "\(id) \(text ?? ""), observed \(observed), selection \(String(describing: host.store.editorSession.textView?.selectedRange()))")
    }
}
