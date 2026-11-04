import AppKit
import ApplicationServices
import XCTest

@testable import MD2App

/// Guards the app's own menu commands against keeping their old language after a
/// language change.
///
/// Plain `swift test` skips this suite and CI's `gui-tests` job runs it; run it
/// locally with `MD2_RUN_GUI_TESTS=1 swift test --filter MenuLanguageGUITests`.
///
/// Like `SettingsWindowPresentationGUITests` it launches a real app bundle under
/// its own bundle identifier, so it never reads or writes the developer's
/// settings. Three things about the evidence:
///
/// - The language change is a real one, made through the Settings picker. Writing
///   the preference from outside would prove nothing about the running app.
/// - Waiting reads the closed menu. A read makes AppKit ask the menu to update,
///   so it sees what an open would show, and it needs no focus, which someone
///   using the machine can take away mid-run. Only a case's last step opens one.
/// - Accessibility still answers while the screen is locked, where windows report
///   the wrong role, so these cases need an unlocked session.
final class MenuLanguageGUITests: XCTestCase {
    private static let guardBundleIdentifier = "dev.codex.md2.menu-language-guard"

    private var temporaryRoot: URL!
    private var appURL: URL!
    private var launchedApps: [NSRunningApplication] = []

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this menu GUI test."
        )
        try XCTSkipUnless(
            AXIsProcessTrusted(),
            "This suite reads another process's menu bar, which needs Accessibility trust for the "
                + "test runner. Grant it to the process running `swift test` (System Settings ▸ "
                + "Privacy & Security ▸ Accessibility, add your terminal), then run with "
                + "MD2_RUN_GUI_TESTS=1. This suite does not silently pass without trust."
        )

        Self.removeGuardPreferences()
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenuLanguageGUITests-\(UUID().uuidString)", isDirectory: true)
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
        }
        launchedApps = []

        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        Self.removeGuardPreferences()
    }

    // MARK: - Titles

    func testLanguageChangeRetitlesTheCommandsWithoutARelaunch() throws {
        let pid = try launch()
        let english = try waitForCommandTitles(.english, pid: pid)

        try changeLanguage(toChoice: 2, pid: pid)

        let chinese = try waitForCommandTitles(.zhHans, pid: pid)
        XCTAssertEqual(
            Self.keyEquivalents(in: chinese),
            Self.keyEquivalents(in: english),
            "re-titling must leave every command's shortcut, and the menus' shape, as they were"
        )

        try closeSettings(pid: pid)
        try waitForCommandTitles(.zhHans, pid: pid)
        try assertOpenedFileMenuShowsCommands(.zhHans, pid: pid)
    }

    // MARK: - Launching

    @discardableResult
    private func launch(values extraValues: [String: Any] = [:]) throws -> pid_t {
        // Language and AppleLanguages together: a mismatch makes the app relaunch
        // itself at startup.
        var values: [String: Any] = [
            "MD2.RestoresWindowsOnLaunch": false,
            "MD2.OpensBlankDocumentOnLaunch": false,
            "MD2.Language": "english",
            "AppleLanguages": ["en"]
        ]
        values.merge(extraValues) { _, new in new }
        let domain = UserDefaults(suiteName: Self.guardBundleIdentifier)!
        domain.setPersistentDomain(values, forName: Self.guardBundleIdentifier)
        domain.synchronize()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.environment = Self.launchEnvironment

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

    private static var launchEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["MARKDOWN2_DISABLE_APP_BUNDLE_BOOTSTRAP"] = "1"
        return environment
    }

    private static func appExecutableURL() throws -> URL {
        // …/Tests/MD2CoreTests/MenuLanguageGUITests.swift -> repo root
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

    // MARK: - Reading the menu bar

    /// The command titles the app owns. The standard AppKit items around them
    /// (Undo, Copy, Minimize, the File and Edit menus' own titles, …) are built at
    /// launch from the process localization and still need the relaunch.
    private static var commandKeys: [L10nKey] {
        [
            .new, .open, .openRecent, .clearMenu, .save, .exportTo, .close, .print,
            .formatMenu, .paragraphMenu,
            .zoomIn, .zoomOut, .resetZoom,
            .mode, .write, .read, .sideBySide,
            .find, .findReplace, .findNext, .findPrevious
        ] + MarkdownFormatCommand.items.map(\.title)
    }

    private struct MenuEntry: Equatable {
        var title: String
        var commandCharacter: String?
        var modifiers: Int?
        var children: [MenuEntry]

        var flattened: [MenuEntry] { [self] + children.flatMap(\.flattened) }
    }

    /// Every bar item but the Apple menu, whose system items are slow to read.
    private func readMenuBar(pid: pid_t) throws -> [MenuEntry] {
        Self.children(of: try menuBar(pid: pid)).dropFirst().map(Self.entry(for:))
    }

    private static func entry(for item: AXUIElement) -> MenuEntry {
        MenuEntry(
            title: title(of: item),
            commandCharacter: stringValue(kAXMenuItemCmdCharAttribute, of: item),
            modifiers: intValue(kAXMenuItemCmdModifiersAttribute, of: item),
            children: children(of: item).flatMap { menu in children(of: menu).map(entry(for:)) }
        )
    }

    private static func missingTitles(_ language: AppLanguage, in bar: [MenuEntry]) -> [String] {
        let shown = Set(bar.flatMap(\.flattened).map(\.title))
        return commandKeys.map { L10n.text($0, language: language) }.filter { !shown.contains($0) }
    }

    /// Shortcuts by position, so that a command that lost or swapped its
    /// shortcut, or a menu that gained or lost an item, shows as a difference.
    private static func keyEquivalents(in bar: [MenuEntry]) -> [String] {
        bar.flatMap(\.flattened).map { "\($0.commandCharacter ?? "-")/\($0.modifiers ?? -1)" }
    }

    @discardableResult
    private func waitForCommandTitles(
        _ language: AppLanguage,
        pid: pid_t,
        timeout: TimeInterval = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [MenuEntry] {
        let deadline = Date().addingTimeInterval(timeout)
        var bar = try readMenuBar(pid: pid)
        while !Self.missingTitles(language, in: bar).isEmpty, Date() < deadline {
            usleep(200_000)
            bar = try readMenuBar(pid: pid)
        }
        XCTAssertEqual(
            Self.missingTitles(language, in: bar),
            [],
            "these \(language) command titles are not in the menu bar, which shows \(bar.map(\.title))",
            file: file,
            line: line
        )
        return bar
    }

    /// Opens the File menu and checks what it holds. This must be a case's last
    /// step: `kAXCancelAction` closes the menu without needing the app to be
    /// frontmost, but the next press after it can be lost.
    private func assertOpenedFileMenuShowsCommands(
        _ language: AppLanguage,
        pid: pid_t,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        NSRunningApplication(processIdentifier: pid)?.activate()
        let (barItem, fileMenu) = try locateFileMenu(pid: pid)
        AXUIElementSetMessagingTimeout(barItem, 2)
        AXUIElementPerformAction(barItem, kAXPressAction as CFString)
        usleep(300_000)
        defer { AXUIElementPerformAction(fileMenu, kAXCancelAction as CFString) }
        let shown = Self.children(of: fileMenu).map(Self.title(of:))
        for key in [L10nKey.new, .open, .openRecent, .save, .exportTo, .close, .print] {
            XCTAssertTrue(
                shown.contains(L10n.text(key, language: language)),
                "the opened File menu lacks the \(language) title for \(key); it shows \(shown)",
                file: file,
                line: line
            )
        }
    }

    /// The File menu is the one holding ⌘O; titles are localized ("文件" / "File").
    private func locateFileMenu(pid: pid_t) throws -> (AXUIElement, AXUIElement) {
        for barItem in Self.children(of: try menuBar(pid: pid)) {
            for menu in Self.children(of: barItem)
            where Self.children(of: menu).contains(where: { Self.commandCharacter(of: $0) == "O" }) {
                return (barItem, menu)
            }
        }
        throw GuardFailure("no File menu with a ⌘O item was found through Accessibility")
    }

    private func menuBar(pid: pid_t) throws -> AXUIElement {
        let appElement = AXUIElementCreateApplication(pid)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &value) == .success,
               let menuBar = Self.element(value) {
                return menuBar
            }
            usleep(200_000)
        }
        throw GuardFailure("the app's menu bar is not readable through Accessibility")
    }

    private func menuItem(commandCharacter character: String, pid: pid_t) throws -> AXUIElement {
        for barItem in Self.children(of: try menuBar(pid: pid)) {
            for menu in Self.children(of: barItem) {
                if let item = Self.children(of: menu).first(where: { Self.commandCharacter(of: $0) == character }) {
                    return item
                }
            }
        }
        throw GuardFailure("no menu item with the ⌘\(character) key equivalent was found")
    }

    // MARK: - Driving Settings

    /// Settings… is the app menu's ⌘, item. Language is the window's first picker,
    /// and its choices are follow-system, English, then Simplified Chinese.
    private func changeLanguage(toChoice choice: Int, pid: pid_t) throws {
        let window = try settingsWindow(pid: pid)
        let picker = try XCTUnwrap(Self.firstElement(ofRole: "AXPopUpButton", in: window))
        AXUIElementSetMessagingTimeout(picker, 2)
        NSRunningApplication(processIdentifier: pid)?.activate()
        AXUIElementPerformAction(picker, kAXPressAction as CFString)
        var choices: [AXUIElement] = []
        let deadline = Date().addingTimeInterval(5)
        while choices.count != 3, Date() < deadline {
            usleep(100_000)
            choices = Self.children(of: picker).first.map(Self.children(of:)) ?? []
        }
        guard choices.count == 3 else {
            throw GuardFailure("expected three language choices, found \(choices.map(Self.title(of:)))")
        }
        AXUIElementSetMessagingTimeout(choices[choice], 1)
        AXUIElementPerformAction(choices[choice], kAXPressAction as CFString)
        try dismissRestartPrompt(pid: pid)
    }

    private func settingsWindow(pid: pid_t) throws -> AXUIElement {
        func isSettings(_ window: AXUIElement) -> Bool {
            Self.firstElement(ofRole: "AXPopUpButton", in: window) != nil
        }
        if let window = Self.windows(pid: pid).first(where: isSettings) { return window }
        let settingsItem = try menuItem(commandCharacter: ",", pid: pid)
        AXUIElementSetMessagingTimeout(settingsItem, 1)
        AXUIElementPerformAction(settingsItem, kAXPressAction as CFString)
        return try waitForWindow(pid: pid, where: isSettings)
    }

    /// The prompt's default button restarts the app, so this names "Later". Its
    /// title follows the language the app has just changed to.
    private func dismissRestartPrompt(pid: pid_t) throws {
        func laterButton(in window: AXUIElement) -> AXUIElement? {
            Self.children(of: window).first { ["稍后", "Later"].contains(Self.title(of: $0)) }
        }
        let prompt = try waitForWindow(pid: pid) { laterButton(in: $0) != nil }
        let later = try XCTUnwrap(laterButton(in: prompt))
        AXUIElementSetMessagingTimeout(later, 1)
        AXUIElementPerformAction(later, kAXPressAction as CFString)
    }

    private func closeSettings(pid: pid_t) throws {
        let window = try settingsWindow(pid: pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &value) == .success,
              let closeButton = Self.element(value) else {
            throw GuardFailure("the Settings window has no close button")
        }
        AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
        let deadline = Date().addingTimeInterval(5)
        while Self.windows(pid: pid).contains(where: { Self.firstElement(ofRole: "AXPopUpButton", in: $0) != nil }),
              Date() < deadline {
            usleep(100_000)
        }
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
        let seen = Self.windows(pid: pid).map(Self.title(of:))
        throw GuardFailure("the expected window did not appear within \(timeout)s; windows: \(seen)")
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

    private static func firstElement(ofRole role: String, in root: AXUIElement) -> AXUIElement? {
        for child in children(of: root) {
            if stringValue(kAXRoleAttribute, of: child) == role { return child }
            if let nested = firstElement(ofRole: role, in: child) { return nested }
        }
        return nil
    }

    private static func title(of element: AXUIElement) -> String {
        stringValue(kAXTitleAttribute, of: element) ?? ""
    }

    private static func commandCharacter(of element: AXUIElement) -> String? {
        stringValue(kAXMenuItemCmdCharAttribute, of: element)
    }

    private static func stringValue(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func intValue(_ attribute: String, of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Int
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
