import AppKit
import ApplicationServices
import XCTest

@testable import MD2App

final class DocumentMenuStateGUITests: XCTestCase {
    @MainActor
    func testNativeMenusFollowTheDocumentWindow() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 to inspect the native document menus.")
        guard AXIsProcessTrusted() else { throw FolderTestError("Inspecting native menus requires Accessibility trust") }

        let files = FileManager.default
        let directory = files.temporaryDirectory.appending(path: "MD2-Document-Menus-\(UUID().uuidString)")
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        let document = directory.appending(path: "Menu Fixture.md")
        try "# Menu fixture\n\nAn ordinary document.\n".write(to: document, atomically: true, encoding: .utf8)
        let app = try await FolderTestApplication.launch(in: directory, arguments: [])
        defer { app.close() }

        try waitForCommands(app, documentActive: false)
        XCTAssertTrue(app.windows.isEmpty, "cold launch must leave the app windowless")

        try await app.openDocument(document)
        _ = try app.documentWindow(document, focused: true)
        try waitForCommands(app, documentActive: true)
        try assertMenuLayout(app)

        try app.pressFileCommand(english(.close))
        _ = try app.waitFor("closing the last document window") { app.windows.isEmpty ? app.menuBar : nil }
        try waitForCommands(app, documentActive: false)
    }

    @MainActor
    private func waitForCommands(_ app: FolderTestApplication, documentActive: Bool) throws {
        let format = english(.formatMenu)
        let mode = english(.mode)
        // Checking the AX attribute itself distinguishes a disabled item from a
        // missing command, including children of a disabled export submenu.
        let sections: [([String], [String], Bool)] = [
            (["File"], [.save, .createCopy, .historyBrowse, .exportTo, .close, .print].map(english), documentActive),
            (["File", english(.exportTo)], ["PDF", "HTML", "DOCX", "EPUB"], documentActive),
            ([format], MarkdownFormatCommand.formatItems.map { english($0.title) } + [english(.tableOperations)], documentActive),
            ([format, english(.tableOperations)], MarkdownFormatCommand.tableItems.map { english($0.title) }, documentActive),
            ([english(.paragraphMenu)], MarkdownFormatCommand.paragraphItems.map { english($0.title) }, documentActive),
            ([mode], [.write, .read, .sideBySide].map(english), documentActive),
            (["Edit"], [.find, .findReplace, .findNext, .findPrevious].map(english), documentActive),
            (["File"], [.new, .open, .openFolder].map(english), true),
            (["File"], [english(.revealInFolderBrowser)], false),
            (["View"], [english(.focusFolderBrowser)], false),
            ([mode], [english(.typewriterScrolling)], true)
        ]
        var mismatches: [String] = []
        do {
            _ = try app.waitFor("documentActive=\(documentActive) in the native menu bar") {
                mismatches = sections.flatMap { path, names, expected in
                    let items = app.menuItems(in: path)
                    return names.compactMap { name -> String? in
                        let command = items.first { app.title($0) == name }
                        let actual = command.flatMap { app.attribute(kAXEnabledAttribute, of: $0) as? Bool }
                        guard actual != expected else { return nil }
                        return "\((path + [name]).joined(separator: " → ")) expected \(expected), got \(actual.map(String.init) ?? "unreadable")"
                    }
                }
                return mismatches.isEmpty ? app.menuBar : nil
            }
        } catch {
            throw FolderTestError("\(error)\n\(mismatches.joined(separator: "\n"))")
        }
    }

    @MainActor
    private func assertMenuLayout(_ app: FolderTestApplication) throws {
        let focusTitle = english(.focusFolderBrowser)
        XCTAssertFalse(app.menuItems(in: ["File"]).map(app.title).contains(focusTitle))
        let focus = try XCTUnwrap(app.menuItems(in: ["View"]).first { app.title($0) == focusTitle })
        XCTAssertEqual((app.attribute(kAXMenuItemCmdCharAttribute, of: focus) as? String)?.lowercased(), "b")
        XCTAssertEqual(app.attribute(kAXMenuItemCmdModifiersAttribute, of: focus) as? UInt32, AXMenuItemModifiers.shift.rawValue)

        let editTitles = app.menuItems(in: ["Edit"]).map(app.title)
        let paste = try XCTUnwrap(editTitles.firstIndex(of: english(.pasteAsTable)))
        let find = try XCTUnwrap(editTitles.indices.first { $0 > paste && editTitles[$0] == english(.find) })
        XCTAssertEqual(Array(editTitles[(paste + 1)..<find]), [""], "Edit should show one separator before Find")

        let mode = english(.mode)
        for (key, character) in [(L10nKey.write, "1"), (.read, "2"), (.sideBySide, "3")] {
            let command = try app.menuCommand(mode, english(key))
            XCTAssertEqual(app.attribute(kAXMenuItemCmdCharAttribute, of: command) as? String, character)
            XCTAssertEqual(app.attribute(kAXMenuItemCmdModifiersAttribute, of: command) as? UInt32, AXMenuItemModifiers.control.rawValue)
        }
    }

    private func english(_ key: L10nKey) -> String {
        L10n.text(key, language: .english)
    }
}
