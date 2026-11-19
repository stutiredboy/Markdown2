import AppKit
import ApplicationServices
import Carbon.HIToolbox
import XCTest

@testable import MD2App

/// Runs the actual picker, folder window and document editor in an isolated
/// app. A missing or unresponsive Accessibility surface fails the enabled lane.
final class FolderWorkflowGUITests: XCTestCase {
    @MainActor
    func testFolderPickerTreeQuickOpenAndRefreshPreserveDocumentIdentity() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 to run the native folder workflow.")
        guard AXIsProcessTrusted() else { throw FolderTestError("Folder workflow requires Accessibility trust") }

        let fixture = try FolderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let app = try await FolderTestApplication.launch(fixture: fixture)
        defer { app.close() }

        let originalWindow = try app.documentWindow(fixture.guide)
        let editor = try app.waitFor("native Markdown editor in the existing document") {
            app.descendant(originalWindow) { app.attribute(kAXRoleAttribute, of: $0) as? String == kAXTextAreaRole }
        }
        XCTAssertEqual(app.value(editor), fixture.guideText)

        try app.key(kVK_ANSI_O, flags: [.maskCommand, .maskShift])
        let picker = try app.waitFor("Open Folder picker") {
            app.windows.first { app.title($0).hasPrefix("Open Folder") }
        }
        // Open Folder starts in the current document's parent. Accept that
        // actual picker location and verify it independently in the browser.
        let choose = try app.waitFor("enabled Open button in the folder picker") {
            app.descendant(picker) {
                app.title($0) == "Open" && (app.attribute(kAXEnabledAttribute, of: $0) as? Bool) == true
            }
        }
        XCTAssertEqual(AXUIElementPerformAction(choose, kAXPressAction as CFString), .success)

        let browser = try app.waitFor("folder browser for the explicitly chosen directory") {
            app.windows.first { app.identifier($0) == "folder-browser-window" }
        }
        let search = try app.element("folder-quick-open", in: browser)
        let list = try app.element("folder-file-list", in: browser)
        let path = try app.element("folder-root-path", in: browser)
        XCTAssertTrue(app.labels(path).contains { $0.hasSuffix("/\(fixture.directory.lastPathComponent)/Test Folder") })
        _ = try app.waitFor("Notes directory in the native file tree") { app.row("Notes", in: list) }
        let open = try app.element("folder-open-selection", in: browser)
        XCTAssertEqual(app.attribute(kAXRoleAttribute, of: list) as? String, kAXOutlineRole)
        XCTAssertNil(app.row("Details.md", in: list), "the nested file starts under a collapsed directory")
        XCTAssertNil(app.row("Escape.md", in: list))
        XCTAssertNil(app.row("Redirect", in: list))
        XCTAssertNil(app.row(".Hidden.md", in: list))

        try app.key(kVK_DownArrow)
        try app.key(kVK_Return)
        _ = try app.waitFor("the child revealed by opening the Notes row") { app.row("Details.md", in: list) }
        try app.key(kVK_DownArrow)
        try app.openSelection(using: open)
        let detailsWindow = try app.documentWindow(fixture.details, focused: true)
        try app.key(kVK_ANSI_P, flags: [.maskCommand, .maskShift])
        try app.search("Notes/Details.md", field: search, list: list, expecting: "Details.md")
        try app.openSelection(using: open)
        XCTAssertTrue(CFEqual(try app.documentWindow(fixture.details, focused: true), detailsWindow))

        XCTAssertEqual(AXUIElementPerformAction(originalWindow, kAXRaiseAction as CFString), .success)
        _ = try app.documentWindow(fixture.guide, focused: true)
        let draft = fixture.guideText + "\nUnsaved draft"
        try app.replaceEditorText(draft, in: editor)
        try app.key(kVK_ANSI_P, flags: [.maskCommand, .maskShift])
        _ = try app.waitFor("Quick Open gives keyboard focus to the search field") {
            app.focusedElement.flatMap { app.identifier($0) == "folder-quick-open" ? $0 : nil }
        }
        try app.search("Guide Space.md", field: search, list: list, expecting: "Guide Space.md")
        try app.openSelection(using: open)
        let reusedWindow = try app.documentWindow(fixture.guide, focused: true)
        XCTAssertTrue(CFEqual(reusedWindow, originalWindow), "quick open must focus the existing native window")
        XCTAssertEqual(app.windows.filter { app.isWindow($0, for: fixture.guide) }.count, 1)
        XCTAssertEqual(app.value(editor), draft)
        XCTAssertEqual(try String(contentsOf: fixture.guide, encoding: .utf8), fixture.guideText)
        try app.replaceEditorText(fixture.guideText, in: editor)

        try app.key(kVK_ANSI_P, flags: [.maskCommand, .maskShift])
        try app.search("Pending.md", field: search, list: list, expecting: "Pending.md")
        try FileManager.default.removeItem(at: fixture.pending)
        try FileManager.default.createSymbolicLink(at: fixture.pending, withDestinationURL: fixture.external)
        try app.openSelection(using: open)
        let status = try app.element("folder-status", in: browser)
        _ = try app.waitFor("an inline stale-file message after the selected file became a symlink") {
            app.labels(status).contains { $0.localizedCaseInsensitiveContains("changed on disk") } ? status : nil
        }
        XCTAssertFalse(app.windows.contains { app.isWindow($0, for: fixture.external) })

        let added = fixture.folder.appendingPathComponent("Added.md")
        try "# Added externally\n".write(to: added, atomically: true, encoding: .utf8)
        let refresh = try app.element("folder-refresh", in: browser)
        XCTAssertEqual(AXUIElementPerformAction(refresh, kAXPressAction as CFString), .success)
        try app.search("Added.md", field: search, list: list, expecting: "Added.md")
        try app.openSelection(using: open)
        let addedWindow = try app.documentWindow(added, focused: true)
        let addedEditor = try app.waitFor("native Markdown editor in the new document") {
            app.descendant(addedWindow) { app.attribute(kAXRoleAttribute, of: $0) as? String == kAXTextAreaRole }
        }
        let saved = "# Saved through the ordinary document editor"
        try app.replaceEditorText(saved, in: addedEditor)
        try app.key(kVK_ANSI_S, flags: .maskCommand)
        _ = try app.waitFor("ordinary Save writes the selected file") {
            (try? String(contentsOf: added, encoding: .utf8)) == saved ? addedEditor : nil
        }

        XCTAssertEqual(try String(contentsOf: fixture.guide, encoding: .utf8), fixture.guideText)
        XCTAssertEqual(try String(contentsOf: fixture.linked, encoding: .utf8), fixture.linkedText)
        XCTAssertEqual(try String(contentsOf: fixture.external, encoding: .utf8), fixture.externalText)

        let bulk = fixture.folder.appendingPathComponent("Large", isDirectory: true)
        try FileManager.default.createDirectory(at: bulk, withIntermediateDirectories: false)
        for number in 0..<2_005 {
            try Data().write(to: bulk.appendingPathComponent("Note \(number).md"))
        }
        let start = ContinuousClock.now
        try app.key(kVK_ANSI_P, flags: [.maskCommand, .maskShift])
        _ = try app.waitFor("returning to the large folder announces a partial list") {
            app.labels(status).contains { $0.contains("Partial list") } ? status : nil
        }
        print("Large folder refreshed to a partial list in \(start.duration(to: .now))")
    }
}

private struct FolderFixture {
    let directory: URL
    let folder: URL
    let guide: URL
    let details: URL
    let linked: URL
    let pending: URL
    let external: URL
    let guideText = "# Guide\n\n[Linked](Linked.md) and [outside](../Outside.md).\n"
    let linkedText = "# Linked\n\nKeep these exact bytes.\n"
    let externalText = "# Outside the selected folder\n"

    init() throws {
        let files = FileManager.default
        directory = files.temporaryDirectory.appendingPathComponent("MD2-Folder-\(UUID().uuidString)", isDirectory: true)
        folder = directory.appendingPathComponent("Test Folder", isDirectory: true)
        let notes = folder.appendingPathComponent("Notes", isDirectory: true)
        guide = folder.appendingPathComponent("Guide Space.md")
        details = notes.appendingPathComponent("Details.md")
        linked = folder.appendingPathComponent("Linked.md")
        pending = folder.appendingPathComponent("Pending.md")
        external = directory.appendingPathComponent("Outside.md")
        do {
            try files.createDirectory(at: notes, withIntermediateDirectories: true)
            try guideText.write(to: guide, atomically: true, encoding: .utf8)
            try "# Details\n".write(to: details, atomically: true, encoding: .utf8)
            try linkedText.write(to: linked, atomically: true, encoding: .utf8)
            try externalText.write(to: external, atomically: true, encoding: .utf8)
            try "# Pending\n".write(to: pending, atomically: true, encoding: .utf8)
            try "# Hidden\n".write(to: folder.appendingPathComponent(".Hidden.md"), atomically: true, encoding: .utf8)
            try files.createSymbolicLink(at: folder.appendingPathComponent("Escape.md"), withDestinationURL: external)
            try files.createSymbolicLink(at: folder.appendingPathComponent("Redirect"), withDestinationURL: directory)
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }
}

@MainActor
private struct FolderTestApplication {
    private let process: NSRunningApplication
    private let priorApplication: NSRunningApplication?
    private let bundleIdentifier: String
    private let accessibility: AXUIElement

    static func launch(fixture: FolderFixture) async throws -> Self {
        let priorApplication = NSWorkspace.shared.frontmostApplication
        let identifier = "dev.codex.md2.folder-test.\(UUID().uuidString.lowercased())"
        let appURL = fixture.directory.appendingPathComponent("Markdown2.app", isDirectory: true)
        let productURL = Bundle(for: FolderWorkflowGUITests.self).bundleURL.deletingLastPathComponent()
        try RuntimeAppBundleBuilder(bundleIdentifier: identifier)
            .build(bundleURL: appURL, executableURL: productURL.appendingPathComponent("Markdown2"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        defaults.setPersistentDomain([
            "MD2.DefaultMode": "write", "MD2.NewDocumentMode": "write",
            "MD2.Language": "english", "AppleLanguages": ["en"],
            "MD2.ShowsOutlineByDefault": false, "AppleWindowTabbingMode": "manual"
        ], forName: identifier)
        defaults.synchronize()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [fixture.guide.path]
        configuration.environment = ["MARKDOWN2_DISABLE_APP_BUNDLE_BOOTSTRAP": "1"]
        do {
            let process = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            let accessibility = AXUIElementCreateApplication(process.processIdentifier)
            AXUIElementSetMessagingTimeout(accessibility, 2)
            return Self(process: process, priorApplication: priorApplication,
                        bundleIdentifier: identifier, accessibility: accessibility)
        } catch {
            defaults.removePersistentDomain(forName: identifier)
            throw error
        }
    }

    func close() {
        let pid = process.processIdentifier
        if !process.isTerminated { process.forceTerminate() }
        let deadline = Date().addingTimeInterval(5)
        while pid > 0, kill(pid, 0) == 0, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        UserDefaults(suiteName: bundleIdentifier)?.removePersistentDomain(forName: bundleIdentifier)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: support.appendingPathComponent(bundleIdentifier, isDirectory: true))
        if let priorApplication, !priorApplication.isTerminated {
            priorApplication.activate()
            let deadline = Date().addingTimeInterval(5)
            while NSWorkspace.shared.frontmostApplication?.processIdentifier != priorApplication.processIdentifier,
                  Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
    }

    var focusedElement: AXUIElement? { elementAttribute(kAXFocusedUIElementAttribute, of: accessibility) }
    var windows: [AXUIElement] { attribute(kAXWindowsAttribute, of: accessibility) as? [AXUIElement] ?? [] }

    func documentWindow(_ url: URL, focused: Bool = false) throws -> AXUIElement {
        try waitFor("\(focused ? "focused " : "")document \(url.lastPathComponent)") {
            let candidates = focused ? [elementAttribute(kAXFocusedWindowAttribute, of: accessibility)].compactMap { $0 } : windows
            return candidates.first { isWindow($0, for: url) }
        }
    }

    func isWindow(_ element: AXUIElement, for url: URL) -> Bool {
        if let document = attribute(kAXDocumentAttribute, of: element) as? String, let actual = URL(string: document), actual.isFileURL {
            return actual.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath()
        }
        let name = url.lastPathComponent
        return title(element) == name || title(element) == name + " *"
    }

    func focus(_ element: AXUIElement) throws {
        try set(kAXFocusedAttribute, to: kCFBooleanTrue, on: element)
    }

    func replaceEditorText(_ replacement: String, in editor: AXUIElement) throws {
        try selectText(in: editor)
        try set(kAXSelectedTextAttribute, to: replacement as CFString, on: editor)
        _ = try waitFor("the editor has published the exact replacement") { value(editor) == replacement ? editor : nil }
    }

    private func selectText(in element: AXUIElement) throws {
        try focus(element)
        let previous = value(element) ?? ""
        guard !previous.isEmpty else { return }
        var range = CFRange(location: 0, length: previous.utf16.count)
        try set(kAXSelectedTextRangeAttribute, to: XCTUnwrap(AXValueCreate(.cfRange, &range)), on: element)
        _ = try waitFor("the input field has selected its current text") {
            (attribute(kAXSelectedTextAttribute, of: element) as? String) == previous ? element : nil
        }
    }

    private func set(_ attribute: String, to value: CFTypeRef, on element: AXUIElement) throws {
        let result = AXUIElementSetAttributeValue(element, attribute as CFString, value)
        guard result == .success else { throw FolderTestError("Setting \(attribute) failed: \(result.rawValue)") }
    }

    func openSelection(using button: AXUIElement) throws {
        _ = try waitFor("Open becomes enabled for the selected file") {
            (attribute(kAXEnabledAttribute, of: button) as? Bool) == true ? button : nil
        }
        try key(kVK_Return)
    }

    func search(_ query: String, field: AXUIElement, list: AXUIElement, expecting name: String) throws {
        try selectText(in: field)
        try type(query)
        _ = try waitFor("the path query \(query) shows \(name)") {
            value(field) == query ? row(name, in: list) : nil
        }
    }

    func key(_ key: Int, flags: CGEventFlags = []) throws { try postKey(UInt16(key), flags: flags) }

    func type(_ text: String) throws {
        for character in text { try postKey(0, flags: [], text: String(character)) }
    }

    private func postKey(_ key: CGKeyCode, flags: CGEventFlags, text: String? = nil) throws {
        for down in [true, false] {
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down))
            event.flags = flags
            if let text {
                let units = Array(text.utf16)
                units.withUnsafeBufferPointer { buffer in
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                }
            }
            event.postToPid(process.processIdentifier)
        }
    }

    func waitFor(_ description: String, _ lookup: () -> AXUIElement?) throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline, !process.isTerminated {
            if let element = lookup() { return element }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw FolderTestError("Timed out waiting for \(description). Windows: \(windows.map(title)); focused: \(focusedElement.map(labels) ?? [])")
    }

    func element(_ id: String, in parent: AXUIElement) throws -> AXUIElement {
        try waitFor(id) { descendant(parent) { identifier($0) == id } }
    }

    func row(_ label: String, in list: AXUIElement) -> AXUIElement? {
        descendant(list) { labels($0).contains(label) }
    }

    func descendant(_ root: AXUIElement, matching predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        var pending = [root]
        var index = 0
        while index < pending.count, index < 400 {
            let element = pending[index]
            if predicate(element) { return element }
            pending.append(contentsOf: children(element))
            index += 1
        }
        return nil
    }

    func children(_ element: AXUIElement) -> [AXUIElement] { attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? [] }
    func title(_ element: AXUIElement) -> String { attribute(kAXTitleAttribute, of: element) as? String ?? "" }
    func value(_ element: AXUIElement) -> String? { attribute(kAXValueAttribute, of: element) as? String }
    func identifier(_ element: AXUIElement) -> String? { attribute(kAXIdentifierAttribute, of: element) as? String }
    func labels(_ element: AXUIElement) -> [String] {
        [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attribute($0, of: element) as? String }
    }

    func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

private struct FolderTestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
