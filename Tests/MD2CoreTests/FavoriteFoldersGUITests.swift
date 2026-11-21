import AppKit
import ApplicationServices
import Carbon.HIToolbox
import XCTest

@testable import MD2App

/// Drives the real folder picker, sidebar and File menu under a fresh bundle ID
/// for each case. Relaunch keeps that domain so persistence crosses processes.
final class FavoriteFoldersGUITests: XCTestCase {
    @MainActor
    func testFavoriteMenuUpdatesLiveAndReopensTheTreeAfterRelaunch() async throws {
        try requireGUI()
        let fixture = try FavoriteFolderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let canonicalPath = try fixture.canonicalPath(of: fixture.folder)
        var app = try await FolderTestApplication.launch(in: fixture.directory, arguments: [fixture.guide.path])
        defer { app.close() }

        let fileMenu = try app.waitFor("File menu") { app.fileMenu }
        let fileCommands = app.children(fileMenu).map(app.title).filter { !$0.isEmpty }
        XCTAssertEqual(Array(fileCommands.prefix(3)), ["New", "Open...", "Open Recent"])
        let openFolder = try XCTUnwrap(fileCommands.firstIndex(of: "Open Folder…"))
        XCTAssertEqual(Array(fileCommands.dropFirst(openFolder).prefix(5)),
                       ["Open Folder…", "Quick Open…", "Focus Folder Browser", "Reveal in Folder Browser", "Favorite Folders"])
        app.assertAccessibility(try app.favoriteMenuItem("Favorite Folders"), id: "favorite-folders-menu")
        app.assertAccessibility(try app.favoriteItem("No Favorite Folders", enabled: false),
                                id: "favorite-folders-empty")
        app.assertAccessibility(try app.favoriteItem("Clear Favorite Folders", enabled: false),
                                id: "favorite-folders-clear")

        let browser = try app.chooseDocumentFolder(containing: fixture.guide)
        let star = try app.favoriteToggle(in: browser, label: "Favorite Current Folder", selected: false)
        try app.press(star)
        app.assertAccessibility(try app.favoriteItem(fixture.folder.lastPathComponent),
                                id: "favorite-folders-open-\(canonicalPath)", help: canonicalPath)
        _ = try app.favoriteToggle(in: browser, label: "Remove Current Folder from Favorites", selected: true)

        try app.press(app.favoriteItem("Remove Current Folder from Favorites"))
        _ = try app.favoriteItem("No Favorite Folders", enabled: false)
        _ = try app.favoriteToggle(in: browser, label: "Favorite Current Folder", selected: false)
        try app.press(star)
        _ = try app.favoriteItem(fixture.folder.lastPathComponent)

        app = try await app.relaunch()
        let favorite = try app.favoriteItem(fixture.folder.lastPathComponent)
        XCTAssertTrue(app.folderWindows.isEmpty, "a favorite should open only when selected")
        try app.press(favorite)
        let reopened = try app.waitForFolder(containing: fixture.guide)
        _ = try app.favoriteToggle(in: reopened, label: "Remove Current Folder from Favorites", selected: true)

        try app.changeLanguage(to: .zhHans)
        app.assertAccessibility(try app.favoriteMenuItem("收藏的文件夹"), id: "favorite-folders-menu")
        app.assertAccessibility(try app.favoriteItem(fixture.folder.lastPathComponent, menu: "收藏的文件夹"),
                                id: "favorite-folders-open-\(canonicalPath)", help: canonicalPath)
        app.assertAccessibility(try app.favoriteItem("从收藏夹移除当前文件夹", menu: "收藏的文件夹"),
                                id: "favorite-folders-current")
        _ = try app.favoriteToggle(in: reopened, label: "从收藏夹移除当前文件夹", selected: true)
        try app.assertMinimumBrowserLayout(reopened)
        try app.press(app.favoriteItem("从收藏夹移除当前文件夹", menu: "收藏的文件夹"))
        _ = try app.favoriteItem("暂无收藏的文件夹", menu: "收藏的文件夹", enabled: false)
        _ = try app.favoriteToggle(in: reopened, label: "收藏当前文件夹", selected: false)
        try app.press(app.favoriteItem("收藏当前文件夹", menu: "收藏的文件夹"))
        _ = try app.favoriteItem(fixture.folder.lastPathComponent, menu: "收藏的文件夹")
        _ = try app.favoriteItem("从收藏夹移除当前文件夹", menu: "收藏的文件夹")
        _ = try app.favoriteToggle(in: reopened, label: "从收藏夹移除当前文件夹", selected: true)

        try app.changeLanguage(to: .english)
        _ = try app.favoriteItem(fixture.folder.lastPathComponent)
        _ = try app.favoriteItem("Remove Current Folder from Favorites")
        _ = try app.favoriteToggle(in: reopened, label: "Remove Current Folder from Favorites", selected: true)
        try app.assertMinimumBrowserLayout(reopened)

        try app.press(app.favoriteItem("Clear Favorite Folders"))
        _ = try app.favoriteItem("No Favorite Folders", enabled: false)
        _ = try app.favoriteItem("Clear Favorite Folders", enabled: false)
        _ = try app.favoriteToggle(in: reopened, label: "Favorite Current Folder", selected: false)

        try app.toggleFavoriteWithKeyboard(in: reopened)
        _ = try app.favoriteItem(fixture.folder.lastPathComponent)
        _ = try app.favoriteToggle(in: reopened, label: "Remove Current Folder from Favorites", selected: true)
    }

    @MainActor
    func testUnavailableFavoriteCanBeKeptOrRemovedWithoutReplacingTheOpenFolder() async throws {
        try requireGUI()
        let fixture = try FavoriteFolderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let alternateGuide = try fixture.makeGuide(parent: "Current", name: "Working File.md")
        let alternateFolder = alternateGuide.deletingLastPathComponent()
        let alternatePath = try fixture.canonicalPath(of: alternateFolder)
        let trapGuide = try fixture.makeGuide(parent: "Outside", name: "Outside File.md")

        var app = try await FolderTestApplication.launch(in: fixture.directory, arguments: [fixture.guide.path])
        defer { app.close() }
        let original = try app.chooseDocumentFolder(containing: fixture.guide)
        try app.press(app.favoriteToggle(in: original, label: "Favorite Current Folder", selected: false))
        _ = try app.favoriteItem(fixture.folder.lastPathComponent)

        app = try await app.relaunch(arguments: [alternateGuide.path])
        let document = try app.documentWindow(alternateGuide)
        let alternate = try app.chooseDocumentFolder(containing: alternateGuide)
        try app.press(app.favoriteToggle(in: alternate, label: "Favorite Current Folder", selected: false))

        let firstTitle = "Notes — Saved"
        let secondTitle = "Notes — Current"
        try app.press(app.favoriteItem(firstTitle))
        _ = try app.waitForFolder(containing: fixture.guide)
        XCTAssertTrue(CFEqual(try app.documentWindow(alternateGuide), document))
        try app.press(app.favoriteItem(secondTitle))
        let current = try app.waitForFolder(containing: alternateGuide)
        XCTAssertEqual(app.folderWindows.count, 1)
        XCTAssertTrue(CFEqual(try app.documentWindow(alternateGuide), document))

        try FileManager.default.moveItem(at: fixture.folder, to: fixture.directory.appending(path: "Moved"))
        try app.press(app.favoriteItem(firstTitle))
        let missing = try app.unavailableFavoriteAlert(
            pathEnding: "/Saved/Notes",
            reason: "The folder was moved, deleted, or is on a volume that is currently unavailable."
        )
        let keep = try app.element("favorite-folder-keep", in: missing)
        XCTAssertEqual(app.title(keep), "Keep")
        try app.press(keep)
        try app.waitForAlertToClose(current: current)
        _ = try app.favoriteItem(firstTitle)

        try FileManager.default.createSymbolicLink(
            at: fixture.folder, withDestinationURL: trapGuide.deletingLastPathComponent()
        )
        try app.press(app.favoriteItem(firstTitle))
        let symlink = try app.unavailableFavoriteAlert(
            pathEnding: "/Saved/Notes", reason: "The saved path now points to a symbolic link or alias."
        )
        let remove = try app.element("favorite-folder-remove", in: symlink)
        XCTAssertEqual(app.title(remove), "Remove from Favorites")
        try app.press(remove)
        try app.waitForAlertToClose(current: current)
        _ = try app.favoriteItem(alternateFolder.lastPathComponent)
        XCTAssertFalse(app.favoriteTitles().contains(firstTitle), "the unavailable favorite must be removed")
        XCTAssertTrue(CFEqual(try app.documentWindow(alternateGuide), document))
        XCTAssertFalse(app.windows.contains { app.isWindow($0, for: trapGuide) })

        app.assertAccessibility(try app.favoriteItem("Remove a Favorite"), id: "favorite-folders-manage")
        let managementItem = try app.favoriteItem(alternateFolder.lastPathComponent, under: "Remove a Favorite")
        app.assertAccessibility(managementItem, id: "favorite-folders-remove-\(alternatePath)", help: alternatePath)
        try app.press(managementItem)
        _ = try app.favoriteItem("No Favorite Folders", enabled: false)
        _ = try app.favoriteToggle(in: current, label: "Favorite Current Folder", selected: false)
    }

    private func requireGUI() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 to run the native favorite folders workflow.")
        guard AXIsProcessTrusted() else {
            throw FavoriteFolderTestError("The native favorite folders workflow cannot drive another app without Accessibility trust")
        }
    }
}

private struct FavoriteFolderFixture {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "MD2-Favorites-\(UUID().uuidString)", directoryHint: .isDirectory)

    var folder: URL { directory.appending(path: "Saved/Notes", directoryHint: .isDirectory) }
    var guide: URL { folder.appending(path: "Saved File.md", directoryHint: .notDirectory) }

    init() throws {
        do {
            _ = try makeGuide(parent: "Saved", name: guide.lastPathComponent)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func makeGuide(parent: String, name: String) throws -> URL {
        let folder = directory.appending(path: "\(parent)/Notes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let guide = folder.appending(path: name, directoryHint: .notDirectory)
        try "# \(name)\n".write(to: guide, atomically: true, encoding: .utf8)
        return guide
    }

    func canonicalPath(of folder: URL) throws -> String {
        let path = try XCTUnwrap(realpath(folder.path, nil))
        defer { free(path) }
        return String(cString: path)
    }
}

@MainActor
private extension FolderTestApplication {
    var fileMenu: AXUIElement? {
        guard let menuBar else { return nil }
        // The AppKit-owned File title follows the launch language.
        let barItem = children(menuBar).first { title($0) == "File" }
        return barItem.flatMap(menu(of:))
    }

    func menu(of item: AXUIElement) -> AXUIElement? {
        children(item).first { attribute(kAXRoleAttribute, of: $0) as? String == kAXMenuRole }
    }

    func favoriteTitles(menu menuTitle: String = "Favorite Folders") -> [String] {
        favoriteItems(menu: menuTitle).map(title)
    }

    func favoriteMenuItem(_ name: String) throws -> AXUIElement {
        try waitFor("the \(name) submenu in File") {
            fileMenu.flatMap { children($0).first { title($0) == name } }
        }
    }

    func favoriteItems(menu menuTitle: String, under submenu: String? = nil) -> [AXUIElement] {
        guard let fileMenu, let item = children(fileMenu).first(where: { title($0) == menuTitle }),
              let favorites = menu(of: item) else { return [] }
        let items = children(favorites)
        guard let submenu else { return items }
        guard let manager = items.first(where: { title($0) == submenu }), let menu = menu(of: manager) else { return [] }
        return children(menu)
    }

    func favoriteItem(
        _ itemTitle: String, menu menuTitle: String = "Favorite Folders", under submenu: String? = nil,
        enabled: Bool = true
    ) throws -> AXUIElement {
        try waitFor("\(enabled ? "enabled" : "disabled") \(menuTitle) item \(itemTitle)") {
            favoriteItems(menu: menuTitle, under: submenu).first {
                title($0) == itemTitle && (attribute(kAXEnabledAttribute, of: $0) as? Bool) == enabled
            }
        }
    }

    func assertAccessibility(
        _ element: AXUIElement, id: String, help: String? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(identifier(element), id, title(element), file: file, line: line)
        if let help {
            XCTAssertEqual(attribute(kAXHelpAttribute, of: element) as? String, help, title(element), file: file, line: line)
        }
    }

    func favoriteToggle(in browser: AXUIElement, label: String, selected: Bool) throws -> AXUIElement {
        try waitFor("the star labeled '\(label)' with selection \(selected)") {
            descendant(browser) {
                identifier($0) == "folder-favorite-toggle" && labels($0).contains(label)
                    && (attribute(kAXValueAttribute, of: $0) as? NSNumber)?.boolValue == selected
            }
        }
    }

    func toggleFavoriteWithKeyboard(in browser: AXUIElement) throws {
        XCTAssertEqual(AXUIElementPerformAction(browser, kAXRaiseAction as CFString), .success)
        let search = try element("folder-quick-open", in: browser)
        try focus(search)
        _ = try waitFor("the folder search field to receive keyboard focus") {
            focusedElement.flatMap { identifier($0) == "folder-quick-open" ? $0 : nil }
        }
        try key(kVK_Tab, flags: .maskShift)
        _ = try waitFor("Shift-Tab from search to focus the favorite star") {
            focusedElement.flatMap { identifier($0) == "folder-favorite-toggle" ? $0 : nil }
        }
        try key(kVK_Space)
    }

    func changeLanguage(to language: AppLanguage) throws {
        let settings = try waitFor("Settings command") {
            guard let menuBar else { return nil }
            return children(menuBar).compactMap(menu(of:)).flatMap(children).first {
                attribute(kAXMenuItemCmdCharAttribute, of: $0) as? String == ","
            }
        }
        try press(settings)
        let window = try waitFor("the Settings window") {
            let titles = [AppLanguage.english, .zhHans].map { L10n.text(.settingsTitle, language: $0) }
            return windows.first { titles.contains(title($0)) }
        }
        let picker = try waitFor("the language picker") {
            descendant(window) { attribute(kAXRoleAttribute, of: $0) as? String == kAXPopUpButtonRole }
        }
        try press(picker)
        let choice = try waitFor("the language choice for \(language)") {
            guard let menu = menu(of: picker) else { return nil }
            let choices = children(menu)
            guard choices.count == 3 else { return nil }
            return choices[language == .english ? 1 : 2]
        }
        try press(choice)
        let later = try waitFor("the language restart prompt's Later button") {
            windows.lazy.compactMap { window in
                descendant(window) { title($0) == L10n.text(.restartLater, language: language) }
            }.first
        }
        try press(later)
        let close = try XCTUnwrap(elementAttribute(kAXCloseButtonAttribute, of: window))
        try press(close)
        _ = try waitFor("Settings to close without restarting") {
            windows.contains(where: { CFEqual($0, window) }) ? nil : fileMenu
        }
    }

    func unavailableFavoriteAlert(pathEnding: String, reason: String) throws -> AXUIElement {
        try waitFor("favorite folder alert for \(reason)") {
            windows.first { window in
                identifier(window) == "favorite-folder-unavailable"
                    && descendant(window, matching: { labels($0).contains("Favorite Folder Unavailable") }) != nil
                    && descendant(window, matching: {
                        labels($0).contains { $0.contains(pathEnding) && $0.contains(reason) }
                    }) != nil
            }
        }
    }

    func waitForAlertToClose(current: AXUIElement) throws {
        _ = try waitFor("the alert to close while leaving the existing browser") {
            guard !windows.contains(where: { identifier($0) == "favorite-folder-unavailable" }),
                  folderWindows.count == 1, let browser = folderWindows.first, CFEqual(browser, current) else { return nil }
            return browser
        }
    }

    func assertMinimumBrowserLayout(_ browser: AXUIElement) throws {
        var requested = CGSize(width: 390, height: 290)
        let size = try XCTUnwrap(AXValueCreate(.cgSize, &requested))
        XCTAssertEqual(AXUIElementSetAttributeValue(browser, kAXSizeAttribute as CFString, size), .success)
        let windowFrame = try frame(of: browser)
        let path = try frame(of: element("folder-root-path", in: browser))
        let star = try frame(of: element("folder-favorite-toggle", in: browser))
        let search = try frame(of: element("folder-quick-open", in: browser))
        XCTAssertTrue(windowFrame.contains(star))
        XCTAssertTrue(windowFrame.contains(path))
        XCTAssertGreaterThan(path.width, 0)
        XCTAssertGreaterThan(star.width, 16)
        XCTAssertFalse(star.intersects(path))
        XCTAssertFalse(star.intersects(search))
    }
}

private struct FavoriteFolderTestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
