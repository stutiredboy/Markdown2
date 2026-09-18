import AppKit
import ApplicationServices
import XCTest

@testable import MD2App

/// Guards the Settings window's launch presentation.
///
/// SwiftUI presents an app's *only* scene at launch when the executable is
/// linked below the macOS 15 SDK, and this app's only SwiftUI scene is `Settings`
/// (document windows are AppKit-managed) — so without the
/// `.defaultLaunchBehavior(.suppressed)` opt-out the Settings window opens by
/// itself on every launch, including the Finder opens that launch the app.
/// `swift test` and CI skip this suite; run it with
/// `MD2_RUN_GUI_TESTS=1 swift test --filter SettingsWindowPresentationGUITests`.
///
/// This is the repo's first multi-process GUI test: it builds a real app bundle
/// and launches it, because the behavior under guard is what the *framework* does
/// to a launched app. Consequences worth knowing:
///
/// - The guard app is built with its own bundle identifier, so the suite never
///   reads or writes the developer's app state (`dev.codex.md2.debug`).
/// - Evidence comes from the app's own window inventory (`MD2_HEALTH_FILE`),
///   which is authoritative and needs no permissions; the cases that perform the
///   app menu's Settings command additionally observe windows through
///   Accessibility and skip loudly without trust.
/// - Every absence assertion is preceded by a positive control, so a probe that
///   never reported cannot be mistaken for a window that never appeared.
final class SettingsWindowPresentationGUITests: XCTestCase {
    private static let guardBundleIdentifier = "dev.codex.md2.settings-window-guard"
    private static let settingsWindowIdentifier = "com_apple_SwiftUI_Settings_window"

    private var temporaryRoot: URL!
    private var appURL: URL!
    private var healthURL: URL!
    private var fixtureURL: URL!
    private var launchedApps: [NSRunningApplication] = []

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this launch/Window GUI test."
        )

        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsWindowPresentationGUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

        appURL = temporaryRoot.appendingPathComponent("Markdown2.app", isDirectory: true)
        healthURL = temporaryRoot.appendingPathComponent("health.txt")
        fixtureURL = temporaryRoot.appendingPathComponent("GuardFixture.md")
        try "# Guard fixture\n\nOpened by the launch guard.\n".write(to: fixtureURL, atomically: true, encoding: .utf8)

        try RuntimeAppBundleBuilder(bundleIdentifier: Self.guardBundleIdentifier)
            .build(bundleURL: appURL, executableURL: try Self.appExecutableURL())
    }

    override func tearDownWithError() throws {
        for app in launchedApps where Self.isProcessAlive(app) {
            app.terminate()
        }
        let deadline = Date().addingTimeInterval(5)
        for app in launchedApps where Self.isProcessAlive(app) {
            while Self.isProcessAlive(app), Date() < deadline { usleep(100_000) }
            if Self.isProcessAlive(app) { app.forceTerminate() }
        }
        launchedApps = []

        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        Self.removeGuardPreferences()
    }

    /// `NSRunningApplication.isTerminated` does not flip for an app obtained
    /// from a launch callback — it stays false after a real quit — so liveness
    /// is decided by the process, which is what the assertions actually mean.
    private static func isProcessAlive(_ app: NSRunningApplication) -> Bool {
        kill(app.processIdentifier, 0) == 0
    }

    // MARK: - Launch matrix

    func testDirectLaunchPresentsNoSettingsWindow() throws {
        let app = try launchApp(arguments: [])

        let record = try waitForRecord(stage: "didFinishLaunching")
        try assertNoSettingsWindow(in: record)

        // The spec's "no other window is presented either": hidden helper
        // windows (WebKit's, for one) are not presentations, visible ones are.
        let presented = record.windows.filter(\.isVisible)
        XCTAssertTrue(
            presented.isEmpty,
            "a direct launch presented windows nobody asked for: \(presented)"
        )

        XCTAssertTrue(Self.isProcessAlive(app), "the app must still be running for the record to be launch evidence")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: healthURL.path),
            "the probe must have reported; otherwise the assertions above are vacuous"
        )
    }

    func testLaunchWithDocumentArgumentPresentsOnlyTheDocument() throws {
        _ = try launchApp(arguments: [fixtureURL.path])

        let record = try waitForRecord(stage: "didFinishLaunching")
        assertDocumentWindowPresent(in: record)
        try assertNoSettingsWindow(in: record)
    }

    func testOpeningDocumentIntoRunningInstancePresentsNoSettingsWindow() throws {
        _ = try launchApp(arguments: [])
        _ = try waitForRecord(stage: "didFinishLaunching")

        try openIntoRunningInstance(urls: [fixtureURL])

        let record = try waitForRecord(stage: "openURLs")
        assertDocumentWindowPresent(in: record)
        try assertNoSettingsWindow(in: record)
    }

    func testReopeningTheRunningAppPresentsNoSettingsWindow() throws {
        _ = try launchApp(arguments: [])
        _ = try waitForRecord(stage: "didFinishLaunching")

        try reopenRunningInstance()

        let record = try waitForRecord(stage: "reopen")
        try assertNoSettingsWindow(in: record)
    }

    // MARK: - The Settings window itself

    func testSettingsCommandOpensTheWindowAndReopensItAtItsSavedFrame() throws {
        try requireAccessibilityTrust()
        let app = try launchApp(arguments: [fixtureURL.path])
        let launchRecord = try waitForRecord(stage: "didFinishLaunching")
        assertDocumentWindowPresent(in: launchRecord)
        try assertNoSettingsWindow(in: launchRecord)

        try pressSettingsMenuItem(pid: app.processIdentifier)
        let title = try waitForSettingsWindow(pid: app.processIdentifier, present: true)

        // The spec's "no document window is closed or otherwise disturbed".
        let titlesAfterOpening = Self.windowTitles(pid: app.processIdentifier)
        XCTAssertTrue(
            titlesAfterOpening.contains { $0.contains(fixtureURL.lastPathComponent) },
            "opening Settings disturbed the document window; windows: \(titlesAfterOpening)"
        )

        let originalFrame = try XCTUnwrap(
            Self.windowFrame(titled: title, pid: app.processIdentifier),
            "the Settings window does not expose its position and size"
        )

        // Move it before closing: an autosaving window comes back where it was
        // left, so a Settings window that lost its frame — or one that is not
        // the real Settings UI — shows up here rather than passing silently.
        let movedFrame = try moveWindow(
            titled: title,
            pid: app.processIdentifier,
            by: CGPoint(x: 64, y: 48)
        )
        XCTAssertNotEqual(
            movedFrame.origin.x,
            originalFrame.origin.x,
            "the window did not move, so the saved-frame check below would be vacuous"
        )

        try closeWindow(titled: title, pid: app.processIdentifier)
        _ = try waitForSettingsWindow(pid: app.processIdentifier, present: false)

        try pressSettingsMenuItem(pid: app.processIdentifier)
        let reopenedTitle = try waitForSettingsWindow(pid: app.processIdentifier, present: true)
        let reopenedFrame = try XCTUnwrap(
            Self.windowFrame(titled: reopenedTitle, pid: app.processIdentifier),
            "the re-opened Settings window does not expose its position and size"
        )

        XCTAssertEqual(reopenedFrame.origin.x, movedFrame.origin.x, accuracy: 2, "x did not restore")
        XCTAssertEqual(reopenedFrame.origin.y, movedFrame.origin.y, accuracy: 2, "y did not restore")
        XCTAssertEqual(reopenedFrame.size.width, movedFrame.size.width, accuracy: 2, "width did not restore")
        XCTAssertEqual(reopenedFrame.size.height, movedFrame.size.height, accuracy: 2, "height did not restore")
    }

    func testRelaunchAfterQuittingWithSettingsOpenDoesNotRestoreIt() throws {
        try requireAccessibilityTrust()
        let app = try launchApp(arguments: [])
        _ = try waitForRecord(stage: "didFinishLaunching")

        try pressSettingsMenuItem(pid: app.processIdentifier)
        _ = try waitForSettingsWindow(pid: app.processIdentifier, present: true)

        try terminate(app)
        // Fresh evidence: the previous instance's records stay in the file.
        try FileManager.default.removeItem(at: healthURL)

        _ = try launchApp(arguments: [])
        let relaunchRecord = try waitForRecord(stage: "didFinishLaunching")
        try assertNoSettingsWindow(in: relaunchRecord)
    }

    // MARK: - Launching

    private func launchApp(
        arguments: [String],
        createsNewInstance: Bool = true
    ) throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = createsNewInstance
        configuration.arguments = arguments
        configuration.environment = Self.launchEnvironment(healthFile: healthURL)

        let app = try open(configuration: configuration)
        launchedApps.append(app)
        return app
    }

    /// The Finder path: a document delivered as a URL to the running instance
    /// (`application(_:open:)`), not as an argv path.
    private func openIntoRunningInstance(urls: [URL]) throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.environment = Self.launchEnvironment(healthFile: healthURL)

        let app = try open(urls: urls, configuration: configuration)
        if !launchedApps.contains(where: { $0.processIdentifier == app.processIdentifier }) {
            launchedApps.append(app)
        }
    }

    /// Activating an already-running app the way the Dock does.
    private func reopenRunningInstance() throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.environment = Self.launchEnvironment(healthFile: healthURL)

        _ = try open(configuration: configuration)
    }

    private func open(configuration: NSWorkspace.OpenConfiguration) throws -> NSRunningApplication {
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
        return try XCTUnwrap(result.app, "the launch reported neither an app nor an error")
    }

    private func open(urls: [URL], configuration: NSWorkspace.OpenConfiguration) throws -> NSRunningApplication {
        let result = LaunchResult()
        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: configuration) { app, error in
            result.app = app
            result.error = error
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 30) == .success else {
            throw GuardFailure("opening a document took longer than 30s")
        }
        if let error = result.error { throw error }
        return try XCTUnwrap(result.app, "the open reported neither an app nor an error")
    }

    private func terminate(_ app: NSRunningApplication) throws {
        app.terminate()
        let deadline = Date().addingTimeInterval(10)
        while Self.isProcessAlive(app), Date() < deadline { usleep(100_000) }
        guard !Self.isProcessAlive(app) else {
            app.forceTerminate()
            throw GuardFailure("the app did not quit, so the relaunch would not be a fresh launch")
        }
    }

    private static func launchEnvironment(healthFile: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["MD2_HEALTH_FILE"] = healthFile.path
        // The bundle is already an app, so this is belt-and-braces against the
        // dev bootstrap rebuilding it out from under the test.
        environment["MARKDOWN2_DISABLE_APP_BUNDLE_BOOTSTRAP"] = "1"
        return environment
    }

    private static func appExecutableURL() throws -> URL {
        // …/Tests/MD2CoreTests/SettingsWindowPresentationGUITests.swift -> repo root
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let executable = repositoryRoot
            .appendingPathComponent(".build/debug/Markdown2")
            .resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw GuardFailure(
                "no built app executable at \(executable.path); build the app before running this suite"
            )
        }
        return executable
    }

    // MARK: - Evidence

    private func waitForRecord(
        stage: String,
        timeout: TimeInterval = 30
    ) throws -> LaunchHealthReporter.Record {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = ""
        while Date() < deadline {
            if let text = try? String(contentsOf: healthURL, encoding: .utf8) {
                latest = text
                if let record = LaunchHealthReporter.parse(text).last(where: { $0.stage == stage }) {
                    return record
                }
            }
            usleep(150_000)
        }
        throw GuardFailure(
            "no '\(stage)' record within \(Int(timeout))s; the probe never reported that stage. "
                + "Health file contents:\n\(latest.isEmpty ? "(missing or empty)" : latest)"
        )
    }

    private func assertNoSettingsWindow(
        in record: LaunchHealthReporter.Record,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let settingsWindows = record.windows.filter(Self.isSettingsWindow)
        XCTAssertTrue(
            settingsWindows.isEmpty,
            "stage '\(record.stage)' presented an unsolicited Settings window: \(settingsWindows)",
            file: file,
            line: line
        )
    }

    /// Positive control: without the document window in the inventory, "no
    /// Settings window" would also hold for an app that never opened anything.
    /// Also pins the spec's "exactly one window for that document is visible".
    private func assertDocumentWindowPresent(
        in record: LaunchHealthReporter.Record,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let presented = record.windows.filter(\.isVisible)
        XCTAssertEqual(
            presented.count,
            1,
            "stage '\(record.stage)' should present exactly the opened document; inventory: \(record.windows)",
            file: file,
            line: line
        )
        XCTAssertEqual(presented.first?.className, "ModeShortcutWindow", file: file, line: line)
        XCTAssertTrue(
            presented.first?.title.contains(fixtureURL.lastPathComponent) ?? false,
            "stage '\(record.stage)' did not report the opened document; inventory: \(record.windows)",
            file: file,
            line: line
        )
    }

    private static func isSettingsWindow(_ window: LaunchHealthReporter.WindowSnapshot) -> Bool {
        // Identifier first (stable), title second (the identifier is AppKit
        // private and could be renamed; the title is localized but always ends
        // in "Settings"/"设置").
        window.identifier == settingsWindowIdentifier
            || window.title.contains("Settings")
            || window.title.contains("设置")
    }

    // MARK: - Accessibility

    private func requireAccessibilityTrust() throws {
        try XCTSkipUnless(
            AXIsProcessTrusted(),
            "This case performs the app menu's Settings command and observes another process's "
                + "windows, which needs Accessibility trust for the test runner. Grant it to the "
                + "process running `swift test` (System Settings ▸ Privacy & Security ▸ "
                + "Accessibility, add your terminal), then run with MD2_RUN_GUI_TESTS=1. "
                + "This case does not silently pass without trust."
        )
    }

    /// Performs the app menu's Settings… item, found by its key equivalent so the
    /// check survives localization.
    private func pressSettingsMenuItem(pid: pid_t) throws {
        let appElement = AXUIElementCreateApplication(pid)
        var menuBarValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarValue) == .success,
              let menuBar = Self.element(menuBarValue) else {
            throw GuardFailure("the app's menu bar is not readable through Accessibility")
        }

        for barItem in Self.children(of: menuBar) {
            for menu in Self.children(of: barItem) {
                for menuItem in Self.children(of: menu) where Self.isSettingsShortcut(menuItem) {
                    AXUIElementPerformAction(menuItem, kAXPressAction as CFString)
                    return
                }
            }
        }

        throw GuardFailure("no app menu item with the ⌘, key equivalent was found")
    }

    /// `menuBar → bar item → menu → item`; matched on the key equivalent rather
    /// than the title, which is localized ("设置…" / "Settings…").
    private static func isSettingsShortcut(_ element: AXUIElement) -> Bool {
        guard commandCharacter(of: element) == "," else { return false }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXMenuItemCmdModifiersAttribute as CFString,
            &value
        ) == .success, let modifiers = value as? NSNumber else {
            return true
        }
        // 0 is command-only; anything else means ⌘, is not this item's shortcut.
        return modifiers.intValue == 0
    }

    /// Returns the Settings window's title once it is (or is not) on screen.
    @discardableResult
    private func waitForSettingsWindow(
        pid: pid_t,
        present: Bool,
        timeout: TimeInterval = 10
    ) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var titles: [String] = []
        while Date() < deadline {
            titles = Self.windowTitles(pid: pid)
            let match = titles.first(where: { $0.contains("Settings") || $0.contains("设置") })
            if present, let match { return match }
            if !present, match == nil { return "" }
            usleep(150_000)
        }
        throw GuardFailure(
            present
                ? "the Settings window never appeared; windows: \(titles)"
                : "the Settings window never closed; windows: \(titles)"
        )
    }

    private func closeWindow(titled title: String, pid: pid_t) throws {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            throw GuardFailure("the app's windows are not readable through Accessibility")
        }

        guard let window = windows.first(where: { Self.title(of: $0) == title }) else {
            throw GuardFailure("no window titled '\(title)' to close")
        }

        var closeButtonValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeButtonValue) == .success,
              let closeButton = Self.element(closeButtonValue) else {
            throw GuardFailure("the Settings window exposes no close button")
        }
        AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
    }

    /// Moves the window and returns the frame it actually took (AppKit may
    /// constrain it to the screen, so the caller compares against the read-back
    /// values rather than the requested ones). Waits for the frame autosave to
    /// settle before the caller closes the window.
    private func moveWindow(titled title: String, pid: pid_t, by delta: CGPoint) throws -> CGRect {
        guard let window = Self.window(titled: title, pid: pid),
              let current = Self.windowFrame(titled: title, pid: pid) else {
            throw GuardFailure("no window titled '\(title)' to move")
        }

        var target = CGPoint(x: current.origin.x + delta.x, y: current.origin.y + delta.y)
        guard let value = AXValueCreate(.cgPoint, &target) else {
            throw GuardFailure("could not build an Accessibility position value")
        }

        let result = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        guard result == .success else {
            throw GuardFailure("setting the window position failed with AXError \(result.rawValue)")
        }

        usleep(1_000_000)
        return try XCTUnwrap(
            Self.windowFrame(titled: title, pid: pid),
            "the window disappeared while moving it"
        )
    }

    private static func windowFrame(titled title: String, pid: pid_t) -> CGRect? {
        guard let window = window(titled: title, pid: pid),
              let origin = point(of: window, attribute: kAXPositionAttribute),
              let size = size(of: window, attribute: kAXSizeAttribute) else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    private static func window(titled title: String, pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return nil
        }
        return windows.first { self.title(of: $0) == title }
    }

    private static func point(of element: AXUIElement, attribute: String) -> CGPoint? {
        guard let value = axValue(of: element, attribute: attribute) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func size(of element: AXUIElement, attribute: String) -> CGSize? {
        guard let value = axValue(of: element, attribute: attribute) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private static func axValue(of element: AXUIElement, attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        return (value as! AXValue)
    }

    private static func windowTitles(pid: pid_t) -> [String] {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return []
        }
        return windows.map(title(of:))
    }

    private static func title(of element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success else {
            return ""
        }
        return (value as? String) ?? ""
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
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(guardBundleIdentifier).plist")
        try? FileManager.default.removeItem(at: plist)
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
