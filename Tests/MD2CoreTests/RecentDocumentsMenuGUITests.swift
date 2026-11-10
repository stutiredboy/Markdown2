import AppKit
import ApplicationServices
import XCTest

@testable import MD2App

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
        }
        launchedApps = []

        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        Self.removeGuardPreferences()
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

    private func menuItem(commandCharacter character: String, pid: pid_t) throws -> AXUIElement {
        let appElement = AXUIElementCreateApplication(pid)
        var menuBarValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarValue) == .success,
              let menuBar = Self.element(menuBarValue) else {
            throw GuardFailure("the app's menu bar is not readable through Accessibility")
        }
        for barItem in Self.children(of: menuBar) {
            for menu in Self.children(of: barItem) {
                if let item = Self.children(of: menu).first(where: { Self.commandCharacter(of: $0) == character }) {
                    return item
                }
            }
        }
        throw GuardFailure("no menu item with the ⌘\(character) key equivalent was found")
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
