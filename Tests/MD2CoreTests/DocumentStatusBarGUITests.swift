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

    @MainActor func testClickingShortSplitPanesChangesStatusWithoutScrolling() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("StatusFocus-\(UUID())")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let source = root.appendingPathComponent("Short.md")
        try "# Short\n\nTwo words\n".write(to: source, atomically: true, encoding: .utf8)
        let app = try await FolderTestApplication.launch(in: root, arguments: [source.path], presentationMode: .split)
        defer { app.close() }
        let window = try app.documentWindow(source, focused: true)
        let editor = try app.editor(in: window)
        let web = try app.waitFor("rendered short preview") {
            app.descendant(window) { app.attribute(kAXRoleAttribute, of: $0) as? String == "AXWebArea"
                && app.descendant($0, matching: { app.labels($0).contains("Two words") }) != nil }
        }
        let paragraph = try XCTUnwrap(app.descendant(web) {
            app.attribute(kAXRoleAttribute, of: $0) as? String == kAXStaticTextRole && app.labels($0).contains("Two words")
        })

        // WebKit's rendered accessibility tree belongs to its content process.
        // A WindowServer hit may return the native pane hosting AXWebArea.
        func splitChild(containing element: AXUIElement) -> AXUIElement? {
            var child = element
            for _ in 0..<20 {
                guard let parent = app.elementAttribute(kAXParentAttribute, of: child) else { return nil }
                if app.attribute(kAXRoleAttribute, of: parent) as? String == kAXSplitGroupRole { return child }
                child = parent
            }
            return nil
        }
        func click(in surface: AXUIElement, stage: String, bounds: () throws -> CGRect) throws {
            try app.activateForInput()
            _ = try app.documentWindow(source, focused: true)
            let pane = try XCTUnwrap(splitChild(containing: surface), stage)
            var point = CGPoint.zero
            _ = try app.waitFor("a visible click target for \(stage)") {
                guard let rect = try? bounds(), !rect.isEmpty else { return nil }
                point = CGPoint(x: rect.midX, y: rect.midY)
                guard (try? app.frame(of: surface))?.contains(point) == true else { return nil }
                var hit: AXUIElement?
                guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
                      let hit, let hitPane = splitChild(containing: hit), CFEqual(hitPane, pane) else { return nil }
                return surface
            }
            for kind: CGEventType in [.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: kind,
                                                  mouseCursorPosition: point, mouseButton: .left))
                event.setIntegerValueField(.mouseEventClickState, value: 1)
                event.post(tap: .cghidEventTap)
            }
        }

        // The full NSTextView frame may extend outside its clip view. Use the
        // actual glyph bounds and wait for the mouse-delivered caret, so the
        // initial click has reached AppKit before setting the selection by AX.
        func clickSource(_ stage: String) throws {
            var target = CFRange(location: 13, length: 5) // "words" in "# Short\n\nTwo words\n".
            let range = try XCTUnwrap(AXValueCreate(.cfRange, &target))
            try click(in: editor, stage: stage) {
                var value: CFTypeRef?
                guard AXUIElementCopyParameterizedAttributeValue(editor, kAXBoundsForRangeParameterizedAttribute as CFString,
                      range, &value) == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return .zero }
                var rect = CGRect.zero
                return AXValueGetValue(value as! AXValue, .cgRect, &rect) ? rect : .zero
            }
            _ = try app.waitFor("a focused source caret inside 'words' after \(stage)") {
                guard let focused = app.focusedElement, CFEqual(focused, editor),
                      let value = app.attribute(kAXSelectedTextRangeAttribute, of: editor),
                      CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
                var caret = CFRange()
                guard AXValueGetValue(value as! AXValue, .cfRange, &caret), caret.length == 0,
                      (target.location...target.location + target.length).contains(caret.location) else { return nil }
                return editor
            }
        }

        try clickSource("initial source selection setup")
        var selection = CFRange(location: 9, length: 3)
        let value = try XCTUnwrap(AXValueCreate(.cfRange, &selection))
        XCTAssertEqual(AXUIElementSetAttributeValue(editor, kAXSelectedTextRangeAttribute as CFString, value), .success)
        _ = try app.waitFor("the native source selection before the preview click") {
            app.attribute(kAXSelectedTextAttribute, of: editor) as? String == "Two" ? editor : nil
        }
        _ = try app.element("document-selection-count", in: window)
        try click(in: web, stage: "preview paragraph") { try app.frame(of: paragraph) }
        _ = try app.element("document-reading-time", in: window)
        XCTAssertNil(app.descendant(window) { app.identifier($0) == "document-caret-position" })
        XCTAssertEqual(app.attribute(kAXSelectedTextAttribute, of: editor) as? String, "Two")

        // Inspecting the document is a third focus target. The retained source
        // selection must not reclaim the status or pull focus from its popover.
        func infoPath() -> AXUIElement? {
            app.windows.compactMap { app.descendant($0) { app.identifier($0) == "document-info-path" } }.first
        }
        try app.press(app.element("document-info", in: window))
        _ = try app.waitFor("visible document information") { infoPath() }
        _ = try app.element("document-reading-time", in: window)
        XCTAssertFalse(app.focusedElement.map { CFEqual($0, editor) } ?? false)
        // A click outside dismisses a transient popover. Wait for dismissal
        // before sending the separate click that must position the source caret.
        try click(in: web, stage: "dismiss Document Info") { try app.frame(of: paragraph) }
        _ = try app.waitFor("Document Info to dismiss before returning to source") { infoPath() == nil ? window : nil }
        try clickSource("the return from the preview")
        _ = try app.element("document-caret-position", in: window)
        XCTAssertNil(app.descendant(window) { app.identifier($0) == "document-reading-time" })
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
