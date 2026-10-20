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

        Self.removeGuardPreferences()
        Self.writeGuardPreferences(["MD2.RestoresWindowsOnLaunch": true])

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

    func testSystemCloseWindowsSettingSuppressesCleanSessionRestoration() throws {
        Self.writeGuardPreferences(["NSQuitAlwaysKeepsWindows": false])
        let snapshot = DocumentRecoverySnapshot(id: UUID(), text: "# saved copy", fileURL: fixtureURL,
            identity: DocumentFileIdentity(url: fixtureURL), format: MarkdownFileFormat(),
            fingerprint: DocumentFileFingerprint.current(at: fixtureURL), isDirty: false, windowFrame: nil)
        let recordURL = try seedSnapshot(snapshot)
        _ = try launchApp(arguments: [])
        let record = try waitForRecord(stage: "didFinishLaunching")
        XCTAssertTrue(record.windows.filter { $0.className == "ModeShortcutWindow" }.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL.path))
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

    func testFinderLaunchOpensOnlyRequestedDocumentAndRetainsOtherDrafts() throws {
        let records = try seedPreviousSession()
        let requested = temporaryRoot.appendingPathComponent("Requested.md")
        try "# Requested document\n\nDifferent content.\n".write(to: requested, atomically: true, encoding: .utf8)

        // NSWorkspace delivers an open-document event, just like Finder. It can
        // arrive before didFinishLaunching. Assert both stages: checking only
        // openURLs misses unrelated windows restored later during launch.
        try openIntoRunningInstance(urls: [requested])
        let app = try XCTUnwrap(launchedApps.last)
        assertOnlyDocuments([requested.lastPathComponent], in: try waitForRecord(stage: "didFinishLaunching"))
        assertOnlyDocuments([requested.lastPathComponent], in: try waitForRecord(stage: "openURLs"))
        if AXIsProcessTrusted() { try assertFocusedDocument(requested, pid: app.processIdentifier) }
        try terminate(app)
        for (url, original) in records { XCTAssertEqual(try Data(contentsOf: url), original) }

        // Deferring unrelated recovery must not discard drafts. An ordinary
        // app launch still restores the previous session, including Untitled.
        try FileManager.default.removeItem(at: healthURL)
        _ = try launchApp(arguments: [])
        assertOnlyDocuments(["Untitled.md *", fixtureURL.lastPathComponent, "Other.md", requested.lastPathComponent],
                            in: try waitForRecord(stage: "didFinishLaunching"))
    }

    func testArgumentLaunchOpensOnlyRequestedDocumentAndRetainsOtherDrafts() throws {
        let records = try seedPreviousSession()
        let requested = temporaryRoot.appendingPathComponent("Requested.md")
        try "# Requested\n".write(to: requested, atomically: true, encoding: .utf8)
        let app = try launchApp(arguments: [requested.path])
        assertOnlyDocuments([requested.lastPathComponent], in: try waitForRecord(stage: "didFinishLaunching"))
        try terminate(app)
        for (url, original) in records { XCTAssertEqual(try Data(contentsOf: url), original) }
    }

    func testFinderLaunchRestoresOnlyNewestDraftOfRequestedFile() throws {
        let previousRecords = try seedPreviousSession()
        let original = try Data(contentsOf: fixtureURL)
        let snapshot = DocumentRecoverySnapshot(id: UUID(), text: "# Unsaved requested edits\n", fileURL: fixtureURL,
            identity: DocumentFileIdentity(url: fixtureURL), format: MarkdownFileFormat(),
            fingerprint: DocumentFileFingerprint.current(at: fixtureURL), isDirty: true, windowFrame: nil)
        let recordURL = try seedSnapshot(snapshot)

        try openIntoRunningInstance(urls: [fixtureURL])
        assertOnlyDocuments([fixtureURL.lastPathComponent + " *"], in: try waitForRecord(stage: "didFinishLaunching"))
        assertOnlyDocuments([fixtureURL.lastPathComponent + " *"], in: try waitForRecord(stage: "openURLs"))
        let restored = try JSONDecoder().decode(DocumentRecoverySnapshot.self, from: Data(contentsOf: recordURL))
        XCTAssertEqual(restored.text, snapshot.text, "explicit open must restore unsaved content, not just read the file")
        XCTAssertTrue(restored.isDirty)
        XCTAssertEqual(try Data(contentsOf: fixtureURL), original)
        for (url, data) in previousRecords { XCTAssertEqual(try Data(contentsOf: url), data) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: Self.recoveryDirectory.path).count, 4,
                       "restoring a record must not leave a temporary empty-window record behind")
    }

    func testOpeningDeferredDraftLaterFollowsRenameAndDoesNotDuplicateWindow() throws {
        let original = try Data(contentsOf: fixtureURL)
        let snapshot = DocumentRecoverySnapshot(id: UUID(), text: "# Deferred unsaved edits\n", fileURL: fixtureURL,
            identity: DocumentFileIdentity(url: fixtureURL), format: MarkdownFileFormat(),
            fingerprint: DocumentFileFingerprint.current(at: fixtureURL), isDirty: true, windowFrame: nil)
        let recordURL = try seedSnapshot(snapshot)
        let originalRecord = try Data(contentsOf: recordURL)
        let requested = temporaryRoot.appendingPathComponent("Requested.md")
        try "# Requested\n".write(to: requested, atomically: true, encoding: .utf8)
        let app = try launchApp(arguments: [requested.path])
        assertOnlyDocuments([requested.lastPathComponent], in: try waitForRecord(stage: "didFinishLaunching"))
        XCTAssertEqual(try Data(contentsOf: recordURL), originalRecord)

        let moved = temporaryRoot.appendingPathComponent("Moved.md")
        try FileManager.default.moveItem(at: fixtureURL, to: moved)
        for _ in 0..<2 {
            try FileManager.default.removeItem(at: healthURL)
            try openIntoRunningInstance(urls: [moved])
            assertOnlyDocuments([requested.lastPathComponent, moved.lastPathComponent + " *"],
                                in: try waitForRecord(stage: "openURLs"))
        }
        let restored = try JSONDecoder().decode(DocumentRecoverySnapshot.self, from: Data(contentsOf: recordURL))
        XCTAssertEqual(restored.text, snapshot.text)
        XCTAssertEqual(restored.fileURL?.resolvingSymlinksInPath(), moved.resolvingSymlinksInPath())
        XCTAssertEqual(try Data(contentsOf: moved), original)
        try terminate(app)
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), snapshot.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixtureURL.path))
    }

    func testFinderLaunchOpensAllSelectedFilesWithoutRestoringOtherWindows() throws {
        let previousRecords = try seedPreviousSession()
        let requested = temporaryRoot.appendingPathComponent("Requested.md")
        try "# Requested\n".write(to: requested, atomically: true, encoding: .utf8)
        try openIntoRunningInstance(urls: [fixtureURL, requested])
        let expected = [fixtureURL.lastPathComponent, requested.lastPathComponent]
        assertOnlyDocuments(expected, in: try waitForRecord(stage: "didFinishLaunching"))
        assertOnlyDocuments(expected, in: try waitForRecord(stage: "openURLs"))
        for (url, data) in previousRecords {
            let snapshot = try JSONDecoder().decode(DocumentRecoverySnapshot.self, from: data)
            if snapshot.fileURL != fixtureURL { XCTAssertEqual(try Data(contentsOf: url), data) }
        }
    }

    func testFinderOpensAndReopensTheRequestedDocumentAmongSeveralWindows() throws {
        try requireAccessibilityTrust()
        let app = try launchApp(arguments: [fixtureURL.path])
        _ = try waitForRecord(stage: "didFinishLaunching")
        let second = temporaryRoot.appendingPathComponent("Second.md")
        let third = temporaryRoot.appendingPathComponent("Third.md")
        try "# Second\n".write(to: second, atomically: true, encoding: .utf8)
        try "# Third\n".write(to: third, atomically: true, encoding: .utf8)

        for requested in [second, third, fixtureURL!, second] {
            try FileManager.default.removeItem(at: healthURL)
            try openIntoRunningInstance(urls: [requested])
            _ = try waitForRecord(stage: "openURLs")
            try assertFocusedDocument(requested, pid: app.processIdentifier)
        }
        try FileManager.default.removeItem(at: healthURL)
        try reopenRunningInstance()
        _ = try waitForRecord(stage: "reopen")
        try assertFocusedDocument(second, pid: app.processIdentifier)
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "# Second\n")
        XCTAssertEqual(try String(contentsOf: third, encoding: .utf8), "# Third\n")
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

    /// The reported four-window reproduction: one untitled draft and two
    /// previous files, followed by a cold launch for an unrelated fourth file.
    private func seedPreviousSession() throws -> [URL: Data] {
        let other = temporaryRoot.appendingPathComponent("Other.md")
        try "# Other\n".write(to: other, atomically: true, encoding: .utf8)
        var records: [URL: Data] = [:]
        for url in [nil, fixtureURL, other] as [URL?] {
            let snapshot = DocumentRecoverySnapshot(id: UUID(),
                text: try url.map { try String(contentsOf: $0, encoding: .utf8) } ?? "未命名草稿 🚀",
                fileURL: url, identity: url.map { DocumentFileIdentity(url: $0) }, format: MarkdownFileFormat(),
                fingerprint: url.flatMap { DocumentFileFingerprint.current(at: $0) }, isDirty: url == nil, windowFrame: nil)
            let recordURL = try seedSnapshot(snapshot)
            records[recordURL] = try Data(contentsOf: recordURL)
        }
        return records
    }

    @discardableResult
    private func seedSnapshot(_ snapshot: DocumentRecoverySnapshot) throws -> URL {
        try FileManager.default.createDirectory(at: Self.recoveryDirectory, withIntermediateDirectories: true)
        let url = Self.recoveryDirectory.appendingPathComponent("\(snapshot.id.uuidString).json")
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        return url
    }

    private func assertOnlyDocuments(_ titles: [String], in record: LaunchHealthReporter.Record,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let documents = record.windows.filter { $0.className == "ModeShortcutWindow" }
        XCTAssertEqual(documents.map(\.title).sorted(), titles.sorted(),
                       "unexpected document windows at \(record.stage): \(documents)", file: file, line: line)
        XCTAssertTrue(documents.contains(where: \.isVisible), "the requested document must be visible", file: file, line: line)
    }

    func testQuitAndRelaunchRestoresDocumentWithoutDuplicateArgumentWindow() throws {
        let app = try launchApp(arguments: [fixtureURL.path])
        assertDocumentWindowPresent(in: try waitForRecord(stage: "didFinishLaunching"))
        try terminate(app)
        try FileManager.default.removeItem(at: healthURL)
        _ = try launchApp(arguments: [fixtureURL.path])
        let record = try waitForRecord(stage: "didFinishLaunching")
        XCTAssertEqual(record.windows.filter { $0.isVisible && $0.title.contains(fixtureURL.lastPathComponent) }.count, 1)
        try assertNoSettingsWindow(in: record)
    }

    func testUntitledRecoverySurvivesForcedTerminationAndRelaunch() throws {
        // Seed the durable record produced by DocumentStore's independently
        // tested throttled writer; then exercise two real application launches.
        let snapshot = DocumentRecoverySnapshot(id: UUID(), text: "未命名草稿 🚀", fileURL: nil,
            identity: nil, format: MarkdownFileFormat(), fingerprint: nil,
            isDirty: true, windowFrame: "100 100 980 680 0 0 1920 1080 ")
        try FileManager.default.createDirectory(at: Self.recoveryDirectory, withIntermediateDirectories: true)
        let recordURL = Self.recoveryDirectory.appendingPathComponent("\(snapshot.id.uuidString).json")
        try JSONEncoder().encode(snapshot).write(to: recordURL, options: .atomic)
        let app = try launchApp(arguments: [])
        let first = try waitForRecord(stage: "didFinishLaunching")
        XCTAssertEqual(first.windows.filter { $0.isVisible && $0.title == "Untitled.md *" }.count, 1)
        app.forceTerminate()
        let deadline = Date().addingTimeInterval(10)
        while Self.isProcessAlive(app), Date() < deadline { usleep(100_000) }
        XCTAssertFalse(Self.isProcessAlive(app))
        try FileManager.default.removeItem(at: healthURL)
        let relaunched = try launchApp(arguments: [])
        let second = try waitForRecord(stage: "didFinishLaunching")
        XCTAssertEqual(second.windows.filter { $0.isVisible && $0.title == "Untitled.md *" }.count, 1)
        let restored = try JSONDecoder().decode(DocumentRecoverySnapshot.self, from: Data(contentsOf: recordURL))
        XCTAssertEqual(restored.text, snapshot.text)
        XCTAssertTrue(restored.isDirty)
        try assertNoSettingsWindow(in: second)
        // Normal Quit preserves an untitled draft without requiring a destination.
        try terminate(relaunched)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordURL.path))
    }

    func testTwoRecoveryDraftsForOneFileKeepBothTexts() throws {
        try FileManager.default.createDirectory(at: Self.recoveryDirectory, withIntermediateDirectories: true)
        for (index, text) in ["draft A", "draft B"].enumerated() {
            var snapshot = DocumentRecoverySnapshot(id: UUID(), text: text, fileURL: fixtureURL,
                identity: DocumentFileIdentity(url: fixtureURL), format: MarkdownFileFormat(),
                fingerprint: DocumentFileFingerprint.current(at: fixtureURL), isDirty: true, windowFrame: nil)
            snapshot.updatedAt = Date(timeIntervalSince1970: Double(index))
            try JSONEncoder().encode(snapshot).write(to: Self.recoveryDirectory
                .appendingPathComponent("\(snapshot.id.uuidString).json"), options: .atomic)
        }
        let app = try launchApp(arguments: [])
        let record = try waitForRecord(stage: "didFinishLaunching")
        XCTAssertEqual(record.windows.filter { $0.isVisible && $0.title.contains(fixtureURL.lastPathComponent) }.count, 1)
        XCTAssertEqual(record.windows.filter { $0.isVisible && $0.title == "Untitled.md *" }.count, 1)
        try terminate(app)
        let snapshots = try FileManager.default.contentsOfDirectory(at: Self.recoveryDirectory,
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.map {
                try JSONDecoder().decode(DocumentRecoverySnapshot.self, from: Data(contentsOf: $0))
            }
        XCTAssertEqual(try String(contentsOf: fixtureURL, encoding: .utf8), "draft A")
        XCTAssertEqual(snapshots.filter { $0.fileURL != nil && !$0.isDirty && $0.text.isEmpty }.count, 1,
                       "the saved copy stays in its file, without a second plaintext recovery copy")
        XCTAssertEqual(snapshots.filter { $0.fileURL == nil && $0.isDirty }.map(\.text), ["draft B"])
    }

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

    // MARK: - Evidence

    private func assertFocusedDocument(_ url: URL, pid: pid_t, file: StaticString = #filePath, line: UInt = #line) throws {
        // Include the early activation retries; asserting only that a window
        // exists misses the old document being brought back in front of it.
        usleep(1_500_000)
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        XCTAssertEqual(AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value), .success,
                       file: file, line: line)
        let focused = try XCTUnwrap(Self.element(value), file: file, line: line)
        XCTAssertEqual(Self.title(of: focused), url.lastPathComponent, "the opened document must remain in front",
                       file: file, line: line)
    }

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

    /// Moves within the visible screen and waits for frame autosave to settle.
    /// Accessibility permits an off-screen position that AppKit clamps only on
    /// reopening; that would test screen constraints instead of frame restoration.
    private func moveWindow(titled title: String, pid: pid_t, by delta: CGPoint) throws -> CGRect {
        guard let window = Self.window(titled: title, pid: pid),
              let current = Self.windowFrame(titled: title, pid: pid) else {
            throw GuardFailure("no window titled '\(title)' to move")
        }

        // Accessibility coordinates start at the primary screen's top-left;
        // NSScreen uses a bottom-left origin, including for secondary displays.
        let screens = NSScreen.screens
        let primaryTop = try XCTUnwrap(screens.first).frame.maxY
        let visibleFrames = screens.map {
            CGRect(x: $0.visibleFrame.minX, y: primaryTop - $0.visibleFrame.maxY,
                   width: $0.visibleFrame.width, height: $0.visibleFrame.height)
        }
        let visible = try XCTUnwrap(visibleFrames.max { lhs, rhs in
            let left = current.intersection(lhs), right = current.intersection(rhs)
            return left.width * left.height < right.width * right.height
        })
        func shifted(_ origin: CGFloat, by delta: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
            let proposed = origin + delta
            let target = proposed >= lower && proposed <= upper ? proposed : origin - delta
            return min(max(lower, upper), max(lower, target))
        }
        var target = CGPoint(
            x: shifted(current.minX, by: delta.x, lower: visible.minX, upper: visible.maxX - current.width),
            y: shifted(current.minY, by: delta.y, lower: visible.minY, upper: visible.maxY - current.height)
        )
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
        try? FileManager.default.removeItem(at: recoveryDirectory)
    }

    private static func writeGuardPreferences(_ values: [String: Any]) {
        let defaults = UserDefaults(suiteName: guardBundleIdentifier)!
        defaults.setPersistentDomain(values, forName: guardBundleIdentifier)
        defaults.synchronize()
    }

    private static var recoveryDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(guardBundleIdentifier).appendingPathComponent("Document Recovery")
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
