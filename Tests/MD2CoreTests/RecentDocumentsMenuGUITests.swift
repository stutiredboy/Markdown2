import AppKit
import ApplicationServices
import Carbon
import XCTest

@testable import MD2App
@testable import MD2Core

/// Guards File ▸ Open Recent against going stale within a session.
///
/// The command tree is re-evaluated only when a setting changes, so the submenu
/// stays live only because `RecentDocumentsMenu` observes the model itself; pass
/// the entries in from the tree and it silently goes stale, which throws
/// nothing. Plain `swift test` skips this suite and CI's `gui-tests` job runs
/// it; run it locally with
/// `MD2_RUN_GUI_TESTS=1 swift test --filter RecentDocumentsMenuGUITests`.
///
/// Like `SettingsWindowPresentationGUITests` it launches a real app bundle under
/// its own bundle identifier, so it never reads or writes the developer's
/// recents. Three things about the evidence:
///
/// - Every case ends by opening the File menu and reading it. SwiftUI reconciles
///   a menu from its command tree on open, which drops anything the tree does not
///   contain, so a read of the closed menu alone could pass on an item the user
///   would not see.
/// - Waiting in between reads the closed menu. An open menu needs the app to be
///   frontmost, which someone using the machine can take away mid-run.
/// - Accessibility still answers while the screen is locked, where no menu is
///   drawn and windows report the wrong role. These cases prove the menu's
///   contents after that reconcile, not its pixels, and the missing-file and
///   language cases need an unlocked session.
final class RecentDocumentsMenuGUITests: XCTestCase {
    /// Cross-package regression: real menu dispatch, document-owned history,
    /// and saved bytes. Goldens are handwritten from the TSV below; neither
    /// converter nor table transformer computes an expected value.
    func testStructuredPasteTableColumnsKeepCRLFAndIndependentUndo() throws {
        let board = NSPasteboard.general
        let saved = board.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        defer {
            board.clearContents()
            board.writeObjects(saved.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            })
        }

        let prefix = "BEFORE_SENTINEL 文😀\r\n"
        let suffix = "\r\nAFTER_SENTINEL e\u{301}" // Deliberately no final newline.
        let original = prefix + "PASTE_HERE" + suffix
        let tsv = "Name\tNote\n中文😀\tunchanged"
        let pasted = prefix + "\r\n"
            + "| Name | Note |\r\n| --- | --- |\r\n| 中文😀 | unchanged |"
            + "\r\n" + suffix
        let widened = prefix + "\r\n"
            + "| Name |  | Note |\r\n| --- | --- | --- |\r\n| 中文😀 |  | unchanged |"
            + "\r\n" + suffix
        let document = try makeDocument("notes/StructuredIntegrationCRLF.md")
        try Data(original.utf8).write(to: document)
        let pid = try launch(recents: [], language: "english", appleLanguages: ["en"])
        try waitForEntries([], pid: pid)
        try open(document)
        try waitForEntries([document], pid: pid)

        var commandWindow: AXUIElement?
        var commandSource: AXUIElement?
        func role(_ element: AXUIElement) -> String {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
            return value as? String ?? "?"
        }
        func diagnose(_ stage: String, menu: AXUIElement? = nil) {
            var focused: CFTypeRef?
            AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &focused)
            let owner = Self.element(focused)
            let observedSource = commandSource ?? Self.windows(pid: pid)
                .filter { Self.title(of: $0).contains(document.deletingPathExtension().lastPathComponent) }
                .compactMap { Self.firstElement(ofRole: kAXTextAreaRole as String, in: $0) }.first
            var details: [String: Any] = ["stage": stage,
                "appActive": NSRunningApplication(processIdentifier: pid)?.isActive == true,
                "focusedRole": owner.map(role) ?? "?",
                "focusedTitle": owner.map(Self.title) ?? "?",
                "sourceOwnsFocus": observedSource.map { source in owner.map { CFEqual(source, $0) } == true } ?? false]
            if let source = observedSource {
                var rawText: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(source, kAXValueAttribute as CFString, &rawText)
                details["sourceValueStatus"] = status.rawValue
                if let text = rawText as? String { details["sourceUTF16"] = Array(text.utf16) }
                var raw: CFTypeRef?
                AXUIElementCopyAttributeValue(source, kAXSelectedTextRangeAttribute as CFString, &raw)
                if let raw, CFGetTypeID(raw) == AXValueGetTypeID() {
                    var range = CFRange()
                    if AXValueGetValue(raw as! AXValue, .cfRange, &range) { details["selection"] = [range.location, range.length] }
                }
            }
            if let menu {
                var actions: CFArray?
                AXUIElementCopyActionNames(menu, &actions)
                details["menuRole"] = role(menu)
                details["menuActions"] = actions as? [String] ?? []
                details["menuChildCount"] = Self.children(of: menu).count
                var visible: CFTypeRef?
                details["menuVisibleStatus"] = AXUIElementCopyAttributeValue(menu, "AXVisible" as CFString, &visible).rawValue
                details["menuVisible"] = (visible as? NSNumber)?.boolValue
            }
            if let bytes = try? Data(contentsOf: document), let text = String(data: bytes, encoding: .utf8) {
                details["diskUTF16"] = Array(text.utf16)
            }
            if let data = try? JSONSerialization.data(withJSONObject: details, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print("StructuredIntegration " + text) }
        }
        // Open each ancestor, then fetch its current item. This also refreshes
        // native Undo/Redo targets; do not reuse a closed Edit menu's old item.
        func press(_ barTitle: String, _ path: [String]) throws {
            NSRunningApplication(processIdentifier: pid)?.activate()
            if let commandWindow {
                XCTAssertEqual(AXUIElementPerformAction(commandWindow, kAXRaiseAction as CFString), .success)
            }
            diagnose("before " + path.joined(separator: " > "))
            // SwiftUI may replace AX containers when tracking a submenu starts.
            // Every query walks the live app tree; never reuse an item/menu
            // obtained before an AXPress to query the resulting menu state.
            func currentBarItem() -> AXUIElement? {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                    kAXMenuBarAttribute as CFString, &value) == .success,
                    let bar = Self.element(value) else { return nil }
                return Self.children(of: bar).first { Self.title(of: $0) == barTitle }
            }
            func namedItem(_ title: String, in menu: AXUIElement) -> AXUIElement? {
                let items = Self.children(of: menu)
                return items.first { Self.title(of: $0) == title }
                    ?? items.first { Self.title(of: $0).hasPrefix(title + " ") }
            }
            func currentMenu(_ ancestors: [String]) -> AXUIElement? {
                guard let bar = currentBarItem(),
                      var menu = Self.children(of: bar).first(where: { role($0) == (kAXMenuRole as String) }) else { return nil }
                for title in ancestors {
                    guard let item = namedItem(title, in: menu),
                          let submenu = Self.children(of: item).first(where: { role($0) == (kAXMenuRole as String) }) else { return nil }
                    menu = submenu
                }
                return menu
            }
            func waitForMenu(_ ancestors: [String]) throws {
                let deadline = Date().addingTimeInterval(5)
                while currentMenu(ancestors) == nil, Date() < deadline { usleep(50_000) }
                _ = try XCTUnwrap(currentMenu(ancestors), "fresh submenu: \(barTitle) > \(ancestors.joined(separator: " > "))")
            }
            var dispatchedLeaf = false
            defer {
                // Successful selection dismisses itself. Cleanup only failed
                // navigation, resolving the current actual menu again first.
                if !dispatchedLeaf, let menu = currentMenu([]) {
                    let result = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
                    print("StructuredIntegration failure cleanup result=\(result.rawValue)")
                }
                diagnose("after " + path.joined(separator: " > "), menu: currentMenu([]))
            }
            do {
                let entry = try XCTUnwrap(currentBarItem(), "menu bar: " + barTitle)
                guard AXUIElementPerformAction(entry, kAXPressAction as CFString) == .success else {
                    throw GuardFailure("cannot open " + barTitle)
                }
            }
            try waitForMenu([])
            diagnose("opened bar " + barTitle, menu: currentMenu([]))
            for (index, title) in path.enumerated() {
                let ancestors = Array(path.prefix(index))
                func currentItem() -> AXUIElement? {
                    guard let menu = currentMenu(ancestors) else { return nil }
                    return namedItem(title, in: menu)
                }
                let deadline = Date().addingTimeInterval(5)
                while currentItem().map(Self.isEnabled) != true, Date() < deadline { usleep(50_000) }
                diagnose("press " + title, menu: currentMenu(ancestors))
                do {
                    let target = try XCTUnwrap(currentItem(), "\(barTitle) > \(title)")
                    XCTAssertTrue(Self.isEnabled(target), title)
                    guard Self.isEnabled(target) else { throw GuardFailure("disabled command: " + title) }
                    guard AXUIElementPerformAction(target, kAXPressAction as CFString) == .success else {
                        throw GuardFailure("cannot press command: " + title)
                    }
                }
                if index == path.count - 1 { dispatchedLeaf = true }
                else { try waitForMenu(Array(path.prefix(index + 1))) }
                diagnose("after leaf-or-submenu press " + title, menu: currentMenu(ancestors))
            }
        }
        try press("Mode", ["Edit"])
        let window = try waitForWindow(pid: pid) {
            Self.title(of: $0).contains(document.deletingPathExtension().lastPathComponent)
                && Self.firstElement(ofRole: kAXTextAreaRole as String, in: $0) != nil
        }
        NSRunningApplication(processIdentifier: pid)?.activate()
        XCTAssertEqual(AXUIElementPerformAction(window, kAXRaiseAction as CFString), .success)
        let source = try XCTUnwrap(Self.firstElement(ofRole: kAXTextAreaRole as String, in: window))
        commandWindow = window
        commandSource = source
        func sourceText() throws -> String {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(source, kAXValueAttribute as CFString, &value) == .success,
                  let text = value as? String else { throw GuardFailure("source AX value unavailable") }
            return text
        }
        func selectedRange() throws -> CFRange {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(source, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXValueGetTypeID() else {
                throw GuardFailure("source AX selection unavailable")
            }
            var range = CFRange()
            guard AXValueGetValue(value as! AXValue, .cfRange, &range) else {
                throw GuardFailure("source AX selection is not a range")
            }
            return range
        }
        func select(_ marker: String) throws {
            XCTAssertEqual(AXUIElementSetAttributeValue(source, kAXFocusedAttribute as CFString, kCFBooleanTrue), .success)
            let found = (try sourceText() as NSString).range(of: marker)
            guard found.location != NSNotFound else { throw GuardFailure("missing source marker: \(marker)") }
            var range = CFRange(location: found.location, length: found.length)
            let value = try XCTUnwrap(AXValueCreate(.cfRange, &range))
            XCTAssertEqual(AXUIElementSetAttributeValue(source, kAXSelectedTextRangeAttribute as CFString, value), .success)
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                let actual = try selectedRange()
                if actual.location == range.location && actual.length == range.length { return }
                usleep(50_000)
            }
            throw GuardFailure("source selection did not converge")
        }
        func waitSource(_ expected: String, stage: String) throws {
            let deadline = Date().addingTimeInterval(5)
            while !(try sourceText()).utf16.elementsEqual(expected.utf16), Date() < deadline { usleep(50_000) }
            let actual = try sourceText()
            diagnose("source check " + stage)
            XCTAssertEqual(Array(actual.utf16), Array(expected.utf16), stage)
            guard actual.utf16.elementsEqual(expected.utf16) else { throw GuardFailure("source mismatch at \(stage)") }
            XCTAssertTrue(actual.hasPrefix(prefix) && actual.hasSuffix(suffix), "sentinels: \(stage)")
        }
        try waitSource(original, stage: "original CRLF source")
        board.clearContents()
        XCTAssertTrue(board.setString(tsv, forType: .string))
        try select("PASTE_HERE")
        try press("Edit", ["Paste as Table"])
        try waitSource(pasted, stage: "P: table paste")
        try select("中文😀")
        try press("Format", ["Table Operations", "Insert Column Right"])
        try waitSource(widened, stage: "T1: insert column")
        // Delete the cell chosen by insertion, without replacing its selection.
        let bodyStart = (widened as NSString).range(of: "| 中文😀 |  | unchanged |").location
        let emptyStart = bodyStart + "| 中文😀 |".utf16.count
        let selection = try selectedRange()
        XCTAssertGreaterThanOrEqual(selection.location, emptyStart)
        XCTAssertLessThanOrEqual(selection.location + selection.length, emptyStart + 2)
        guard selection.location >= emptyStart, selection.location + selection.length <= emptyStart + 2 else {
            throw GuardFailure("insertion did not select the new body cell")
        }
        try press("Format", ["Table Operations", "Delete Column"])
        try waitSource(pasted, stage: "T2: delete inserted column")
        for (label, expected) in [("undo T2", widened), ("undo T1", pasted), ("undo P", original)] {
            try press("Edit", ["Undo"])
            try waitSource(expected, stage: label)
        }
        for (label, expected) in [("redo P", pasted), ("redo T1", widened), ("redo T2", pasted)] {
            try press("Edit", ["Redo"])
            try waitSource(expected, stage: label)
        }
        try press("File", ["Save"])
        let expectedBytes = Data(pasted.utf8)
        let deadline = Date().addingTimeInterval(5)
        while (try? Data(contentsOf: document)) != expectedBytes, Date() < deadline { usleep(50_000) }
        XCTAssertEqual(try Data(contentsOf: document), expectedBytes,
            "saved UTF-8 bytes must retain CRLF, Unicode, both sentinels and no final newline")
        try waitSource(pasted, stage: "source after save")
    }

    private static let guardBundleIdentifier = "dev.codex.md2.recent-documents-guard"
    private static let recentsKey = "MD2.RecentDocuments"

    private var temporaryRoot: URL!
    private var appURL: URL!
    private var launchedApps: [NSRunningApplication] = []

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this File menu GUI test."
        )
        try XCTSkipUnless(
            AXIsProcessTrusted(),
            "This suite reads another process's File menu, which needs Accessibility trust for the "
                + "test runner. Grant it to the process running `swift test` (System Settings ▸ "
                + "Privacy & Security ▸ Accessibility, add your terminal), then run with "
                + "MD2_RUN_GUI_TESTS=1. This suite does not silently pass without trust."
        )

        Self.removeGuardPreferences()
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentDocumentsMenuGUITests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

        appURL = temporaryRoot.appendingPathComponent("Markdown2.app", isDirectory: true)
        try RuntimeAppBundleBuilder(bundleIdentifier: Self.guardBundleIdentifier)
            .build(bundleURL: appURL, executableURL: try Self.appExecutableURL())
    }

    override func tearDownWithError() throws {
        for app in launchedApps where Self.isProcessAlive(app) {
            app.forceTerminate()
        }
        let deadline = Date().addingTimeInterval(5)
        for app in launchedApps {
            while Self.isProcessAlive(app), Date() < deadline { usleep(100_000) }
            XCTAssertFalse(Self.isProcessAlive(app), "private test app PID \(app.processIdentifier) survived teardown")
        }
        launchedApps = []

        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        Self.removeGuardPreferences()
    }

    func testPinyinCompositionCommitsWithSpaceAndReturn() throws {
        let pinyinID = "com.apple.inputmethod.SCIM.ITABC"
        let query: [String: Any] = [
            kTISPropertyInputSourceID as String: pinyinID,
            kTISPropertyInputSourceIsEnabled as String: true,
            kTISPropertyInputSourceIsSelectCapable as String: true
        ]
        // Carbon can return nil when there is no matching enabled input source.
        guard let sources = TISCreateInputSourceList(query as CFDictionary, false)?.takeRetainedValue(),
              let inputSource = (sources as? [TISInputSource])?.first else {
            throw XCTSkip("Enable Simplified Chinese Pinyin to run the real input-method regression.")
        }
        guard CGPreflightPostEventAccess() else {
            throw GuardFailure("Quartz keyboard events must be allowed for the real input-method test")
        }
        let originalSource = try XCTUnwrap(TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
                                         "the previous input source is required for restoration")
        defer { XCTAssertEqual(TISSelectInputSource(originalSource), noErr, "restore the user's input source") }

        func wait(_ label: @autoclosure () -> String, until condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                if condition() { return }
                usleep(30_000)
            } while Date() < deadline
            throw GuardFailure(label())
        }

        let initial = "- "
        let document = try makeDocument("notes/PinyinList.md")
        try Data(initial.utf8).write(to: document)
        // Start the app with Pinyin already selected so its first text input
        // context inherits the input source before its window takes focus.
        guard TISSelectInputSource(inputSource) == noErr else {
            throw GuardFailure("could not select Simplified Chinese Pinyin before launching the fixture")
        }
        let pid = try launch(recents: [], language: "english", appleLanguages: ["en"])
        try open(document)
        let window = try waitForWindow(pid: pid) {
            Self.title(of: $0) == document.lastPathComponent
                && Self.firstElement(ofRole: kAXTextAreaRole as String, in: $0) != nil
        }
        let editor = try XCTUnwrap(Self.firstElement(ofRole: kAXTextAreaRole as String, in: window))
        let app = try XCTUnwrap(NSRunningApplication(processIdentifier: pid))
        app.activate()
        XCTAssertEqual(AXUIElementPerformAction(window, kAXRaiseAction as CFString), .success)
        XCTAssertEqual(AXUIElementSetAttributeValue(editor, kAXFocusedAttribute as CFString, kCFBooleanTrue), .success)
        let appElement = AXUIElementCreateApplication(pid)
        try wait("the Pinyin fixture must own keyboard focus") {
            var focused: CFTypeRef?
            return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                && AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success
                && Self.element(focused).map { CFEqual($0, editor) } == true
        }
        var end = CFRange(location: initial.utf16.count, length: 0)
        let caret = try XCTUnwrap(AXValueCreate(.cfRange, &end))
        XCTAssertEqual(AXUIElementSetAttributeValue(editor, kAXSelectedTextRangeAttribute as CFString, caret), .success)

        guard TISSelectInputSource(inputSource) == noErr else {
            throw GuardFailure("could not select Simplified Chinese Pinyin")
        }
        try wait("the system must select Simplified Chinese Pinyin") {
            guard let selected = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return false }
            return TISGetInputSourceProperty(selected, kTISPropertyInputSourceID)
                .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } == pinyinID
        }
        // The app receives the input-source change after Text Input Sources
        // returns. Give the WindowServer time to attach the new input context.
        usleep(750_000)

        func editorText() -> String? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(editor, kAXValueAttribute as CFString, &value) == .success
                ? value as? String : nil
        }
        let eventSource = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        func press(_ key: Int, flags: CGEventFlags = []) throws {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                throw GuardFailure("keyboard focus left the isolated Pinyin fixture")
            }
            for down in [true, false] {
                let event = try XCTUnwrap(CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(key), keyDown: down))
                event.flags = flags
                // Route through WindowServer so the active input method receives the key.
                event.post(tap: .cghidEventTap)
            }
            usleep(70_000)
        }

        try wait("the editor must contain the original list marker") { editorText() == initial }
        for key in [kVK_ANSI_W, kVK_ANSI_U, kVK_ANSI_B, kVK_ANSI_I] { try press(key) }
        try wait("Pinyin did not show a provisional buffer: \(String(describing: editorText()))") {
            guard let text = editorText() else { return false }
            return text != initial
        }
        let title = document.lastPathComponent
        XCTAssertEqual(Self.title(of: window), title, "marked text must leave the document clean")
        XCTAssertEqual(try Data(contentsOf: document), Data(initial.utf8))
        try press(kVK_Return)
        try wait("the first Return must commit wubi without continuing the list: \(String(describing: editorText()))") {
            editorText() == "- wubi" && Self.title(of: window) == title + " *"
        }
        try press(kVK_Return)
        let continuedList = "- wubi\n- "
        try wait("only the second Return may continue the list") { editorText() == continuedList }

        try press(kVK_ANSI_S, flags: .maskCommand)
        try wait("save the continued list before testing a Chinese candidate") {
            Self.title(of: window) == title && (try? Data(contentsOf: document)) == Data(continuedList.utf8)
        }
        for key in [kVK_ANSI_N, kVK_ANSI_I, kVK_ANSI_H, kVK_ANSI_A, kVK_ANSI_O] { try press(key) }
        try wait("Pinyin did not compose nihao") {
            guard let text = editorText() else { return false }
            return text.hasPrefix(continuedList) && text != continuedList
        }
        XCTAssertEqual(Self.title(of: window), title, "the candidate must still be provisional")
        try press(kVK_Space)
        try wait("Space must commit a Chinese candidate: \(String(describing: editorText()))") {
            guard let text = editorText(), text.hasPrefix(continuedList) else { return false }
            let candidate = text.dropFirst(continuedList.count)
            return !candidate.isEmpty && candidate.unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains($0.value) }
                && Self.title(of: window) == title + " *"
        }
    }

    func testLocalHistoryRestoresSelectedRevisionIntoAnIndependentDocumentTab() throws {
        func wait<Value>(_ label: String, _ read: () -> Value?) throws -> Value {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                if let value = read() { return value }
                usleep(50_000)
            } while Date() < deadline
            throw GuardFailure("missing \(label)")
        }
        func attribute(_ name: String, of element: AXUIElement) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value as? String
        }
        func descendant(of element: AXUIElement, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
            if matches(element) { return element }
            for child in Self.children(of: element) {
                if let found = descendant(of: child, where: matches) { return found }
            }
            return nil
        }

        let attachment = "![Shared](assets/shared.png)"
        let historical = "# 历史版本\r\n\(attachment)\r\n历史正文 😀"
        let latest = "# New version\r\n\(attachment)\r\nEdited text 😀"
        let bom = Data([0xEF, 0xBB, 0xBF])
        let historicalBytes = bom + Data(historical.utf8)
        let latestBytes = bom + Data(latest.utf8)
        let document = try makeDocument("notes/LocalHistory.md")
        try historicalBytes.write(to: document)
        let image = document.deletingLastPathComponent().appendingPathComponent("assets/shared.png")
        let imageBytes = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVwAAAABJRU5ErkJggg=="))
        try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        try imageBytes.write(to: image)

        let board = NSPasteboard.general
        let savedClipboard = board.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        defer {
            board.clearContents()
            board.writeObjects(savedClipboard.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            })
        }

        let pid = try launch(recents: [], language: "english", appleLanguages: ["en"])
        try open(document)
        let originalWindow = try waitForWindow(pid: pid) {
            Self.title(of: $0) == document.lastPathComponent
                && Self.firstElement(ofRole: kAXTextAreaRole as String, in: $0) != nil
        }
        let source = try XCTUnwrap(Self.firstElement(ofRole: kAXTextAreaRole as String, in: originalWindow))
        func expectText(_ text: String, in editor: AXUIElement) throws {
            _ = try wait("exact editor text") {
                attribute(kAXValueAttribute, of: editor).flatMap { $0.utf16.elementsEqual(text.utf16) ? $0 : nil }
            }
        }
        func pressMenu(_ menuTitle: String, _ title: String) throws {
            let app = AXUIElementCreateApplication(pid)
            func menuBarItem() -> AXUIElement? {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &value) == .success,
                      let bar = Self.element(value) else { return nil }
                return Self.children(of: bar).first { Self.title(of: $0) == menuTitle }
            }
            func menu() -> AXUIElement? { menuBarItem().flatMap { Self.children(of: $0).first } }
            let entry = try wait("\(menuTitle) menu", menuBarItem)
            XCTAssertEqual(AXUIElementPerformAction(entry, kAXPressAction as CFString), .success)
            var selected = false
            defer {
                if !selected, let menu = menu() { AXUIElementPerformAction(menu, kAXCancelAction as CFString) }
            }
            let item = try wait("enabled \(menuTitle) > \(title)") {
                menu().flatMap { menu in
                    Self.children(of: menu).first {
                        let label = Self.title(of: $0)
                        return Self.isEnabled($0) && (label == title || label.hasPrefix(title + " "))
                    }
                }
            }
            let outcome = AXUIElementPerformAction(item, kAXPressAction as CFString)
            XCTAssertEqual(outcome, .success, title)
            selected = outcome == .success
        }
        func findHistoryElement(_ id: String) -> AXUIElement? {
            for window in Self.windows(pid: pid) {
                if let match = descendant(of: window, where: { attribute(kAXIdentifierAttribute, of: $0) == id }) {
                    return match
                }
            }
            return nil
        }
        func historyElement(_ id: String) throws -> AXUIElement { try wait(id) { findHistoryElement(id) } }

        try expectText(historical, in: source)
        board.clearContents()
        XCTAssertTrue(board.setString(latest, forType: .string))
        NSRunningApplication(processIdentifier: pid)?.activate()
        XCTAssertEqual(AXUIElementPerformAction(originalWindow, kAXRaiseAction as CFString), .success)
        XCTAssertEqual(AXUIElementSetAttributeValue(source, kAXFocusedAttribute as CFString, kCFBooleanTrue), .success)
        var entireSource = CFRange(location: 0, length: historical.utf16.count)
        let selection = try XCTUnwrap(AXValueCreate(.cfRange, &entireSource))
        XCTAssertEqual(AXUIElementSetAttributeValue(source, kAXSelectedTextRangeAttribute as CFString, selection), .success)
        try pressMenu("Edit", "Paste as Plain Text")
        try expectText(latest, in: source)
        try pressMenu("File", "Save")
        _ = try wait("latest bytes on disk") { (try? Data(contentsOf: document)) == latestBytes ? true : nil }

        try pressMenu("File", "Browse Local History…")
        func expectExcerpt(_ marker: String) throws {
            _ = try wait("history excerpt containing \(marker)") {
                guard let excerpt = findHistoryElement("historyRevisionExcerpt") else { return nil as AXUIElement? }
                return descendant(of: excerpt) { row in
                    [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].contains {
                        attribute($0, of: row)?.contains(marker) == true
                    }
                }
            }
        }
        let newest = try historyElement("historyRevision-0")
        XCTAssertEqual(AXUIElementPerformAction(newest, kAXPressAction as CFString), .success)
        try expectExcerpt("Edited text")
        let previous = try historyElement("historyRevision-1")
        XCTAssertFalse(CFEqual(newest, previous))
        XCTAssertEqual(AXUIElementPerformAction(previous, kAXPressAction as CFString), .success)
        try expectExcerpt("历史正文 😀")
        let restore = try historyElement("historyRestoreAsCopy")
        XCTAssertEqual(AXUIElementPerformAction(restore, kAXPressAction as CFString), .success)
        let filenameField = try historyElement("historyCopyFilename")
        let filename = try XCTUnwrap(attribute(kAXValueAttribute, of: filenameField))
        XCTAssertFalse(filename.isEmpty)
        XCTAssertNotEqual(filename, document.lastPathComponent)
        let restored = document.deletingLastPathComponent().appendingPathComponent(filename)
        let confirm = try historyElement("historyRestoreAndOpen")
        XCTAssertEqual(AXUIElementPerformAction(confirm, kAXPressAction as CFString), .success)

        let copyWindow = try waitForWindow(pid: pid) {
            Self.title(of: $0) == filename && Self.firstElement(ofRole: kAXTextAreaRole as String, in: $0) != nil
        }
        XCTAssertFalse(CFEqual(originalWindow, copyWindow))
        let copyEditor = try XCTUnwrap(Self.firstElement(ofRole: kAXTextAreaRole as String, in: copyWindow))
        try expectText(historical, in: copyEditor)
        XCTAssertEqual(try Data(contentsOf: restored), historicalBytes)
        XCTAssertEqual(try Data(contentsOf: document), latestBytes)
        XCTAssertEqual(try Data(contentsOf: image), imageBytes)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: restored.deletingLastPathComponent().path)),
                       Set([document.lastPathComponent, filename, "assets"]))

        func selectTab(_ name: String, from current: AXUIElement, to target: AXUIElement) throws {
            let tab = try wait("the native tab for \(name)") {
                guard let group = Self.firstElement(ofRole: kAXTabGroupRole, in: current) else { return nil as AXUIElement? }
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(group, kAXTabsAttribute as CFString, &value) == .success,
                      let tabs = value as? [AXUIElement] else { return nil }
                return tabs.first { Self.title(of: $0) == name }
            }
            XCTAssertEqual(AXUIElementPerformAction(tab, kAXPressAction as CFString), .success)
            let app = AXUIElementCreateApplication(pid)
            _ = try wait("the \(name) tab to own window focus") {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
                      let focused = Self.element(value), CFEqual(target, focused) else { return nil as AXUIElement? }
                return focused
            }
        }
        try selectTab(document.lastPathComponent, from: copyWindow, to: originalWindow)
        try expectText(latest, in: source)
        XCTAssertEqual(AXUIElementSetAttributeValue(source, kAXFocusedAttribute as CFString, kCFBooleanTrue), .success)
        try pressMenu("Edit", "Undo")
        try expectText(historical, in: source)
        try pressMenu("Edit", "Redo")
        try expectText(latest, in: source)
        try selectTab(filename, from: originalWindow, to: copyWindow)
        try expectText(historical, in: copyEditor)
    }

    // MARK: - Editor accessibility

    func testEnglishSourceAndPopulatedFindFieldsHaveAccessibleNames() throws {
        try assertEditorAccessibleNames(language: "english", appleLanguage: "en",
                                       sourceLabel: "Markdown Source", findLabel: "Find", replacementLabel: "Replace With")
    }

    func testChineseSourceAndPopulatedFindFieldsHaveAccessibleNames() throws {
        try assertEditorAccessibleNames(language: "zhHans", appleLanguage: "zh-Hans",
                                       sourceLabel: "Markdown 源码", findLabel: "查找", replacementLabel: "替换为")
    }

    private func assertEditorAccessibleNames(
        language: String, appleLanguage: String, sourceLabel: String, findLabel: String, replacementLabel: String
    ) throws {
        let document = try makeDocument("notes/AccessibilityLabels.md")
        let original = "needle 中文 needle\n"
        try Data(original.utf8).write(to: document)
        let pid = try launch(recents: [], language: language, appleLanguages: [appleLanguage])
        try open(document)

        func string(_ attribute: String, in element: AXUIElement) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
            return value as? String
        }
        func isDocument(_ window: AXUIElement) -> Bool {
            Self.title(of: window) == document.lastPathComponent
        }
        func textFields(in element: AXUIElement) -> [AXUIElement] {
            if string(kAXRoleAttribute, in: element) == kAXTextFieldRole { return [element] }
            return Self.children(of: element).flatMap { textFields(in: $0) }
        }

        let sourceWindow = try waitForWindow(pid: pid) {
            isDocument($0) && Self.firstElement(ofRole: kAXTextAreaRole, in: $0) != nil
        }
        let source = try XCTUnwrap(Self.firstElement(ofRole: kAXTextAreaRole, in: sourceWindow))
        XCTAssertEqual(string(kAXValueAttribute, in: source), original)
        XCTAssertEqual(string(kAXDescriptionAttribute, in: source), sourceLabel)

        // AX marks Option as bit 2. Find uses plain Command+F.
        let command = try menuItem(commandCharacter: "F", pid: pid, modifiers: 2)
        XCTAssertEqual(AXUIElementPerformAction(command, kAXPressAction as CFString), .success)
        let findWindow = try waitForWindow(pid: pid) { isDocument($0) && textFields(in: $0).count == 2 }
        let fields = textFields(in: findWindow)
        XCTAssertEqual(fields.count, 2)
        let query = try XCTUnwrap(fields.first)
        let replacement = try XCTUnwrap(fields.dropFirst().first)
        let queryValue = "needle"
        let replacementValue = "替换内容"
        XCTAssertEqual(AXUIElementSetAttributeValue(query, kAXValueAttribute as CFString, queryValue as CFString), .success)
        XCTAssertEqual(AXUIElementSetAttributeValue(replacement, kAXValueAttribute as CFString, replacementValue as CFString), .success)

        // Locate both fields by content so this cannot pass using placeholder text.
        let filledWindow = try waitForWindow(pid: pid) { window in
            isDocument(window) && Set(textFields(in: window).compactMap { string(kAXValueAttribute, in: $0) })
                == Set([queryValue, replacementValue])
        }
        let filledFields = textFields(in: filledWindow)
        let filledQuery = try XCTUnwrap(filledFields.first { string(kAXValueAttribute, in: $0) == queryValue })
        let filledReplacement = try XCTUnwrap(filledFields.first { string(kAXValueAttribute, in: $0) == replacementValue })
        XCTAssertEqual(string(kAXDescriptionAttribute, in: filledQuery), findLabel)
        XCTAssertEqual(string(kAXDescriptionAttribute, in: filledReplacement), replacementLabel)
        XCTAssertEqual(string(kAXValueAttribute, in: source), original)
    }

    // MARK: - Remote-image permission

    private enum RemoteImageSurface: String {
        case banner = "remote-images-notice"
        case statusMenu = "remote-images-status-menu"
    }

    private static func remoteImageAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func remoteImageControl(_ id: String, in root: AXUIElement) -> AXUIElement? {
        if remoteImageAttribute(kAXIdentifierAttribute, of: root) == id { return root }
        for child in children(of: root) {
            if let found = remoteImageControl(id, in: child) { return found }
        }
        return nil
    }

    private func pressRemoteImageMenuItem(
        _ id: String, title: String, in window: AXUIElement, pid: pid_t
    ) throws {
        let opener = try XCTUnwrap(Self.remoteImageControl(RemoteImageSurface.statusMenu.rawValue, in: window))
        let status = L10n.text(.remoteImagesAllowed, language: .english)
        XCTAssertTrue([kAXValueAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXTitleAttribute].contains {
            Self.remoteImageAttribute($0, of: opener)?.contains(status) == true
        }, "The status menu must announce session permission")
        AXUIElementSetMessagingTimeout(opener, 1)
        let result = AXUIElementPerformAction(opener, kAXPressAction as CFString)
        XCTAssertTrue(result == .success || result == .cannotComplete, "The allowed status menu can be opened by AXPress")

        func action(in root: AXUIElement) -> AXUIElement? {
            if Self.remoteImageAttribute(kAXRoleAttribute, of: root) == kAXMenuItemRole,
               Self.isEnabled(root),
               (Self.remoteImageAttribute(kAXIdentifierAttribute, of: root) == id || Self.title(of: root) == title) {
                return root
            }
            for child in Self.children(of: root) {
                if let result = action(in: child) { return result }
            }
            return nil
        }
        let deadline = Date().addingTimeInterval(5)
        repeat {
            let roots = [opener, window, AXUIElementCreateApplication(pid)]
            if let item = roots.lazy.compactMap(action(in:)).first {
                AXUIElementSetMessagingTimeout(item, 1)
                let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
                XCTAssertTrue(result == .success || result == .cannotComplete, title)
                return
            }
            usleep(50_000)
        } while Date() < deadline
        throw GuardFailure("The allowed status menu did not expose the enabled action \(title)")
    }

    private func pressRemoteImageAppMenuRevoke(pid: pid_t) throws {
        let application = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        XCTAssertEqual(AXUIElementCopyAttributeValue(application, kAXMenuBarAttribute as CFString, &value), .success)
        let menuBar = try XCTUnwrap(Self.element(value))
        let path = ["View", "Remote Images", "Block Remote Images"]
        func item(at depth: Int) -> AXUIElement? {
            var parent = menuBar
            for title in path.prefix(depth + 1) {
                guard let item = Self.children(of: parent).first(where: { Self.title(of: $0) == title }) else { return nil }
                if title == path[depth] { return item }
                guard let menu = Self.children(of: item).first(where: {
                    Self.remoteImageAttribute(kAXRoleAttribute, of: $0) == kAXMenuRole
                }) else { return nil }
                parent = menu
            }
            return nil
        }
        for (depth, title) in path.enumerated() {
            let deadline = Date().addingTimeInterval(5)
            while item(at: depth).map(Self.isEnabled) != true, Date() < deadline { usleep(50_000) }
            let command = try XCTUnwrap(item(at: depth), title)
            XCTAssertTrue(Self.isEnabled(command), title)
            AXUIElementSetMessagingTimeout(command, 1)
            let result = AXUIElementPerformAction(command, kAXPressAction as CFString)
            XCTAssertTrue(result == .success || result == .cannotComplete, title)
        }
    }

    func testRemoteImageNoticeFollowsSourceEdits() throws {
        let document = try makeDocument("notes/RemoteImagePresence.md")
        let noImages = "# No remote images\n\n[Ordinary link](https://example.invalid/page)\n\n![local](assets/local.png)\n"
        let withImage = noImages + "\n![pic](http://localhost:1/remote.png)\n"
        try Data(noImages.utf8).write(to: document)
        let pid = try launch(recents: [], language: "english", appleLanguages: ["en"])
        try open(document)

        func waitForSource(_ expected: String, surface: RemoteImageSurface?) throws -> AXUIElement {
            let host = try waitForWindow(pid: pid) { window in
                guard Self.title(of: window).hasPrefix(document.lastPathComponent),
                      let editor = Self.firstElement(ofRole: kAXTextAreaRole, in: window),
                      Self.remoteImageAttribute(kAXValueAttribute, of: editor) == expected else { return false }
                let banner = Self.remoteImageControl(RemoteImageSurface.banner.rawValue, in: window)
                let statusMenu = Self.remoteImageControl(RemoteImageSurface.statusMenu.rawValue, in: window)
                return (banner != nil) == (surface == .banner) && (statusMenu != nil) == (surface == .statusMenu)
            }
            return try XCTUnwrap(Self.firstElement(ofRole: kAXTextAreaRole, in: host))
        }

        func replace(_ previous: String, with replacement: String, in editor: AXUIElement) throws {
            XCTAssertEqual(AXUIElementSetAttributeValue(editor, kAXFocusedAttribute as CFString, kCFBooleanTrue), .success)
            var range = CFRange(location: 0, length: previous.utf16.count)
            let selection = try XCTUnwrap(AXValueCreate(.cfRange, &range))
            XCTAssertEqual(AXUIElementSetAttributeValue(editor, kAXSelectedTextRangeAttribute as CFString, selection), .success)
            XCTAssertEqual(AXUIElementSetAttributeValue(editor, kAXSelectedTextAttribute as CFString, replacement as CFString), .success)
        }

        func switchMode(_ key: String, title: String) throws {
            let command = try menuItem(commandCharacter: key, pid: pid, modifiers: 0)
            XCTAssertEqual(Self.title(of: command), title)
            XCTAssertEqual(AXUIElementPerformAction(command, kAXPressAction as CFString), .success)
        }

        func waitForPreview(showsBanner: Bool) throws {
            _ = try waitForWindow(pid: pid) { window in
                guard Self.title(of: window).hasPrefix(document.lastPathComponent),
                      Self.firstElement(ofRole: kAXTextAreaRole, in: window) == nil,
                      Self.firstElement(ofRole: "AXWebArea", in: window) != nil else { return false }
                return (Self.remoteImageControl(RemoteImageSurface.banner.rawValue, in: window) != nil) == showsBanner
                    && Self.remoteImageControl(RemoteImageSurface.statusMenu.rawValue, in: window) == nil
            }
        }

        let editor = try waitForSource(noImages, surface: nil)
        try replace(noImages, with: withImage, in: editor)
        _ = try waitForSource(withImage, surface: .banner)
        try switchMode("2", title: "Preview")
        try waitForPreview(showsBanner: true)

        try switchMode("3", title: "Side by Side")
        let splitEditor = try waitForSource(withImage, surface: .banner)
        try replace(withImage, with: noImages, in: splitEditor)
        _ = try waitForSource(noImages, surface: nil)
        try switchMode("2", title: "Preview")
        try waitForPreview(showsBanner: false)

        try switchMode("1", title: "Edit")
        let cleanEditor = try waitForSource(noImages, surface: nil)
        try replace(noImages, with: withImage, in: cleanEditor)
        let blocked = try waitForWindow(pid: pid) {
            Self.title(of: $0).hasPrefix(document.lastPathComponent)
                && Self.remoteImageControl("remote-images-allow", in: $0) != nil
        }
        let allow = try XCTUnwrap(Self.remoteImageControl("remote-images-allow", in: blocked))
        XCTAssertEqual(AXUIElementPerformAction(allow, kAXPressAction as CFString), .success)
        let prompt = try waitForWindow(pid: pid) { Self.remoteImageControl("remote-images-confirm", in: $0) != nil }
        let confirm = try XCTUnwrap(Self.remoteImageControl("remote-images-confirm", in: prompt))
        XCTAssertEqual(AXUIElementPerformAction(confirm, kAXPressAction as CFString), .success)
        let allowed = try waitForSource(withImage, surface: .statusMenu)
        try replace(withImage, with: noImages, in: allowed)
        let withoutImages = try waitForSource(noImages, surface: nil)

        // The status indicator goes away with the last image. The View menu
        // must still let the user revoke this document's active session grant.
        try pressRemoteImageAppMenuRevoke(pid: pid)
        try replace(noImages, with: withImage, in: withoutImages)
        _ = try waitForSource(withImage, surface: .banner)
    }

    func testRemoteImagePermissionSheetCancelsConfirmsRevokesAndClosesOnReload() throws {
        let document = try makeDocument("notes/RemoteImagePermission.md")
        let original = "# Permission test\n\n![Remote](http://localhost:1/permission.png)\n"
        try Data(original.utf8).write(to: document)
        let pid = try launch(recents: [], language: "english", appleLanguages: ["en"])
        try open(document)
        let app = AXUIElementCreateApplication(pid)

        let allow = "remote-images-allow"
        let cancel = "remote-images-cancel"
        let confirm = "remote-images-confirm"
        let statusMenu = RemoteImageSurface.statusMenu.rawValue
        let banner = RemoteImageSurface.banner.rawValue
        let attribute = Self.remoteImageAttribute
        let control = Self.remoteImageControl
        func sheet(in window: AXUIElement) -> AXUIElement? {
            Self.firstElement(ofRole: kAXSheetRole, in: window)
        }
        func isDocument(_ window: AXUIElement) -> Bool {
            Self.title(of: window) == document.lastPathComponent
        }
        func press(_ id: String, in root: AXUIElement) throws {
            let button = try XCTUnwrap(control(id, root), id)
            XCTAssertEqual(attribute(kAXRoleAttribute, button), kAXButtonRole)
            XCTAssertEqual(AXUIElementPerformAction(button, kAXPressAction as CFString), .success, id)
        }
        func expectState(allowed: Bool, source: String) throws -> AXUIElement {
            let id = allowed ? statusMenu : allow
            let window: AXUIElement
            do {
                window = try waitForWindow(pid: pid) {
                    guard isDocument($0), sheet(in: $0) == nil, control(id, $0) != nil,
                          let editor = Self.firstElement(ofRole: kAXTextAreaRole, in: $0) else { return false }
                    return attribute(kAXValueAttribute, editor) == source
                }
            } catch {
                let current = Self.windows(pid: pid).first(where: isDocument)
                let editor = current.flatMap { Self.firstElement(ofRole: kAXTextAreaRole, in: $0) }
                throw GuardFailure("Expected permission control \(id) and source \(source.debugDescription); "
                    + "actual source \(editor.flatMap { attribute(kAXValueAttribute, $0) }?.debugDescription ?? "missing"), "
                    + "allow=\(current.flatMap { control(allow, $0) } != nil), "
                    + "status menu=\(current.flatMap { control(statusMenu, $0) } != nil), "
                    + "sheet=\(current.flatMap(sheet(in:)) != nil); \(error)")
            }
            XCTAssertNil(control(allowed ? allow : statusMenu, window))
            XCTAssertEqual(control(banner, window) != nil, !allowed)
            XCTAssertEqual(try Data(contentsOf: document), Data(source.utf8))
            return window
        }
        func openPrompt(in window: AXUIElement) throws -> AXUIElement {
            let opener = try XCTUnwrap(control(allow, window), allow)
            var focusSettable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(opener, kAXFocusedAttribute as CFString, &focusSettable) == .success,
               focusSettable.boolValue {
                XCTAssertEqual(AXUIElementSetAttributeValue(opener, kAXFocusedAttribute as CFString, kCFBooleanTrue), .success)
            }
            try press(allow, in: window)

            let host = try waitForWindow(pid: pid) {
                guard isDocument($0), let attached = sheet(in: $0) else { return false }
                var focused: CFTypeRef?
                AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
                guard let focus = Self.element(focused), attribute(kAXIdentifierAttribute, focus) == cancel else { return false }
                return control(cancel, attached) != nil && control(confirm, attached) != nil
            }
            return try XCTUnwrap(sheet(in: host), "native sheet attached to the fixture window")
        }

        var window = try expectState(allowed: false, source: original)
        try press(cancel, in: openPrompt(in: window))
        window = try expectState(allowed: false, source: original)
        try press(confirm, in: openPrompt(in: window))
        window = try expectState(allowed: true, source: original)
        try pressRemoteImageMenuItem("remote-images-revoke", title: "Block Remote Images", in: window, pid: pid)
        window = try expectState(allowed: false, source: original)

        // A clean external reload changes the document context while the
        // prompt is active. Appending in place gives the watcher one new version.
        _ = try openPrompt(in: window)
        let addition = "\nExternal update.\n"
        do {
            let writer = try FileHandle(forWritingTo: document)
            defer { try? writer.close() }
            _ = try writer.seekToEnd()
            try writer.write(contentsOf: Data(addition.utf8))
        }
        _ = try expectState(allowed: false, source: original + addition)
    }

    func testRemoteResourceDetailsReportDoesNotFetchAndClosesOnReload() throws {
        let originalServer = try ResourceRequestServer(), replacementServer = try ResourceRequestServer()
        defer { originalServer.stop(); replacementServer.stop() }
        func waitForRequests(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(10)
            while !condition(), Date() < deadline { usleep(50_000) }
            return condition()
        }
        guard waitForRequests({ originalServer.port != nil && replacementServer.port != nil }),
              let originalPort = originalServer.port, let replacementPort = replacementServer.port else {
            throw GuardFailure("remote resource fixtures did not start listening")
        }
        // Use the loopback hostname so the launched app's ATS policy can
        // permit the plain HTTP fixture.
        let originalOrigin = "http://localhost:\(originalPort)"
        let replacementOrigin = "http://localhost:\(replacementPort)"
        let document = try makeDocument("notes/RemoteResourceDetails.md")
        let original = """
        # Resource details

        ![Direct](\(originalOrigin)/direct.png)

        <img src="\(originalOrigin)/raw.png?token=private-fixture" alt="Raw">
        """
        let replacement = "![Replacement](\(replacementOrigin)/replacement.png)"
        try Data(original.utf8).write(to: document)
        let pid = try launch(recents: [], language: "english", appleLanguages: ["en"])
        try open(document)

        let details = "remote-images-details"
        let close = "remote-images-details-close"
        let allow = "remote-images-allow"
        let confirm = "remote-images-confirm"
        let statusMenu = RemoteImageSurface.statusMenu.rawValue
        let banner = RemoteImageSurface.banner.rawValue
        let attribute = Self.remoteImageAttribute
        let element = Self.remoteImageControl
        func sheet(in window: AXUIElement) -> AXUIElement? {
            Self.firstElement(ofRole: kAXSheetRole, in: window)
        }
        func isDocument(_ window: AXUIElement) -> Bool {
            Self.title(of: window) == document.lastPathComponent
        }
        func press(_ id: String, in root: AXUIElement) throws {
            let button = try XCTUnwrap(element(id, root), id)
            XCTAssertEqual(AXUIElementPerformAction(button, kAXPressAction as CFString), .success, id)
        }
        func windowWithPolicy(_ id: String, requiresPreview: Bool = false) throws -> AXUIElement {
            do {
                return try waitForWindow(pid: pid) {
                    isDocument($0) && sheet(in: $0) == nil && element(id, $0) != nil
                        && (element(banner, $0) != nil) == (id == allow)
                        && (id == statusMenu || element(details, $0).map { Self.isEnabled($0) } == true)
                        && (!requiresPreview || Self.firstElement(ofRole: "AXWebArea", in: $0) != nil)
                }
            } catch {
                throw GuardFailure("waiting for \(id) (live preview required: \(requiresPreview)): \(error)")
            }
        }
        func accessibleText(in root: AXUIElement) -> [String] {
            [attribute(kAXValueAttribute, root) ?? "", Self.title(of: root)]
                + Self.children(of: root).flatMap { accessibleText(in: $0) }
        }
        func openDetails(in window: AXUIElement, origin: String, references: Int) throws -> AXUIElement {
            if element(statusMenu, window) != nil {
                try pressRemoteImageMenuItem(details, title: "Details…", in: window, pid: pid)
            } else {
                try press(details, in: window)
            }
            let host = try waitForWindow(pid: pid) {
                guard isDocument($0), let attached = sheet(in: $0), element(close, attached) != nil,
                      let origins = element("remote-images-origins", attached),
                      let summary = attribute(kAXValueAttribute, origins) else { return false }
                return summary.contains(origin)
            }
            let detailsSheet = try XCTUnwrap(sheet(in: host))
            let origins = try XCTUnwrap(element("remote-images-origins", detailsSheet))
            let summary = try XCTUnwrap(attribute(kAXValueAttribute, origins))
            XCTAssertEqual(summary.trimmingCharacters(in: .whitespacesAndNewlines), "\(origin) — \(references)")
            let scope = accessibleText(in: detailsSheet).joined(separator: " ").lowercased()
            for text in ["css", "svg", "diagram", "blocked request count and redirect destinations are unknown"] {
                XCTAssertTrue(scope.contains(text), "Missing inspection limit \(text) in \(scope)")
            }
            return detailsSheet
        }
        func assertQuiet(_ server: ResourceRequestServer, after requestCount: Int = 0) {
            // Allow an accidental request to reach the listener before reading
            // the counter. The explicit grant below proves the same host is reachable.
            usleep(500_000)
            XCTAssertEqual(server.requests.count, requestCount)
        }

        // Enter Split via the live document's command. The window starts with
        // an untitled store and can adopt that store's presentation preference.
        _ = try windowWithPolicy(allow)
        let split = try menuItem(commandCharacter: "3", pid: pid, modifiers: 0)
        XCTAssertEqual(Self.title(of: split), "Side by Side")
        XCTAssertTrue(Self.isEnabled(split))
        XCTAssertEqual(AXUIElementPerformAction(split, kAXPressAction as CFString), .success)
        let blocked = try openDetails(in: windowWithPolicy(allow, requiresPreview: true), origin: originalOrigin, references: 2)
        try press(close, in: blocked)
        assertQuiet(originalServer)
        XCTAssertEqual(try Data(contentsOf: document), Data(original.utf8))

        try press(allow, in: windowWithPolicy(allow))
        let prompt = try waitForWindow(pid: pid) {
            isDocument($0) && sheet(in: $0).flatMap { element(confirm, $0) } != nil
        }
        try press(confirm, in: XCTUnwrap(sheet(in: prompt)))
        let allowed = try windowWithPolicy(statusMenu, requiresPreview: true)
        guard waitForRequests({
            let paths = originalServer.requests.compactMap { $0.path.split(separator: "?", maxSplits: 1).first }
            return paths.contains("/direct.png") && paths.contains("/raw.png")
        }) else {
            throw GuardFailure("granted preview did not request both fixture images; observed \(originalServer.requests.map(\.path))")
        }
        let requestsBeforeInspection = originalServer.requests.count
        let allowedDetails = try openDetails(in: allowed, origin: originalOrigin, references: 2)
        try press(close, in: allowedDetails)
        assertQuiet(originalServer, after: requestsBeforeInspection)

        try pressRemoteImageMenuItem("remote-images-revoke", title: "Block Remote Images", in: windowWithPolicy(statusMenu), pid: pid)
        _ = try openDetails(in: windowWithPolicy(allow), origin: originalOrigin, references: 2)
        do {
            let writer = try FileHandle(forWritingTo: document)
            defer { try? writer.close() }
            let bytes = Data(replacement.utf8)
            try writer.write(contentsOf: bytes)
            try writer.truncate(atOffset: UInt64(bytes.count))
        }
        _ = try waitForWindow(pid: pid) {
            guard isDocument($0), sheet(in: $0) == nil, element(allow, $0) != nil,
                  let editor = Self.firstElement(ofRole: kAXTextAreaRole, in: $0) else { return false }
            return attribute(kAXValueAttribute, editor) == replacement
        }
        let updated = try openDetails(in: windowWithPolicy(allow), origin: replacementOrigin, references: 1)
        try press(close, in: updated)
        assertQuiet(replacementServer)
        XCTAssertEqual(originalServer.requests.count, requestsBeforeInspection)
    }

    // MARK: - Explicit paste menus

    func testPasteMenusFollowSourceFindSettingsAndPlainShortcut() throws {
        let board = NSPasteboard.general
        let saved = board.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } } ?? []
        defer {
            board.clearContents()
            board.writeObjects(saved.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            })
        }
        board.clearContents(); board.setString("PASTE_NATIVE_FIELD", forType: .string)
        let document = try makeDocument("notes/PasteMenu.md")
        let pid = try launch(recents: [], language: "english", appleLanguages: ["en"])
        try waitForEntries([], pid: pid)
        func item(_ title: String) throws -> AXUIElement {
            var barValue: CFTypeRef?
            let app = AXUIElementCreateApplication(pid)
            guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &barValue) == .success,
                  let bar = Self.element(barValue) else { throw GuardFailure("paste menu bar unavailable") }
            for entry in Self.children(of: bar) {
                for menu in Self.children(of: entry) {
                    if let result = Self.children(of: menu).first(where: { Self.title(of: $0) == title }) { return result }
                }
            }
            throw GuardFailure("paste menu item missing: \(title)")
        }
        func waitEnabled(_ title: String, _ expected: Bool) throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                if let target = try? item(title), Self.isEnabled(target) == expected { return }
                usleep(50_000)
            } while Date() < deadline
            XCTAssertEqual(Self.isEnabled(try item(title)), expected, title)
        }
        for title in ["Paste as Plain Text", "Paste as Markdown", "Paste as Table"] { try waitEnabled(title, false) }
        try open(document); try waitForEntries([document], pid: pid)
        XCTAssertEqual(AXUIElementPerformAction(try item("Edit"), kAXPressAction as CFString), .success)
        let sourceWindow = try waitForWindow(pid: pid) { Self.firstElement(ofRole: kAXTextAreaRole as String, in: $0) != nil }
        let source = try XCTUnwrap(Self.firstElement(ofRole: kAXTextAreaRole as String, in: sourceWindow))
        XCTAssertEqual(AXUIElementSetAttributeValue(source, kAXFocusedAttribute as CFString, kCFBooleanTrue), .success)
        for title in ["Paste as Plain Text", "Paste as Markdown", "Paste as Table"] { try waitEnabled(title, true) }
        let plainItem = try item("Paste as Plain Text")
        XCTAssertEqual(Self.commandCharacter(of: plainItem)?.lowercased(), "v")
        var modifiers: CFTypeRef?
        AXUIElementCopyAttributeValue(plainItem, kAXMenuItemCmdModifiersAttribute as CFString, &modifiers)
        // AX uses Shift=1, Option=2, Control=4, NoCommand=8.
        XCTAssertEqual((modifiers as? NSNumber)?.intValue, 3)
        // Actual Find focus must disable the source-only commands.
        XCTAssertEqual(AXUIElementPerformAction(try menuItem(commandCharacter: "F", pid: pid), kAXPressAction as CFString), .success)
        try waitEnabled("Paste as Markdown", false); try waitEnabled("Paste as Table", false)
        try waitEnabled("Paste as Plain Text", true)
        XCTAssertEqual(AXUIElementPerformAction(try item("Paste as Plain Text"), kAXPressAction as CFString), .success)
        let fieldDeadline = Date().addingTimeInterval(5)
        var fieldValue = ""
        repeat {
            var focusedValue: CFTypeRef?
            AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &focusedValue)
            if let focused = Self.element(focusedValue) {
                var value: CFTypeRef?
                AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &value)
                fieldValue = value as? String ?? ""
            }
            if fieldValue == "PASTE_NATIVE_FIELD" { break }
            usleep(50_000)
        } while Date() < fieldDeadline
        XCTAssertEqual(fieldValue, "PASTE_NATIVE_FIELD", "plain paste belongs to the focused Find field")
        var sourceValue: CFTypeRef?
        AXUIElementCopyAttributeValue(source, kAXValueAttribute as CFString, &sourceValue)
        XCTAssertFalse((sourceValue as? String ?? "").contains("PASTE_NATIVE_FIELD"))
        XCTAssertEqual(AXUIElementPerformAction(try menuItem(commandCharacter: ",", pid: pid), kAXPressAction as CFString), .success)
        _ = try waitForWindow(pid: pid) { Self.title(of: $0).contains("Settings") || Self.title(of: $0).contains("设置") }
        try waitEnabled("Paste as Markdown", false); try waitEnabled("Paste as Table", false)
    }

    func testPasteSourceCommandsUndoFallbackAndReadSplitBoundaries() throws {
        let board = NSPasteboard.general
        let saved = board.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } } ?? []
        defer {
            board.clearContents()
            board.writeObjects(saved.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            })
        }
        let document = try makeDocument("notes/PasteRoundTrip.md")
        let pid = try launch(recents: [], language: "english", appleLanguages: ["en"])
        try waitForEntries([], pid: pid)
        try open(document); try waitForEntries([document], pid: pid)
        func isTargetWindow(_ window: AXUIElement) -> Bool {
            let title = Self.title(of: window)
            return title == document.lastPathComponent || title == document.lastPathComponent + " *"
        }
        func sourceEditor() throws -> AXUIElement {
            let window = try waitForWindow(pid: pid) {
                isTargetWindow($0) && Self.firstElement(ofRole: kAXTextAreaRole as String, in: $0) != nil
            }
            let targets = Self.windows(pid: pid).filter(isTargetWindow)
            guard targets.count == 1, CFEqual(targets[0], window) else {
                throw GuardFailure("paste fixture expected one target document window in PID \(pid); saw \(Self.windows(pid: pid).map(Self.title(of:)))")
            }
            // The production title is always available. AXDocument is an
            // additional identity check only when this AppKit window exposes it.
            var represented: CFTypeRef?
            let documentStatus = AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &represented)
            if documentStatus == .success, let value = represented as? String, !value.isEmpty {
                guard let url = URL(string: value), url.isFileURL,
                      url.resolvingSymlinksInPath() == document.resolvingSymlinksInPath() else {
                    throw GuardFailure("paste fixture window represents \(value), expected \(document.path)")
                }
            }
            return try XCTUnwrap(Self.firstElement(ofRole: kAXTextAreaRole as String, in: window))
        }
        func sourceText(_ source: AXUIElement) throws -> String {
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(source, kAXValueAttribute as CFString, &value)
            guard status == .success, let text = value as? String else {
                throw GuardFailure("paste source AXValue unavailable in PID \(pid): AXError=\(status.rawValue), valueType=\(String(describing: value.map { CFGetTypeID($0) }))")
            }
            return text
        }
        func command(_ title: String) throws -> AXUIElement {
            var barValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXMenuBarAttribute as CFString, &barValue) == .success,
                  let bar = Self.element(barValue) else { throw GuardFailure("paste menu bar unavailable") }
            for entry in Self.children(of: bar) { for menu in Self.children(of: entry) {
                if let item = Self.children(of: menu).first(where: { Self.title(of: $0) == title || Self.title(of: $0).hasPrefix(title + " ") }) { return item }
            } }
            throw GuardFailure("paste command unavailable: \(title)")
        }
        func press(_ title: String) throws {
            let deadline = Date().addingTimeInterval(5)
            while !(try Self.isEnabled(command(title))), Date() < deadline { usleep(50_000) }
            let target = try command(title)
            print("PasteRoundTrip press \(Self.title(of: target)) enabled=\(Self.isEnabled(target))")
            XCTAssertTrue(Self.isEnabled(target))
            XCTAssertEqual(AXUIElementPerformAction(target, kAXPressAction as CFString), .success)
        }
        func select(_ source: AXUIElement, range: CFRange? = nil) throws {
            XCTAssertEqual(AXUIElementSetAttributeValue(source, kAXFocusedAttribute as CFString, kCFBooleanTrue), .success)
            let text = try sourceText(source)
            var selection = range ?? CFRange(location: 0, length: (text as NSString).length)
            let value = try XCTUnwrap(AXValueCreate(.cfRange, &selection))
            XCTAssertEqual(AXUIElementSetAttributeValue(source, kAXSelectedTextRangeAttribute as CFString, value), .success)
        }
        func waitText(_ expected: String, source: AXUIElement) throws {
            let deadline = Date().addingTimeInterval(5)
            while try sourceText(source) != expected, Date() < deadline { usleep(50_000) }
            XCTAssertEqual(try sourceText(source), expected)
        }
        func paste(_ title: String, plain: String, html: String? = nil, source: AXUIElement) throws {
            board.clearContents()
            let item = NSPasteboardItem(); item.setString(plain, forType: .string)
            if let html { item.setData(Data(html.utf8), forType: .html) }
            board.writeObjects([item])
            try select(source)
            let deadline = Date().addingTimeInterval(5)
            while !(try Self.isEnabled(command(title))), Date() < deadline { usleep(50_000) }
            XCTAssertTrue(try Self.isEnabled(command(title)))
            XCTAssertEqual(AXUIElementPerformAction(try command(title), kAXPressAction as CFString), .success)
        }
        try press("Edit")
        var source = try sourceEditor()
        let original = try sourceText(source)
        let disk = try Data(contentsOf: document)
        let expectedInitial = Data("# \(document.lastPathComponent)\n".utf8)
        guard disk == expectedInitial, Data(original.utf8) == disk else {
            throw GuardFailure("paste fixture initial bytes differ in PID \(pid), \(document.path): disk=\(Array(disk)), AX=\(Array(original.utf8)), expected=\(Array(expectedInitial))")
        }
        try paste("Paste as Plain Text", plain: "https://example.com", source: source)
        try waitText("https://example.com", source: source)
        try press("Undo")
        try waitText(original, source: source)
        try press("Redo")
        try waitText("https://example.com", source: source)
        try paste("Paste as Table", plain: "H\tB\n1\t2", source: source)
        let table = "| H | B |\n| --- | --- |\n| 1 | 2 |"
        try waitText(table, source: source)
        XCTAssertTrue(MarkdownRenderer().render(try sourceText(source)).body.contains("<table"))
        try press("Undo")
        try waitText("https://example.com", source: source)
        try paste("Paste as Markdown", plain: "Bold", html: "<p><strong>Bold</strong></p>", source: source)
        try waitText("**Bold**", source: source)
        try paste("Paste as Markdown", plain: "![x](https://example.com)", html: "<img src='https://example.com'>", source: source)
        let literal = #"\!&#91;x&#93;&#40;https\://example\.com&#41;"#
        try waitText(literal, source: source)
        XCTAssertEqual(RenderedPlainText.extract(from: MarkdownRenderer().render(try sourceText(source)).body), "![x](https://example.com)")
        XCTAssertFalse(MarkdownRenderer().render(try sourceText(source)).body.contains("<img"))
        func containsFallbackNotice(_ element: AXUIElement) -> Bool {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
            if (value as? String ?? Self.title(of: element)).contains("Formatting was not preserved") { return true }
            return Self.children(of: element).contains(where: containsFallbackNotice)
        }
        let noticeDeadline = Date().addingTimeInterval(5)
        while !Self.windows(pid: pid).contains(where: containsFallbackNotice), Date() < noticeDeadline { usleep(50_000) }
        XCTAssertTrue(Self.windows(pid: pid).contains(where: containsFallbackNotice), "whole-input fallback must be disclosed visibly")
        // Empty input must not delete a full selection or create an undo step.
        try paste("Paste as Plain Text", plain: "", source: source)
        usleep(200_000); try waitText(literal, source: source)
        try press("Undo")
        try waitText("**Bold**", source: source)
        // Read retains source but offers no source-only paste command.
        try press("Preview")
        let readDeadline = Date().addingTimeInterval(5)
        while (try Self.isEnabled(command("Paste as Markdown"))), Date() < readDeadline { usleep(50_000) }
        XCTAssertFalse(try Self.isEnabled(command("Paste as Markdown")))
        XCTAssertFalse(try Self.isEnabled(command("Paste as Table")))
        // Split re-hosts the retained editor and accepts a fresh command.
        try press("Side by Side")
        source = try sourceEditor()
        try paste("Paste as Plain Text", plain: "split source", source: source)
        try waitText("split source", source: source)
    }

    // MARK: - Live list

    // T package owns only these table-menu cases/helpers. The existing launch,
    // AX prerequisites, waits and non-table cases remain shared and unchanged.
    func testTableMenuFollowsOpeningSwitchingAndClosingDocuments() throws {
        let first = try makeDocument("notes/TableFirst.md")
        let second = try makeDocument("notes/TableSecond.md")
        let pid = try launch(recents: [], language: "english", appleLanguages: ["en"])
        try waitForEntries([], pid: pid)
        XCTAssertTrue(Self.windows(pid: pid).isEmpty)
        try waitForTableCommandsEnabled(false, pid: pid)
        try open(first)
        try waitForEntries([first], pid: pid)
        try waitForTableCommandsEnabled(true, pid: pid)
        try open(second)
        try waitForEntries([second, first], pid: pid)
        try waitForTableCommandsEnabled(true, pid: pid)
        XCTAssertEqual(AXUIElementPerformAction(try menuItem(commandCharacter: "W", pid: pid), kAXPressAction as CFString), .success)
        usleep(300_000)
        try waitForTableCommandsEnabled(true, pid: pid)
        XCTAssertEqual(AXUIElementPerformAction(try menuItem(commandCharacter: "W", pid: pid), kAXPressAction as CFString), .success)
        try waitForTableCommandsEnabled(false, pid: pid)
        try assertOpenedTableCommandsEnabled(false, pid: pid)
    }

    func testTableMenuEnablesAfterFirstOpenWithoutSettingsChange() throws {
        let document = try makeDocument("notes/TableFirstOpen.md")
        let pid = try launch(recents: [], language: "english", appleLanguages: ["en"])
        try waitForEntries([], pid: pid)
        try waitForTableCommandsEnabled(false, pid: pid)
        try open(document)
        try waitForEntries([document], pid: pid)
        try waitForTableCommandsEnabled(true, pid: pid)
        try assertOpenedTableCommandsEnabled(true, pid: pid)
    }

    func testTableMenuDisablesWhenSettingsTakesFocus() throws {
        let document = try makeDocument("notes/TableBehindSettings.md")
        let pid = try launch(recents: [], language: "english", appleLanguages: ["en"])
        try open(document)
        try waitForEntries([document], pid: pid)
        try waitForTableCommandsEnabled(true, pid: pid)
        NSRunningApplication(processIdentifier: pid)?.activate()
        let settings = try menuItem(commandCharacter: ",", pid: pid)
        AXUIElementSetMessagingTimeout(settings, 2)
        XCTAssertEqual(AXUIElementPerformAction(settings, kAXPressAction as CFString), .success)
        _ = try waitForWindow(pid: pid) {
            Self.title(of: $0).contains("Settings") && Self.firstElement(ofRole: "AXPopUpButton", in: $0) != nil
        }
        try waitForTableCommandsEnabled(false, pid: pid)
        try assertOpenedTableCommandsEnabled(false, pid: pid)
    }

    private func tableMenu(pid: pid_t) throws -> (bar: AXUIElement, menu: AXUIElement, item: AXUIElement, submenu: AXUIElement) {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXMenuBarAttribute as CFString, &value) == .success,
              let bar = Self.element(value) else { throw GuardFailure("no menu bar for table commands") }
        for item in Self.children(of: bar) {
            for menu in Self.children(of: item) {
                if let table = Self.children(of: menu).first(where: { Self.title(of: $0) == "Table Operations" }),
                   let submenu = Self.children(of: table).first {
                    return (item, menu, table, submenu)
                }
            }
        }
        throw GuardFailure("no Format > Table Operations submenu")
    }

    private func waitForTableCommandsEnabled(_ expected: Bool, pid: pid_t) throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if let menu = try? tableMenu(pid: pid) {
                let items = Self.children(of: menu.submenu)
                if items.count == 6, items.allSatisfy({ Self.isEnabled($0) == expected }) { return }
            }
            usleep(50_000)
        } while Date() < deadline
        XCTFail("Table Operations enabled state did not become \(expected)")
        throw GuardFailure("table menu state did not converge")
    }

    private func assertOpenedTableCommandsEnabled(_ expected: Bool, pid: pid_t) throws {
        let menu = try tableMenu(pid: pid)
        NSRunningApplication(processIdentifier: pid)?.activate()
        XCTAssertEqual(AXUIElementPerformAction(menu.bar, kAXPressAction as CFString), .success)
        defer { AXUIElementPerformAction(menu.menu, kAXCancelAction as CFString) }
        XCTAssertEqual(AXUIElementPerformAction(menu.item, kAXPressAction as CFString), .success)
        try waitForTableCommandsEnabled(expected, pid: pid)
    }

    /// Real SwiftUI command state after a no-document launch (independent R4 regression).
    func testCollectionMenuEnablesAfterOpeningDocument() throws {
        let document = try makeDocument("notes/ReviewCollect.md")
        let healthURL = temporaryRoot.appendingPathComponent("collection-health.log")
        let pid = try launch(recents: [], language: "english", appleLanguages: ["en"], healthURL: healthURL)
        try waitForEntries([], pid: pid)
        XCTAssertTrue(Self.windows(pid: pid).isEmpty, "the scenario must start without a document")

        func collectionItem(openFile: Bool) throws -> (AXUIElement, AXUIElement) {
            let (bar, menu, _) = try locateOpenRecent(pid: pid)
            if openFile {
                NSRunningApplication(processIdentifier: pid)?.activate()
                AXUIElementSetMessagingTimeout(bar, 2)
                XCTAssertEqual(AXUIElementPerformAction(bar, kAXPressAction as CFString), .success)
            }
            return (menu, try XCTUnwrap(Self.children(of: menu).first { Self.title(of: $0) == "Collect Local Images…" }))
        }

        // As the existing menu harness documents, opening/canceling the menu
        // must be the final GUI action. Read only the closed tree at startup.
        let (_, initialItem) = try collectionItem(openFile: false)
        XCTAssertFalse(Self.isEnabled(initialItem))
        try open(document)
        try waitForEntries([document], pid: pid)
        let healthPath = healthURL.path
        let healthDeadline = Date().addingTimeInterval(5)
        var documentReady = false
        repeat {
            let health = (try? String(contentsOfFile: healthPath, encoding: .utf8)) ?? ""
            documentReady = LaunchHealthReporter.parse(health).contains { record in
                record.stage == "openURLs" && record.windows.contains { $0.isVisible && $0.title.contains("ReviewCollect") }
            }
            if documentReady { break }
            usleep(50_000)
        } while Date() < healthDeadline
        XCTAssertTrue(documentReady, "production launch health must observe the visible opened document")

        let (fileMenu, _) = try collectionItem(openFile: true)
        defer { AXUIElementPerformAction(fileMenu, kAXCancelAction as CFString) }
        let deadline = Date().addingTimeInterval(5)
        var enabled = false
        repeat {
            enabled = Self.isEnabled(try collectionItem(openFile: false).1)
            if enabled { break }
            usleep(50_000)
        } while Date() < deadline
        print("Collection menu: production documentReady=\(documentReady), AX windows=\(Self.windows(pid: pid).map(Self.title(of:))), recents=\(Self.storedNames()), collection enabled=\(enabled)")
        XCTAssertTrue(enabled, "Collect Local Images must enable after a document opens, without changing a setting or relaunching")
    }

    func testCollectionMenuFollowsTwoOpenDocumentsAndDisablesAfterLastClose() throws {
        let first = try makeDocument("notes/CollectFirst.md")
        let second = try makeDocument("notes/CollectSecond.md")
        let pid = try launch(recents: [], language: "english", appleLanguages: ["en"])
        try waitForEntries([], pid: pid)
        try waitForCollectionEnabled(false, pid: pid)
        try open(first)
        try waitForEntries([first], pid: pid)
        try waitForCollectionEnabled(true, pid: pid)
        try open(second)
        try waitForEntries([second, first], pid: pid)
        try open(first)
        try waitForEntries([first, second], pid: pid)
        try waitForCollectionEnabled(true, pid: pid)
        let close = try menuItem(commandCharacter: "W", pid: pid)
        XCTAssertEqual(AXUIElementPerformAction(close, kAXPressAction as CFString), .success)
        try waitForCollectionEnabled(true, pid: pid)
        // Wait for the first native close to settle before issuing another.
        usleep(300_000)
        XCTAssertEqual(AXUIElementPerformAction(try menuItem(commandCharacter: "W", pid: pid), kAXPressAction as CFString), .success)
        try waitForCollectionEnabled(false, pid: pid)
        try assertOpenedCollectionEnabled(false, pid: pid)
    }

    func testCollectionMenuDisablesWhenSettingsTakesFocus() throws {
        let document = try makeDocument("notes/CollectBehindSettings.md")
        let pid = try launch(recents: [], language: "english", appleLanguages: ["en"])
        try open(document)
        try waitForEntries([document], pid: pid)
        try waitForCollectionEnabled(true, pid: pid)
        NSRunningApplication(processIdentifier: pid)?.activate()
        let settings = try menuItem(commandCharacter: ",", pid: pid)
        AXUIElementSetMessagingTimeout(settings, 2)
        XCTAssertEqual(AXUIElementPerformAction(settings, kAXPressAction as CFString), .success)
        let settingsWindow = try waitForWindow(pid: pid) {
            Self.title(of: $0).contains("Settings") && Self.firstElement(ofRole: "AXPopUpButton", in: $0) != nil
        }
        let focusDeadline = Date().addingTimeInterval(5)
        var settingsHasFocus = false
        repeat {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &value) == .success,
               let focused = Self.element(value) {
                settingsHasFocus = CFEqual(focused, settingsWindow)
            }
            if settingsHasFocus { break }
            usleep(50_000)
        } while Date() < focusDeadline
        XCTAssertTrue(settingsHasFocus, "the real Settings window must have keyboard focus")
        print("Collection Settings: focused=\(settingsHasFocus), title=\(Self.title(of: settingsWindow))")
        try waitForCollectionEnabled(false, pid: pid)
        try assertOpenedCollectionEnabled(false, pid: pid)
    }

    private func waitForCollectionEnabled(_ expected: Bool, pid: pid_t) throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            let (_, menu, _) = try locateOpenRecent(pid: pid)
            if let item = Self.children(of: menu).first(where: { Self.title(of: $0) == "Collect Local Images…" }),
               Self.isEnabled(item) == expected { return }
            usleep(50_000)
        } while Date() < deadline
        XCTFail("Collect Local Images enabled state did not become \(expected)")
        throw GuardFailure("collection menu state did not converge")
    }

    private func assertOpenedCollectionEnabled(_ expected: Bool, pid: pid_t) throws {
        let (bar, menu, _) = try locateOpenRecent(pid: pid)
        NSRunningApplication(processIdentifier: pid)?.activate()
        XCTAssertEqual(AXUIElementPerformAction(bar, kAXPressAction as CFString), .success)
        defer { AXUIElementPerformAction(menu, kAXCancelAction as CFString) }
        try waitForCollectionEnabled(expected, pid: pid)
    }

    func testOpeningADocumentShowsInTheFileMenuWithoutRelaunching() throws {
        let seeded = try makeDocument("notes/Seeded.md")
        let opened = try makeDocument("notes/Opened.md")
        let pid = try launch(recents: [seeded])
        try waitForEntries([seeded], pid: pid)

        try open(opened)

        try waitForEntries([opened, seeded], pid: pid)
        try assertOpenedMenuShows([opened, seeded], pid: pid)
    }

    /// A title depends on the whole list: the second `Same.md` renames the first.
    func testACollidingNameRetitlesTheEntryAlreadyInTheMenu() throws {
        let seeded = try makeDocument("notes/Same.md")
        let opened = try makeDocument("other/Same.md")
        let pid = try launch(recents: [seeded])
        try waitForEntries([seeded], pid: pid)

        try open(opened)

        try waitForEntries([opened, seeded], pid: pid)
        try assertOpenedMenuShows([opened, seeded], pid: pid)
    }

    func testReopeningAnOpenDocumentMovesItToTheTop() throws {
        let first = try makeDocument("notes/First.md")
        let second = try makeDocument("notes/Second.md")
        let pid = try launch(recents: [])
        try open(first)
        try waitForEntries([first], pid: pid)
        try open(second)
        try waitForEntries([second, first], pid: pid)

        try open(first)

        try waitForEntries([first, second], pid: pid)
        try assertOpenedMenuShows([first, second], pid: pid)
    }

    /// A first save reaches the list through the document window, as an open
    /// does, and the cases above show the list reaching the menu. This runs
    /// in-process so that it can skip the save panel, which is OS UI that a
    /// shared desktop can take focus from.
    @MainActor
    func testFirstSaveReachesTheListTheMenuReads() throws {
        _ = NSApplication.shared
        let saved = temporaryRoot.appendingPathComponent("FirstSave.md")
        let appDelegate = MD2AppDelegate()
        let store = DocumentStore(saveLocationPicker: { _ in saved })
        let window = appDelegate.newDocument(store: store)
        defer {
            appDelegate.recentDocuments.remove(saved)
            // Let the opening animation finish before closing: tearing a window
            // down mid-animation crashes the next window-hosted suite (TODOS.md).
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            window.animationBehavior = .none
            window.close()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }

        XCTAssertTrue(store.save(), "the first save must succeed for this to say anything about the list")
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))

        let deadline = Date().addingTimeInterval(5)
        while appDelegate.recentDocuments.urls.first?.lastPathComponent != saved.lastPathComponent, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(appDelegate.recentDocuments.entries.first?.title, saved.lastPathComponent)
    }

    func testClearMenuEmptiesTheFileMenuAndDisablesItself() throws {
        let seeded = try makeDocument("notes/Seeded.md")
        let pid = try launch(recents: [seeded])
        let menu = try waitForEntries([seeded], pid: pid)
        XCTAssertTrue(menu.isClearEnabled, "Clear Menu must be enabled while the list has entries")

        try pressClearMenu(pid: pid)

        let cleared = try waitForEntries([], pid: pid)
        XCTAssertFalse(cleared.isClearEnabled, "Clear Menu must disable itself once the list is empty")
        try assertOpenedMenuShows([], pid: pid)
    }

    func testEntriesOpenedAfterClearMenuStillAppear() throws {
        let seeded = try makeDocument("notes/Seeded.md")
        let opened = try makeDocument("notes/Opened.md")
        let pid = try launch(recents: [seeded])
        try waitForEntries([seeded], pid: pid)
        try pressClearMenu(pid: pid)
        try waitForEntries([], pid: pid)

        try open(opened)

        let menu = try waitForEntries([opened], pid: pid)
        XCTAssertTrue(menu.isClearEnabled, "Clear Menu must come back once the list has entries again")
        try assertOpenedMenuShows([opened], pid: pid)
    }

    func testSelectingAMissingFilePrunesOnlyThatEntry() throws {
        let kept = try makeDocument("notes/Kept.md")
        let missing = temporaryRoot.appendingPathComponent("notes/Missing.md")
        let pid = try launch(recents: [missing, kept])
        try waitForEntries([missing, kept], pid: pid)

        try pressEntry(titled: "Missing.md", pid: pid)
        try dismissAlert(pid: pid)

        try waitForEntries([kept], pid: pid)
        try assertOpenedMenuShows([kept], pid: pid)
    }

    /// The live list must not cost the menu its behavior: each row has to act on
    /// the document it shows, including after the rows swap places. Selecting an
    /// entry bumps it to the top, so a row still bound to its old document would
    /// leave the order unchanged.
    func testEntriesAddedDuringTheSessionActOnTheirOwnDocuments() throws {
        let first = try makeDocument("notes/First.md")
        let second = try makeDocument("notes/Second.md")
        let pid = try launch(recents: [])
        try open(first)
        try open(second)
        try waitForEntries([second, first], pid: pid)

        try pressEntry(titled: "First.md", pid: pid)
        try waitForEntries([first, second], pid: pid)

        try pressEntry(titled: "Second.md", pid: pid)
        try waitForEntries([second, first], pid: pid)
        try assertOpenedMenuShows([second, first], pid: pid)
    }

    // MARK: - Language

    /// Two update paths meet in one view: the titles come from `AppCommands`, like
    /// every other command's, and the list from the view's own observation. So a
    /// language change must re-title the submenu along with the other commands
    /// and leave the list live.
    func testLanguageChangeLeavesTheSubmenuLiveAndInStepWithOtherCommands() throws {
        let seeded = try makeDocument("notes/Seeded.md")
        let opened = try makeDocument("notes/Opened.md")
        let pid = try launch(recents: [seeded], language: "english", appleLanguages: ["en"])
        try waitForEntries([seeded], pid: pid)
        XCTAssertEqual(try readTitles(pid: pid).openRecent, "Open Recent", "the case must start in English")

        try chooseSimplifiedChinese(pid: pid)
        try dismissRestartPrompt(pid: pid)
        usleep(1_000_000)

        CFPreferencesAppSynchronize(Self.guardBundleIdentifier as CFString)
        XCTAssertEqual(
            CFPreferencesCopyAppValue("MD2.Language" as CFString, Self.guardBundleIdentifier as CFString) as? String,
            "zhHans",
            "without a real language change this case says nothing"
        )
        XCTAssertEqual(Self.title(of: try menuItem(commandCharacter: "N", pid: pid)), "新建")
        let titles = try readTitles(pid: pid)
        XCTAssertEqual(titles.openRecent, "打开最近使用的", "Open Recent left the other commands behind")
        XCTAssertEqual(titles.clearMenu, "清除菜单", "Clear Menu left the other commands behind")

        try open(opened)

        try waitForEntries([opened, seeded], pid: pid)
        try assertOpenedMenuShows([opened, seeded], pid: pid)
    }

    private func readTitles(pid: pid_t) throws -> (openRecent: String, clearMenu: String) {
        let (_, _, openRecent) = try locateOpenRecent(pid: pid)
        let clear = Self.children(of: openRecent).first.flatMap { Self.children(of: $0).last }
        return (Self.title(of: openRecent), clear.map(Self.title(of:)) ?? "")
    }

    /// Settings… is the app menu's ⌘, item. Language is the window's first picker,
    /// and its choices are follow-system, English, then Simplified Chinese.
    private func chooseSimplifiedChinese(pid: pid_t) throws {
        let settingsItem = try menuItem(commandCharacter: ",", pid: pid)
        AXUIElementSetMessagingTimeout(settingsItem, 1)
        AXUIElementPerformAction(settingsItem, kAXPressAction as CFString)

        let window = try waitForWindow(pid: pid) { Self.firstElement(ofRole: "AXPopUpButton", in: $0) != nil }
        let picker = try XCTUnwrap(Self.firstElement(ofRole: "AXPopUpButton", in: window))
        AXUIElementSetMessagingTimeout(picker, 2)
        AXUIElementPerformAction(picker, kAXPressAction as CFString)
        usleep(300_000)
        let choices = Self.children(of: picker).first.map(Self.children(of:)) ?? []
        guard choices.count == 3 else {
            throw GuardFailure("expected three language choices, found \(choices.map(Self.title(of:)))")
        }
        AXUIElementSetMessagingTimeout(choices[2], 1)
        AXUIElementPerformAction(choices[2], kAXPressAction as CFString)
    }

    /// The prompt's default button restarts the app, so this names "Later".
    private func dismissRestartPrompt(pid: pid_t) throws {
        func laterButton(in window: AXUIElement) -> AXUIElement? {
            Self.children(of: window).first { ["稍后", "Later"].contains(Self.title(of: $0)) }
        }
        let prompt = try waitForWindow(pid: pid) { laterButton(in: $0) != nil }
        let later = try XCTUnwrap(laterButton(in: prompt))
        AXUIElementSetMessagingTimeout(later, 1)
        AXUIElementPerformAction(later, kAXPressAction as CFString)
    }

    private func menuItem(commandCharacter character: String, pid: pid_t, modifiers: Int? = nil) throws -> AXUIElement {
        let appElement = AXUIElementCreateApplication(pid)
        var menuBarValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarValue) == .success,
              let menuBar = Self.element(menuBarValue) else {
            throw GuardFailure("the app's menu bar is not readable through Accessibility")
        }
        for barItem in Self.children(of: menuBar) {
            for menu in Self.children(of: barItem) {
                if let item = Self.children(of: menu).first(where: { item in
                    guard Self.commandCharacter(of: item) == character else { return false }
                    guard let modifiers else { return true }
                    var value: CFTypeRef?
                    return AXUIElementCopyAttributeValue(item, kAXMenuItemCmdModifiersAttribute as CFString, &value) == .success
                        && (value as? NSNumber)?.intValue == modifiers
                }) {
                    return item
                }
            }
        }
        let qualifier = modifiers.map { " and AX modifiers \($0)" } ?? ""
        throw GuardFailure("no menu item with the ⌘\(character) key equivalent\(qualifier) was found")
    }

    // MARK: - Launching

    @discardableResult
    private func launch(
        recents: [URL],
        language: String? = nil,
        appleLanguages: [String]? = nil,
        healthURL: URL? = nil
    ) throws -> pid_t {
        var values: [String: Any] = [
            "MD2.RestoresWindowsOnLaunch": false,
            "MD2.OpensBlankDocumentOnLaunch": false,
            Self.recentsKey: recents.map(\.path)
        ]
        // Both or neither: a mismatch makes the app relaunch itself at startup.
        if let language, let appleLanguages {
            values["MD2.Language"] = language
            values["AppleLanguages"] = appleLanguages
        }
        let domain = UserDefaults(suiteName: Self.guardBundleIdentifier)!
        domain.setPersistentDomain(values, forName: Self.guardBundleIdentifier)
        domain.synchronize()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        var environment = Self.launchEnvironment
        if let healthURL { environment["MD2_HEALTH_FILE"] = healthURL.path }
        configuration.environment = environment

        let result = LaunchResult()
        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
            result.app = app
            result.error = error
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 30) == .success else {
            throw GuardFailure("the app bundle did not launch within 30s")
        }
        if let error = result.error { throw error }
        let app = try XCTUnwrap(result.app, "the launch reported neither an app nor an error")
        launchedApps.append(app)
        return app.processIdentifier
    }

    /// The Finder path: a document delivered to the running instance.
    private func open(_ url: URL) throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.environment = Self.launchEnvironment

        let result = LaunchResult()
        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { app, error in
            result.app = app
            result.error = error
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 30) == .success else {
            throw GuardFailure("opening a document took longer than 30s")
        }
        if let error = result.error { throw error }
        let expected = try XCTUnwrap(launchedApps.last, "opening a document requires this test's launched app")
        let actual = try XCTUnwrap(result.app, "opening a document returned no app")
        guard actual.processIdentifier == expected.processIdentifier else {
            throw GuardFailure("document open reached PID \(actual.processIdentifier), expected this test's PID \(expected.processIdentifier); app=\(actual.bundleURL?.path ?? "unknown")")
        }
    }

    private func makeDocument(_ relativePath: String) throws -> URL {
        let url = temporaryRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "# \(url.lastPathComponent)\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static var launchEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["MARKDOWN2_DISABLE_APP_BUNDLE_BOOTSTRAP"] = "1"
        return environment
    }

    private static func appExecutableURL() throws -> URL {
        // …/Tests/MD2CoreTests/RecentDocumentsMenuGUITests.swift -> repo root
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        let executable = repositoryRoot
            .appendingPathComponent(".build/\(configuration)/Markdown2")
            .resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw GuardFailure(
                "no built app executable at \(executable.path); build the app before running this suite"
            )
        }
        return executable
    }

    private static func isProcessAlive(_ app: NSRunningApplication) -> Bool {
        kill(app.processIdentifier, 0) == 0
    }

    // MARK: - Reading the File menu

    private struct OpenRecentMenu: Equatable {
        var titles: [String]
        var isClearEnabled: Bool
    }

    /// Waits until the submenu holds `urls` as the Dock menu would: the same
    /// model, in the same order, with the same titles.
    @discardableResult
    private func waitForEntries(
        _ urls: [URL],
        pid: pid_t,
        timeout: TimeInterval = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> OpenRecentMenu {
        let expected = RecentDocumentsList.menuEntries(for: urls).map(\.title)
        let deadline = Date().addingTimeInterval(timeout)
        var menu = try readOpenRecent(pid: pid)
        while menu.titles != expected, Date() < deadline {
            usleep(100_000)
            menu = try readOpenRecent(pid: pid)
        }
        // The store tells a stale menu (store moved on) from a lost press (it did not).
        XCTAssertEqual(
            menu.titles,
            expected,
            "File ▸ Open Recent is not showing the live list; the store holds \(Self.storedNames())",
            file: file,
            line: line
        )
        return menu
    }

    /// Opens File ▸ Open Recent the way a user does and checks what it shows.
    /// This must be a case's last step: `kAXCancelAction` closes the menu without
    /// needing the app to be frontmost, but the next press after it can be lost.
    private func assertOpenedMenuShows(
        _ urls: [URL],
        pid: pid_t,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let expected = RecentDocumentsList.menuEntries(for: urls).map(\.title)
        let shown = try withOpenRecentOpen(pid: pid, closesMenu: true) { try Self.parse(submenu: $0) }
        XCTAssertEqual(shown.titles, expected, "the opened File ▸ Open Recent differs", file: file, line: line)
    }

    private func readOpenRecent(pid: pid_t) throws -> OpenRecentMenu {
        let (_, _, openRecent) = try locateOpenRecent(pid: pid)
        guard let submenu = Self.children(of: openRecent).first else {
            throw GuardFailure("Open Recent has no submenu")
        }
        return try Self.parse(submenu: submenu)
    }

    /// Entries, then (with entries) a separator, then Clear Menu last.
    private static func parse(submenu: AXUIElement) throws -> OpenRecentMenu {
        let items = children(of: submenu)
        guard let clear = items.last else {
            throw GuardFailure("Open Recent has no Clear Menu item")
        }
        return OpenRecentMenu(
            titles: items.dropLast().map(title(of:)).filter { !$0.isEmpty },
            isClearEnabled: isEnabled(clear)
        )
    }

    private static func storedNames() -> [String] {
        CFPreferencesAppSynchronize(guardBundleIdentifier as CFString)
        let value = CFPreferencesCopyAppValue(recentsKey as CFString, guardBundleIdentifier as CFString)
        return ((value as? [String]) ?? []).map { ($0 as NSString).lastPathComponent }
    }

    private func pressClearMenu(pid: pid_t) throws {
        try pressInOpenRecent(pid: pid) { items in items.last }
    }

    private func pressEntry(titled title: String, pid: pid_t) throws {
        try pressInOpenRecent(pid: pid) { items in
            items.first { Self.title(of: $0) == title }
        }
    }

    /// Presses an item with the menu open, as a click would. The press does not
    /// return to us until the action does, and a missing file's alert runs
    /// modally, so the call gets a short timeout rather than waiting that out.
    private func pressInOpenRecent(pid: pid_t, select: ([AXUIElement]) -> AXUIElement?) throws {
        let item = try withOpenRecentOpen(pid: pid, closesMenu: false) { submenu in
            guard let item = select(Self.children(of: submenu)) else {
                throw GuardFailure("the Open Recent item to press was not found")
            }
            return item
        }
        AXUIElementSetMessagingTimeout(item, 1)
        AXUIElementPerformAction(item, kAXPressAction as CFString)
    }

    private func withOpenRecentOpen<Result>(
        pid: pid_t,
        closesMenu: Bool,
        _ body: (AXUIElement) throws -> Result
    ) throws -> Result {
        NSRunningApplication(processIdentifier: pid)?.activate()
        let (barItem, fileMenu, openRecent) = try locateOpenRecent(pid: pid)
        AXUIElementSetMessagingTimeout(barItem, 2)
        AXUIElementPerformAction(barItem, kAXPressAction as CFString)
        usleep(200_000)
        AXUIElementSetMessagingTimeout(openRecent, 2)
        AXUIElementPerformAction(openRecent, kAXPressAction as CFString)
        usleep(200_000)
        guard let submenu = Self.children(of: openRecent).first else {
            throw GuardFailure("Open Recent has no submenu")
        }
        defer {
            if closesMenu { AXUIElementPerformAction(fileMenu, kAXCancelAction as CFString) }
        }
        return try body(submenu)
    }

    /// The File menu is the one holding ⌘O, and Open Recent directly follows
    /// that item; titles are localized ("文件" / "File").
    private func locateOpenRecent(pid: pid_t) throws -> (AXUIElement, AXUIElement, AXUIElement) {
        let appElement = AXUIElementCreateApplication(pid)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            var menuBarValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarValue) == .success,
               let menuBar = Self.element(menuBarValue) {
                for barItem in Self.children(of: menuBar) {
                    for menu in Self.children(of: barItem) {
                        let items = Self.children(of: menu)
                        if let open = items.firstIndex(where: { Self.commandCharacter(of: $0) == "O" }),
                           items.index(after: open) < items.endIndex {
                            return (barItem, menu, items[items.index(after: open)])
                        }
                    }
                }
            }
            usleep(200_000)
        }
        throw GuardFailure("no File menu with a ⌘O item was found through Accessibility")
    }

    // MARK: - Driving the app

    private func dismissAlert(pid: pid_t) throws {
        let alert = try waitForWindow(pid: pid) { Self.defaultButton(of: $0) != nil }
        let button = try XCTUnwrap(Self.defaultButton(of: alert), "the alert has no default button")
        AXUIElementSetMessagingTimeout(button, 1)
        AXUIElementPerformAction(button, kAXPressAction as CFString)
        usleep(300_000)
    }

    private func waitForWindow(
        pid: pid_t,
        timeout: TimeInterval = 10,
        where matches: (AXUIElement) -> Bool
    ) throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let window = Self.windows(pid: pid).first(where: matches) { return window }
            usleep(200_000)
        }
        let seen = Self.windows(pid: pid).map(Self.describe)
        let appChildren = Self.children(of: AXUIElementCreateApplication(pid)).map(Self.describe)
        throw GuardFailure(
            "the expected window did not appear within \(timeout)s; windows: \(seen); app children: \(appChildren)"
        )
    }

    // MARK: - Accessibility

    private static func windows(pid: pid_t) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(pid),
            kAXWindowsAttribute as CFString,
            &value
        ) == .success, let windows = value as? [AXUIElement] else {
            return []
        }
        return windows
    }

    private static func defaultButton(of window: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXDefaultButtonAttribute as CFString, &value) == .success else {
            return nil
        }
        return element(value)
    }

    private static func firstElement(ofRole role: String, in root: AXUIElement) -> AXUIElement? {
        for child in children(of: root) {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &value) == .success,
               value as? String == role {
                return child
            }
            if let nested = firstElement(ofRole: role, in: child) { return nested }
        }
        return nil
    }

    private static func describe(_ window: AXUIElement) -> String {
        var role: CFTypeRef?
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
        return "\(role as? String ?? "?")/\(subrole as? String ?? "?") \"\(title(of: window))\" "
            + "children=\(children(of: window).count) defaultButton=\(defaultButton(of: window) != nil)"
    }

    private static func title(of element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success else {
            return ""
        }
        return (value as? String) ?? ""
    }

    private static func isEnabled(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &value) == .success else {
            return false
        }
        return (value as? Bool) ?? false
    }

    private static func commandCharacter(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMenuItemCmdCharAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else {
            return []
        }
        return children
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    // MARK: - Cleanup

    private static func removeGuardPreferences() {
        UserDefaults(suiteName: guardBundleIdentifier)?.removePersistentDomain(forName: guardBundleIdentifier)
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(guardBundleIdentifier).plist")
        try? FileManager.default.removeItem(at: plist)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(guardBundleIdentifier)
        try? FileManager.default.removeItem(at: support)
    }
}

private final class LaunchResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedApp: NSRunningApplication?
    private var storedError: Error?

    var app: NSRunningApplication? {
        get { lock.withLock { storedApp } }
        set { lock.withLock { storedApp = newValue } }
    }

    var error: Error? {
        get { lock.withLock { storedError } }
        set { lock.withLock { storedError = newValue } }
    }
}

private struct GuardFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
