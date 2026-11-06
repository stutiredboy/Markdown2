import AppKit
import ApplicationServices
import XCTest

@testable import MD2App

/// Cross-process guards for MD2AppDelegate.openInNewWindow. Unlike a ContentView
/// host, this launches the real executable and activates links in its WebKit
/// accessibility tree. No document-opening or navigation callback is injected.
///
/// Each case has a unique bundle ID, preferences domain and recovery directory.
/// With MD2_RUN_GUI_TESTS=1, missing Accessibility trust is a failure, not a skip.
/// Run serially, as the existing application GUI suites do, on an unlocked desktop.
final class DocumentLinkApplicationGUITests: XCTestCase {
    private var bundleIdentifier: String!
    private var root: URL!
    private var appURL: URL!
    private var healthURL: URL!
    private var application: NSRunningApplication?
    private var pid: pid_t = 0

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 to run this application link GUI test.")
        guard AXIsProcessTrusted() else {
            throw LinkAppFailure("Accessibility trust is required to activate real links and observe the target window. This enabled GUI test cannot be validated without it.")
        }
        bundleIdentifier = "dev.codex.md2.link-guard.\(UUID().uuidString.lowercased())"
        root = FileManager.default.temporaryDirectory.appendingPathComponent(bundleIdentifier, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        appURL = root.appendingPathComponent("Markdown2.app", isDirectory: true)
        healthURL = root.appendingPathComponent("health.txt")
        try RuntimeAppBundleBuilder(bundleIdentifier: bundleIdentifier)
            .build(bundleURL: appURL, executableURL: Self.appExecutableURL())
    }

    override func tearDownWithError() throws {
        if isAlive {
            application?.terminate()
            let deadline = Date().addingTimeInterval(5)
            while isAlive, Date() < deadline { usleep(100_000) }
            if isAlive { application?.forceTerminate() }
            let forcedDeadline = Date().addingTimeInterval(5)
            while isAlive, Date() < forcedDeadline { usleep(100_000) }
        }
        guard !isAlive else {
            XCTFail("the isolated link-test app did not terminate; its files are retained at \(root.path)")
            return
        }
        application = nil
        pid = 0
        if let bundleIdentifier {
            let defaults = UserDefaults(suiteName: bundleIdentifier)!
            defaults.removePersistentDomain(forName: bundleIdentifier)
            defaults.synchronize()
            try? FileManager.default.removeItem(at: recoveryDirectory.deletingLastPathComponent())
        }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testNewWindowRevealsEncodedDuplicateHeadingAndRepeatsAfterTopLink() throws {
        let fixture = try makeFixture(heading: "目标章节", fragment: "%E7%9B%AE%E6%A0%87%E7%AB%A0%E8%8A%82-2",
                                      duplicateHeading: true)
        try launch(fixture.source, mode: .read)
        let source = try waitForWindow(fixture.source)
        let headingLink = try waitForLink("Open destination", in: source)
        let topLink = try waitForLink("Open top", in: source)
        XCTAssertEqual(documentWindows.count, 1, "the target must not already be open")

        try activate(headingLink, in: source)

        let target = try waitForWindow(fixture.target, focused: true)
        try waitForPreviewMarker(Self.destinationMarker, in: target)
        XCTAssertFalse(previewMarkerIsVisible(Self.topMarker, in: target), "the duplicate heading at the top must not win")
        try assertOnlyDocuments([fixture.source, fixture.target])

        // Empty fragments and repeated links exercise the existing-window branch
        // and prove that a consumed navigation request is an action, not state.
        try activate(topLink, in: source)
        let reused = try waitForWindow(fixture.target, focused: true)
        XCTAssertTrue(CFEqual(target, reused), "an open document must reuse the same native window")
        try waitForPreviewMarker(Self.topMarker, in: reused)
        XCTAssertFalse(previewMarkerIsVisible(Self.destinationMarker, in: reused))
        try activate(headingLink, in: source)
        _ = try waitForWindow(fixture.target, focused: true)
        try waitForPreviewMarker(Self.destinationMarker, in: target)
        try assertOnlyDocuments([fixture.source, fixture.target])
        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), fixture.text)
    }

    func testAlreadyOpenDirtyWindowNavigatesItsUnsavedHeadingWithoutReloading() throws {
        let fixture = try makeFixture(heading: "Disk destination", fragment: "draft-destination")
        try launch(fixture.target, mode: .split)
        try openDocument(fixture.source)
        let target = try waitForWindow(fixture.target)
        let source = try waitForWindow(fixture.source)
        let link = try waitForLink("Open destination", in: source)
        let editor = try waitForEditor(in: target)
        XCTAssertFalse(editorMarkerIsVisible(Self.destinationMarker, in: editor), "the target must begin below the viewport")

        // Edit through NSTextView's public Accessibility editing interface. The
        // heading exists only in memory; a disk reload cannot satisfy this link.
        let old = "## Disk destination"
        let replacement = "## Draft destination"
        let expected = fixture.text.replacingOccurrences(of: old, with: replacement)
        try raise(target)
        try select((fixture.text as NSString).range(of: old), in: editor)
        try set(kAXSelectedTextAttribute, value: replacement as CFString, on: editor)
        try wait("the editor must publish the edit and become dirty") {
            Self.string(kAXValueAttribute, of: editor) == expected && Self.title(target).hasSuffix(" *")
        }
        // Command-Up is delivered only to the isolated app. It puts the native
        // editor at the top so revealing the heading cannot pass accidentally.
        try set(kAXFocusedAttribute, value: kCFBooleanTrue, on: editor)
        try commandUp()
        try wait("the editor must return to the beginning before the link") {
            self.visibleRange(of: editor)?.location == 0
        }
        XCTAssertFalse(editorMarkerIsVisible(Self.destinationMarker, in: editor))
        try activate(link, in: source) {
            // Check after raising the source, immediately before AXPress. The
            // app may legitimately autosave while an activation is delayed.
            guard Self.title(target).hasSuffix(" *"),
                  try String(contentsOf: fixture.target, encoding: .utf8) == fixture.text else {
                throw LinkAppFailure("the target autosaved before the click; this run did not exercise a dirty window")
            }
        }

        let reused = try waitForWindow(fixture.target, focused: true)
        XCTAssertTrue(CFEqual(target, reused), "navigation must not replace the dirty window")
        try waitForEditorMarker(Self.destinationMarker, in: editor)
        try waitForPreviewMarker(Self.destinationMarker, in: target)
        XCTAssertEqual(Self.string(kAXValueAttribute, of: editor), expected, "navigation must preserve all unsaved content")
        try assertOnlyDocuments([fixture.source, fixture.target])
    }

    func testLinkRestoresDeferredDraftAndRevealsItsRecoveredHeading() throws {
        let fixture = try makeFixture(heading: "Disk destination", fragment: "recovered-destination")
        let recoveredText = fixture.text.replacingOccurrences(of: "## Disk destination", with: "## Recovered destination")
        let snapshot = DocumentRecoverySnapshot(id: UUID(), text: recoveredText, fileURL: fixture.target,
            identity: DocumentFileIdentity(url: fixture.target), format: MarkdownFileFormat(),
            fingerprint: DocumentFileFingerprint.current(at: fixture.target), isDirty: true, windowFrame: nil)
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        let recordURL = recoveryDirectory.appendingPathComponent("\(snapshot.id.uuidString).json")
        let recordData = try JSONEncoder().encode(snapshot)
        try recordData.write(to: recordURL, options: .atomic)

        // An explicit source open defers the target draft. Only a real link click
        // can reach restoreDocumentWindows(matching:) in the running app.
        try launch(fixture.source, mode: .split)
        let source = try waitForWindow(fixture.source)
        let link = try waitForLink("Open destination", in: source)
        XCTAssertEqual(documentWindows.count, 1)
        XCTAssertEqual(try Data(contentsOf: recordURL), recordData, "the target draft must still be deferred")
        XCTAssertEqual(try String(contentsOf: fixture.target, encoding: .utf8), fixture.text)

        try activate(link, in: source)

        let target = try waitForWindow(fixture.target, focused: true)
        let editor = try waitForEditor(in: target)
        try waitForEditorMarker(Self.destinationMarker, in: editor)
        try waitForPreviewMarker(Self.destinationMarker, in: target)
        XCTAssertEqual(Self.string(kAXValueAttribute, of: editor), recoveredText,
                       "the recovered text, including the heading absent from disk, must survive navigation")
        try assertOnlyDocuments([fixture.source, fixture.target])
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordURL.path), "navigation must keep the recovery record")
    }

    func testNewSplitWindowRevealsHeadingInBothPanes() throws {
        let fixture = try makeFixture(heading: "Destination", fragment: "destination")
        try launch(fixture.source, mode: .split)
        let source = try waitForWindow(fixture.source)
        let link = try waitForLink("Open destination", in: source)
        XCTAssertEqual(documentWindows.count, 1)

        try activate(link, in: source)

        let target = try waitForWindow(fixture.target, focused: true)
        let editor = try waitForEditor(in: target)
        try waitForEditorMarker(Self.destinationMarker, in: editor)
        try waitForPreviewMarker(Self.destinationMarker, in: target)
        XCTAssertFalse(previewMarkerIsVisible(Self.topMarker, in: target))
        XCTAssertGreaterThan(try XCTUnwrap(visibleRange(of: editor)).location, 500)
        XCTAssertEqual(Self.string(kAXValueAttribute, of: editor), fixture.text)
        XCTAssertFalse(Self.title(target).hasSuffix(" *"), "a navigation must not edit the document")
        try assertOnlyDocuments([fixture.source, fixture.target])
    }

    // MARK: - Isolated application and fixtures

    private static let topMarker = "LINK_GUARD_TOP_MARKER"
    private static let destinationMarker = "LINK_GUARD_DESTINATION_MARKER"

    private struct Fixture {
        let source: URL
        let target: URL
        let text: String
    }

    private func makeFixture(heading: String, fragment: String, duplicateHeading: Bool = false) throws -> Fixture {
        let source = root.appendingPathComponent("Source.md")
        let target = root.appendingPathComponent("Destination.md")
        let filler = (0..<80).map { "Paragraph \($0): enough content to keep the destination off screen.\n" }.joined(separator: "\n")
        let topHeading = duplicateHeading ? "## \(heading)" : "# Document start"
        let text = "\(topHeading)\n\n\(Self.topMarker)\n\n\(filler)\n## \(heading)\n\n\(Self.destinationMarker)\n\n\(filler)"
        try text.write(to: target, atomically: true, encoding: .utf8)
        try "# Link source\n\n[Open destination](Destination.md#\(fragment))\n\n[Open top](Destination.md#)\n"
            .write(to: source, atomically: true, encoding: .utf8)
        return Fixture(source: source, target: target, text: text)
    }

    private var recoveryDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleIdentifier).appendingPathComponent("Document Recovery", isDirectory: true)
    }

    private var isAlive: Bool { pid > 0 && kill(pid, 0) == 0 }

    private func launch(_ url: URL, mode: EditorMode) throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: bundleIdentifier))
        // Keep the stored app language and AppKit override in sync. A mismatch
        // relaunches the app before didFinishLaunching and invalidates our PID.
        defaults.setPersistentDomain([
            "MD2.DefaultMode": mode.rawValue, "MD2.NewDocumentMode": mode.rawValue,
            "MD2.Language": "english", "AppleLanguages": ["en"],
            "MD2.ShowsOutlineByDefault": false,
            "MD2.RestoresWindowsOnLaunch": true, "NSQuitAlwaysKeepsWindows": true,
            "AppleWindowTabbingMode": "manual"
        ], forName: bundleIdentifier)
        defaults.synchronize()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [url.path]
        var environment = ProcessInfo.processInfo.environment
        environment["MD2_HEALTH_FILE"] = healthURL.path
        environment["MARKDOWN2_DISABLE_APP_BUNDLE_BOOTSTRAP"] = "1"
        configuration.environment = environment
        let result = LinkLaunchResult()
        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
            result.store(app: app, error: error)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 30) == .success else {
            throw LinkAppFailure("the isolated app did not launch within 30 seconds")
        }
        if let error = result.error { throw error }
        application = try XCTUnwrap(result.app)
        pid = application!.processIdentifier // Keep it before termination; NSRunningApplication's PID is lazy.
        guard pid > 0 else { throw LinkAppFailure("the isolated app exited before its PID was recorded") }
        AXUIElementSetMessagingTimeout(AXUIElementCreateApplication(pid), 2)
        try wait("the launched application must report its real window inventory") {
            guard let text = try? String(contentsOf: self.healthURL, encoding: .utf8) else { return false }
            return LaunchHealthReporter.parse(text).contains { $0.stage == "didFinishLaunching" }
        }
    }

    private func openDocument(_ url: URL) throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        let result = LinkLaunchResult()
        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { app, error in
            result.store(app: app, error: error)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 30) == .success else {
            throw LinkAppFailure("opening the source document in the isolated app timed out")
        }
        if let error = result.error { throw error }
        let opened = try XCTUnwrap(result.app)
        guard opened.processIdentifier == pid else {
            opened.forceTerminate()
            throw LinkAppFailure("the source document opened in another app instance, so this run cannot test window reuse")
        }
    }

    private static func appExecutableURL() throws -> URL {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        let executable = repository.appendingPathComponent(".build/\(configuration)/Markdown2").resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw LinkAppFailure("build the real application before this suite: no executable at \(executable.path)")
        }
        return executable
    }

    // MARK: - Native user actions and observations

    private var documentWindows: [AXUIElement] {
        (Self.attribute(kAXWindowsAttribute, of: AXUIElementCreateApplication(pid)) as? [AXUIElement] ?? [])
            .filter { Self.title($0).hasSuffix(".md") || Self.title($0).hasSuffix(".md *") }
    }

    private func waitForWindow(_ url: URL, focused: Bool = false) throws -> AXUIElement {
        var result: AXUIElement?
        try wait("window \(url.lastPathComponent) must exist\(focused ? " and have focus" : "")") {
            result = self.documentWindows.first { Self.title($0).replacingOccurrences(of: " *", with: "") == url.lastPathComponent }
            guard let result else { return false }
            return !focused || self.isFocused(result)
        }
        return try XCTUnwrap(result)
    }

    private func assertOnlyDocuments(_ urls: [URL], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(documentWindows.map { Self.title($0).replacingOccurrences(of: " *", with: "") }.sorted(),
                       urls.map(\.lastPathComponent).sorted(), file: file, line: line)
    }

    private func isFocused(_ window: AXUIElement) -> Bool {
        guard let focused = Self.attribute(kAXFocusedWindowAttribute, of: AXUIElementCreateApplication(pid)) else { return false }
        return CFEqual(window, focused)
    }

    private func raise(_ window: AXUIElement) throws {
        application?.activate()
        guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else {
            throw LinkAppFailure("could not raise the isolated document window")
        }
        try wait("the raised document must have focus") { self.isFocused(window) }
    }

    private func waitForLink(_ label: String, in window: AXUIElement) throws -> AXUIElement {
        var link: AXUIElement?
        try wait("the rendered source must expose the real \(label) link") {
            link = Self.descendants(window).first {
                Self.string(kAXRoleAttribute, of: $0) == "AXLink" && Self.accessibleText($0).contains(label)
            }
            return link != nil
        }
        return try XCTUnwrap(link)
    }

    private func activate(_ link: AXUIElement, in window: AXUIElement, beforePress: () throws -> Void = {}) throws {
        try raise(window)
        guard let frame = Self.frame(of: link), let viewport = Self.frame(of: window),
              frame.width > 0, frame.height > 0, viewport.contains(CGPoint(x: frame.midX, y: frame.midY)) else {
            throw LinkAppFailure("the source link is not physically in the window viewport")
        }
        // AXPress is the system's user activation, not JavaScript .click(). It
        // must traverse WebKit's trusted-click gate and the real app delegate.
        try beforePress()
        let result = AXUIElementPerformAction(link, kAXPressAction as CFString)
        guard result == .success else { throw LinkAppFailure("link activation failed with AXError \(result.rawValue)") }
    }

    private func waitForEditor(in window: AXUIElement) throws -> AXUIElement {
        var editor: AXUIElement?
        try wait("the split document must expose its native editor") {
            editor = Self.descendants(window).first { Self.string(kAXRoleAttribute, of: $0) == kAXTextAreaRole }
            return editor != nil
        }
        return try XCTUnwrap(editor)
    }

    private func waitForEditorMarker(_ marker: String, in editor: AXUIElement) throws {
        try wait("the native editor must reveal \(marker)") { self.editorMarkerIsVisible(marker, in: editor) }
    }

    private func editorMarkerIsVisible(_ marker: String, in editor: AXUIElement) -> Bool {
        guard let text = Self.string(kAXValueAttribute, of: editor), let visible = visibleRange(of: editor) else { return false }
        let range = (text as NSString).range(of: marker)
        return range.location != NSNotFound && NSIntersectionRange(range, visible).length == range.length
    }

    private func visibleRange(of editor: AXUIElement) -> NSRange? {
        guard let value = Self.axValue(kAXVisibleCharacterRangeAttribute, of: editor) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range), range.location >= 0, range.length > 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private func waitForPreviewMarker(_ marker: String, in window: AXUIElement) throws {
        try wait("the real WebKit preview must reveal \(marker)") { self.previewMarkerIsVisible(marker, in: window) }
    }

    private func previewMarkerIsVisible(_ marker: String, in window: AXUIElement) -> Bool {
        guard let windowFrame = Self.frame(of: window),
              let webArea = Self.descendants(window).first(where: { Self.string(kAXRoleAttribute, of: $0) == "AXWebArea" }),
              let webFrame = Self.frame(of: webArea) else { return false }
        // Clip to the actual native window as well as the WebArea. WebKit may
        // expose offscreen nodes; finding a node alone is not evidence of a jump.
        let viewport = windowFrame.intersection(webFrame).insetBy(dx: 4, dy: 4)
        return Self.descendants(webArea).contains { element in
            guard Self.string(kAXRoleAttribute, of: element) == kAXStaticTextRole,
                  Self.accessibleText(element) == marker, let frame = Self.frame(of: element),
                  frame.width > 0, frame.height > 0 else { return false }
            return viewport.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
    }

    private func select(_ range: NSRange, in editor: AXUIElement) throws {
        guard range.location != NSNotFound else { throw LinkAppFailure("the text to edit was absent") }
        var selected = CFRange(location: range.location, length: range.length)
        try set(kAXSelectedTextRangeAttribute, value: XCTUnwrap(AXValueCreate(.cfRange, &selected)), on: editor)
    }

    private func set(_ attribute: String, value: CFTypeRef, on element: AXUIElement) throws {
        let result = AXUIElementSetAttributeValue(element, attribute as CFString, value)
        guard result == .success else { throw LinkAppFailure("setting \(attribute) failed with AXError \(result.rawValue)") }
    }

    private func commandUp() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .combinedSessionState))
        for down in [true, false] {
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 126, keyDown: down))
            event.flags = .maskCommand
            event.postToPid(pid)
        }
    }

    private func wait(_ evidence: String, timeout: TimeInterval = 15, until predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard isAlive else { throw LinkAppFailure("the isolated application exited while waiting: \(evidence)") }
            if predicate() { return }
            usleep(50_000)
        }
        throw LinkAppFailure("\(evidence); timed out. Window titles: \(documentWindows.map(Self.title))")
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ name: String, of element: AXUIElement) -> String? { attribute(name, of: element) as? String }
    private static func title(_ element: AXUIElement) -> String { string(kAXTitleAttribute, of: element) ?? "" }

    private static func accessibleText(_ element: AXUIElement) -> String {
        for name in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let text = string(name, of: element), !text.isEmpty { return text }
        }
        return (attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? [])
            .compactMap { string(kAXValueAttribute, of: $0) ?? string(kAXTitleAttribute, of: $0) }.joined()
    }

    private static func descendants(_ root: AXUIElement) -> [AXUIElement] {
        var queue = [root]
        var index = 0
        // Bound traversal if a broken accessibility tree cycles. A truncated
        // tree fails the positive control instead of hanging the entire lane.
        while index < queue.count, queue.count < 4_000 {
            let children = attribute(kAXChildrenAttribute, of: queue[index]) as? [AXUIElement] ?? []
            queue.append(contentsOf: children)
            index += 1
        }
        return queue
    }

    private static func axValue(_ name: String, of element: AXUIElement) -> AXValue? {
        guard let value = attribute(name, of: element), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let origin = axValue(kAXPositionAttribute, of: element), let size = axValue(kAXSizeAttribute, of: element) else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(origin, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}

private final class LinkLaunchResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedApp: NSRunningApplication?
    private var storedError: Error?
    var app: NSRunningApplication? { lock.withLock { storedApp } }
    var error: Error? { lock.withLock { storedError } }
    func store(app: NSRunningApplication?, error: Error?) {
        lock.withLock { storedApp = app; storedError = error }
    }
}

private struct LinkAppFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
