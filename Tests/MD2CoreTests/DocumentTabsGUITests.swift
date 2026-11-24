import ApplicationServices
import Carbon.HIToolbox
import XCTest

final class DocumentTabsGUITests: XCTestCase {
    @MainActor
    func testIndependentDocumentsShareOneNativeTabBarAndRestoreTheWindowTitle() async throws {
        try requireGUI()
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let app = try await FolderTestApplication.launch(
            in: fixture.directory, arguments: [fixture.first.path], systemTabbingMode: "fullscreen"
        )
        defer { app.close() }
        let initial = try app.documentWindow(fixture.first, focused: true)
        try app.waitForOneWindow(showing: initial)
        try app.waitForDocumentChrome(in: initial, title: fixture.first.lastPathComponent, tabs: [])

        try await app.openFileThroughWorkspace(fixture.second)
        let second = try app.documentWindow(fixture.second, focused: true)
        let firstPair = Set([fixture.first, fixture.second].map(\.lastPathComponent))
        try app.waitForDocumentChrome(in: second, title: fixture.second.lastPathComponent, tabs: firstPair)
        try app.waitForOnScreenWindowCount(1)

        try await app.openFileThroughWorkspace(fixture.third)
        let third = try app.documentWindow(fixture.third, focused: true)
        let allTitles = firstPair.union([fixture.third.lastPathComponent])
        try app.waitForDocumentChrome(in: third, title: fixture.third.lastPathComponent, tabs: allTitles)
        try app.waitForOnScreenWindowCount(1)

        let firstTab = try XCTUnwrap(app.nativeTabs(in: third).first { app.title($0) == fixture.first.lastPathComponent })
        try app.press(firstTab)
        let selected = try app.documentWindow(fixture.first, focused: true)
        XCTAssertTrue(CFEqual(selected, initial))
        try app.waitForDocumentChrome(in: selected, title: fixture.first.lastPathComponent, tabs: allTitles)

        try app.key(kVK_ANSI_2, flags: [.maskControl, .maskCommand])
        _ = try app.waitFor("the Read mode preview after changing modes inside a tab") {
            app.descendant(selected) { app.attribute(kAXRoleAttribute, of: $0) as? String == "AXWebArea" }
        }
        try app.waitForDocumentChrome(in: selected, title: fixture.first.lastPathComponent, tabs: allTitles)

        try app.key(kVK_ANSI_W, flags: .maskCommand)
        let remainingPair = Set([fixture.second, fixture.third].map(\.lastPathComponent))
        let survivor = try app.waitFor("a surviving tab takes focus after closing the first document") {
            app.focusedWindow.flatMap { remainingPair.contains(app.title($0)) ? $0 : nil }
        }
        let survivorTitle = app.title(survivor)
        try app.waitForDocumentChrome(in: survivor, title: survivorTitle, tabs: remainingPair)
        try app.waitForOnScreenWindowCount(1)

        try app.key(kVK_ANSI_W, flags: .maskCommand)
        let finalTitle = try XCTUnwrap(remainingPair.subtracting([survivorTitle]).first)
        let final = try app.waitFor("the last document after closing two tabs") {
            app.focusedWindow.flatMap { app.title($0) == finalTitle ? $0 : nil }
        }
        try app.waitForDocumentChrome(in: final, title: finalTitle, tabs: [])
        try app.waitForOneWindow(showing: final)

        try app.key(kVK_ANSI_N, flags: .maskCommand)
        let untitled = "Untitled.md"
        let starter = try app.waitFor("New selects an untitled document tab") {
            app.focusedWindow.flatMap { app.title($0) == untitled ? $0 : nil }
        }
        try app.waitForDocumentChrome(in: starter, title: untitled, tabs: [finalTitle, untitled])
        try await app.openFileThroughWorkspace(fixture.first)
        let reopened = try app.documentWindow(fixture.first, focused: true)
        XCTAssertTrue(CFEqual(reopened, starter), "opening a file reuses the untouched tab")
        try app.waitForDocumentChrome(in: reopened, title: fixture.first.lastPathComponent,
                                      tabs: [finalTitle, fixture.first.lastPathComponent])
        try app.waitForOnScreenWindowCount(1)
    }

    @MainActor
    func testSingleDocumentRespectsManualTabBarToggle() async throws {
        try requireGUI()
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let app = try await FolderTestApplication.launch(in: fixture.directory, arguments: [fixture.first.path])
        defer { app.close() }
        let window = try app.documentWindow(fixture.first, focused: true)
        let title = fixture.first.lastPathComponent
        try app.waitForDocumentChrome(in: window, title: title, tabs: [])

        try app.pressTabBarMenuCommand("Show Tab Bar")
        try app.waitForDocumentChrome(in: window, title: title, tabs: [title])
        try app.pressTabBarMenuCommand("Hide Tab Bar")
        try app.waitForDocumentChrome(in: window, title: title, tabs: [])
    }

    @MainActor
    func testDisablingPreferredTabsKeepsSeparateWindowsAndNativeWindowCommands() async throws {
        try requireGUI()
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let app = try await FolderTestApplication.launch(
            in: fixture.directory, arguments: [fixture.first.path], systemTabbingMode: "always",
            preferTabsForDocuments: false
        )
        defer { app.close() }
        let first = try app.documentWindow(fixture.first, focused: true)
        try app.waitForOneWindow(showing: first)
        try await app.openFileThroughWorkspace(fixture.second)
        let second = try app.documentWindow(fixture.second, focused: true)
        try app.waitForDocumentChrome(in: second, title: fixture.second.lastPathComponent, tabs: [])
        try app.waitForOnScreenWindowCount(2)

        try app.pressMenuCommand("Window", "Merge All Windows")
        let pair = Set([fixture.first, fixture.second].map(\.lastPathComponent))
        let merged = try app.waitFor("Merge All Windows puts both tabs in the active window") {
            app.focusedWindow.flatMap { Set(app.tabTitles(in: $0)) == pair ? $0 : nil }
        }
        try app.waitForDocumentChrome(in: merged, title: app.title(merged), tabs: pair)
        try app.waitForOnScreenWindowCount(1)

        try app.pressMenuCommand("Window", "Move Tab to New Window")
        for url in [fixture.first, fixture.second] {
            let separated = try app.documentWindow(url)
            try app.waitForDocumentChrome(in: separated, title: url.lastPathComponent, tabs: [])
        }
        try app.waitForOnScreenWindowCount(2)
    }

    @MainActor
    func testOpeningFolderKeepsAnExistingIndependentTabGroupSeparate() async throws {
        try requireGUI()
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let folder = fixture.directory.appending(path: "Workspace", directoryHint: .isDirectory)
        let folderNote = folder.appending(path: "Folder note.md")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "# Folder note\n".write(to: folderNote, atomically: true, encoding: .utf8)

        let app = try await FolderTestApplication.launch(
            in: fixture.directory, arguments: [fixture.first.path], systemTabbingMode: "always"
        )
        defer { app.close() }
        _ = try app.documentWindow(fixture.first, focused: true)
        try await app.openFileThroughWorkspace(fixture.second)
        let second = try app.documentWindow(fixture.second, focused: true)
        let pair = Set([fixture.first, fixture.second].map(\.lastPathComponent))
        try app.waitForDocumentChrome(in: second, title: fixture.second.lastPathComponent, tabs: pair)

        let landing = try app.chooseFolderByPath(containing: folderNote)
        XCTAssertEqual(app.identifier(landing), "folder-landing-window")
        try app.focusFiles()
        try app.key(kVK_DownArrow)
        let preview = try app.documentWindow(folderNote, focused: true)
        try app.waitForDocumentChrome(in: preview, title: folderNote.lastPathComponent, tabs: [])
        _ = try app.element("folder-file-list", in: preview)
        try app.waitForOnScreenWindowCount(2)

        try await app.openFileThroughWorkspace(fixture.third)
        let third = try app.documentWindow(fixture.third, focused: true)
        try app.waitForDocumentChrome(in: third, title: fixture.third.lastPathComponent,
                                      tabs: pair.union([fixture.third.lastPathComponent]))
        XCTAssertNil(app.descendant(third) { app.identifier($0) == "folder-file-list" })
        try app.waitForOnScreenWindowCount(2)
    }

    private func requireGUI() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 to run the native document tab tests.")
        guard AXIsProcessTrusted() else { throw FolderTestError("Document tab tests require Accessibility trust") }
    }

    private struct Fixture {
        let directory: URL
        let first: URL
        let second: URL
        let third: URL

        init() throws {
            let files = FileManager.default
            directory = files.temporaryDirectory.appending(path: "MD2-DocumentTabs-\(UUID())", directoryHint: .isDirectory)
            first = directory.appending(path: "First.md")
            second = directory.appending(path: "Second.md")
            third = directory.appending(path: "Third.md")
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                for file in [first, second, third] {
                    try "# Document body\n".write(to: file, atomically: true, encoding: .utf8)
                }
            } catch {
                try? files.removeItem(at: directory)
                throw error
            }
        }
    }
}
