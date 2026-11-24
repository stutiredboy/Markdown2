import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os
import XCTest

@testable import MD2App

/// Drives the native picker, sidebar, tab group, and editor in an isolated app.
final class FolderWorkflowGUITests: XCTestCase {
    @MainActor
    func testNativePreviewTabUsesItalicsUntilPinned() throws {
        try requireGUI()
        _ = NSApplication.shared
        let window = ModeShortcutWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let document = DocumentWindow(window: window, store: DocumentStore(), settings: AppSettings(),
                                      contentState: DocumentWindowContentState(),
                                      onFileBacked: { _ in }, onFileURLChanged: {})
        document.setPreview(true)
        let title = try XCTUnwrap(window.tab.attributedTitle)
        XCTAssertEqual(title.string, window.title)
        let font = try XCTUnwrap(title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.italicFontMask))
        document.setPreview(false)
        XCTAssertNil(window.tab.attributedTitle)
    }

    @MainActor
    func testOpenFolderWithoutDocumentsShowsFolderUntilFirstPreview() async throws {
        try requireGUI()
        let fixture = try FolderPreviewFixture(numberOfNotes: 2)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let app = try await FolderTestApplication.launch(in: fixture.directory, arguments: [])
        defer { app.close() }
        _ = try app.waitFor("the application menu") { app.menuBar }
        XCTAssertTrue(app.windows.isEmpty, "the fixture must start without a document window")

        let malformed = fixture.guide.deletingLastPathComponent().appending(path: "Malformed.md")
        try Data([0xef, 0xbb, 0xbf, 0xff]).write(to: malformed)
        let initialLanding = try app.chooseFolderByPath(containing: fixture.guide)
        try assertFolderLanding(initialLanding, guide: fixture.guide, app: app)
        _ = try app.menuCommand("File", "Close")
        _ = try app.menuCommand("View", "Focus Folder Browser")
        _ = try app.menuCommand("File", "Reveal in Folder Browser", enabled: false)
        _ = try app.menuCommand("File", "Save", enabled: false)

        let badResult = try app.quickFind(malformed.lastPathComponent, expecting: malformed.lastPathComponent)
        try app.openSelection(using: badResult.open)
        let errorTitle = String(format: L10n.text(.alertUndecodableFile, language: .english), malformed.lastPathComponent)
        let dismissError = try app.waitFor("the malformed Markdown error is attached to the landing window") {
            guard let sheet = app.descendant(initialLanding, matching: {
                app.attribute(kAXRoleAttribute, of: $0) as? String == kAXSheetRole
            }), app.descendant(sheet, matching: {
                app.labels($0).contains(errorTitle)
            }) != nil else { return nil }
            return app.descendant(sheet) { app.title($0) == "OK" }
        }
        try app.press(dismissError)
        try assertFolderLanding(initialLanding, guide: fixture.guide, app: app)

        try app.key(kVK_ANSI_W, flags: .maskCommand)
        _ = try app.waitFor("closing the landing leaves no document window") { app.windows.isEmpty ? app.menuBar : nil }
        let landing = try app.chooseFolderByPath(containing: fixture.guide, viaQuickOpen: true)
        try assertFolderLanding(landing, guide: fixture.guide, app: app)
        _ = try app.waitFor("Quick Open focuses search on the landing") {
            app.focusedElement.flatMap { app.identifier($0) == "folder-quick-open" ? $0 : nil }
        }

        try app.focusFiles()
        let list = try app.element("folder-file-list", in: landing)
        XCTAssertNil(app.selectedRow(in: list))
        try app.key(kVK_DownArrow)
        let preview = try app.documentWindow(fixture.guide, focused: true)
        try app.waitForTreeFocus()
        try app.waitForDocumentChrome(in: preview, title: fixture.guide.lastPathComponent, tabs: [])
        try app.waitForOneWindow(showing: preview)
        XCTAssertNil(app.descendant(preview) { app.identifier($0) == "folder-landing-prompt" })
        _ = try app.menuCommand("File", "Reveal in Folder Browser")
        _ = try app.menuCommand("File", "Save")

        try app.waitForSelection(fixture.guide, in: app.element("folder-file-list", in: preview))
        let previewEditor = try app.editor(in: preview)
        try app.focus(previewEditor)
        try app.key(kVK_ANSI_A, flags: .maskCommand)
        _ = try app.waitFor("the original preview has a source selection") {
            let selected = app.attribute(kAXSelectedTextAttribute, of: previewEditor) as? String
            return selected?.isEmpty == false ? previewEditor : nil
        }
        try app.focusFiles()
        for (key, note) in [(kVK_DownArrow, fixture.notes[0]), (kVK_DownArrow, fixture.notes[1]),
                            (kVK_UpArrow, fixture.notes[0])] {
            try app.key(key)
            let replacement = try app.documentWindow(note, focused: true)
            XCTAssertTrue(CFEqual(replacement, preview), "keyboard skimming replaces the same preview window")
            try app.waitForTreeFocus()
            try app.waitForDocumentChrome(in: replacement, title: note.lastPathComponent, tabs: [])
            try app.waitForOneWindow(showing: replacement)
            let editor = try app.editor(in: replacement)
            XCTAssertEqual(app.value(editor), try String(contentsOf: note, encoding: .utf8))
            XCTAssertEqual(app.attribute(kAXSelectedTextAttribute, of: editor) as? String ?? "", "")
        }

        try app.key(kVK_Return)
        try app.waitForEditorFocus(in: preview)
        try app.waitForDocumentChrome(in: preview, title: fixture.notes[0].lastPathComponent, tabs: [])
        try app.focusFiles()
        try app.key(kVK_DownArrow)
        let other = try app.documentWindow(fixture.notes[1], focused: true)
        let titles = Set(fixture.notes.prefix(2).map(\.lastPathComponent))
        try app.waitForDocumentChrome(in: other, title: fixture.notes[1].lastPathComponent, tabs: titles)
        try app.waitForPinned(fixture.notes[0], in: other)
        try app.waitForPreview(fixture.notes[1], in: other)
        try app.waitForOnScreenWindowCount(1)

        try app.key(kVK_ANSI_W, flags: .maskCommand)
        let remaining = try app.documentWindow(fixture.notes[0], focused: true)
        XCTAssertTrue(CFEqual(remaining, preview))
        try app.waitForDocumentChrome(in: remaining, title: fixture.notes[0].lastPathComponent, tabs: [])
        try app.waitForOneWindow(showing: remaining)
    }

    @MainActor
    func testOpenFolderReplacesAnUntouchedDocumentBeforeOpeningFirstFile() async throws {
        try requireGUI()
        let fixture = try FolderPreviewFixture(numberOfNotes: 1)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let app = try await FolderTestApplication.launch(in: fixture.directory, arguments: [])
        defer { app.close() }
        let starter = try createUntitledDocument(in: app)
        XCTAssertTrue(app.value(try app.editor(in: starter))?.hasPrefix("# Untitled\n") == true)

        let landing = try app.chooseFolderByPath(containing: fixture.guide)
        try assertFolderLanding(landing, guide: fixture.guide, app: app)

        let found = try app.quickFind(fixture.guide.lastPathComponent, expecting: fixture.guide.lastPathComponent)
        try app.openSelection(using: found.open)
        let document = try app.documentWindow(fixture.guide, focused: true)
        try app.waitForEditorFocus(in: document)
        try app.waitForOneWindow(showing: document)
        XCTAssertTrue(app.tabTitles(in: document).allSatisfy { $0 == fixture.guide.lastPathComponent })
        XCTAssertEqual(app.value(try app.editor(in: document)),
                       try String(contentsOf: fixture.guide, encoding: .utf8))
    }

    @MainActor
    func testOpenFolderPreservesAnEditedUntitledDocument() async throws {
        try requireGUI()
        let fixture = try FolderPreviewFixture(numberOfNotes: 1)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let app = try await FolderTestApplication.launch(in: fixture.directory, arguments: [])
        defer { app.close() }
        let untitled = try createUntitledDocument(in: app)
        let draft = "# Keep the untitled draft"
        let editor = try app.editor(in: untitled)
        try app.replaceEditorText(draft, in: editor)

        let workspace = try app.chooseFolderByPath(containing: fixture.guide)
        XCTAssertTrue(CFEqual(workspace, untitled))
        XCTAssertEqual(app.value(editor), draft)

        let found = try app.quickFind(fixture.guide.lastPathComponent, expecting: fixture.guide.lastPathComponent)
        try app.openSelection(using: found.open)
        let document = try app.documentWindow(fixture.guide, focused: true)
        try app.waitForEditorFocus(in: document)
        let tabs = try app.nativeTabs(in: document)
        XCTAssertEqual(tabs.count, 2)
        let draftTab = try XCTUnwrap(tabs.first { app.title($0).hasPrefix("Untitled.md") })
        try app.press(draftTab)
        _ = try app.waitFor("the original draft tab is selected") {
            app.focusedWindow.flatMap { CFEqual($0, untitled) ? $0 : nil }
        }
        XCTAssertEqual(app.value(editor), draft)
    }

    @MainActor
    private func createUntitledDocument(in app: FolderTestApplication) throws -> AXUIElement {
        // File > New and the default-launch preference both use newDocument().
        // Issue the command explicitly so the fixture does not depend on the
        // Launch Services event classifying the launch as default.
        // This command shares a SwiftUI command group with New. Its presence
        // distinguishes the app's File menu from AppKit's startup menu.
        _ = try app.menuCommand("File", "Open Folder…")
        try app.pressFileCommand("New")
        return try app.waitFor("the new untitled document") {
            app.focusedWindow.flatMap { app.title($0) == "Untitled.md" ? $0 : nil }
        }
    }

    @MainActor
    private func assertFolderLanding(_ window: AXUIElement, guide: URL, app: FolderTestApplication) throws {
        XCTAssertEqual(app.title(window), guide.deletingLastPathComponent().lastPathComponent)
        XCTAssertEqual(app.identifier(window), "folder-landing-window")
        _ = try app.element("folder-landing-prompt", in: window)
        try app.waitForOneWindow(showing: window)
        XCTAssertNil(app.descendant(window) { app.attribute(kAXRoleAttribute, of: $0) as? String == kAXTextAreaRole })
        XCTAssertTrue(app.tabTitles(in: window).allSatisfy { $0 == app.title(window) })
        XCTAssertTrue(app.recentDocumentURLs.isEmpty)
        XCTAssertTrue(try app.recoverySnapshots().isEmpty)
    }

    @MainActor
    func testFolderPickerTreeQuickOpenAndRefreshPreserveDocumentIdentity() async throws {
        try requireGUI()
        let fixture = try FolderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let app = try await FolderTestApplication.launch(in: fixture.directory, arguments: [fixture.guide.path])
        defer { app.close() }

        let original = try app.documentWindow(fixture.guide, focused: true)
        let editor = try app.editor(in: original)
        XCTAssertEqual(app.value(editor), fixture.guideText)
        let browser = try app.chooseDocumentFolder(containing: fixture.guide)
        XCTAssertTrue(CFEqual(original, browser), "Open Folder embeds its tree in the current document")
        let list = try app.element("folder-file-list", in: browser)
        _ = try app.waitFor("Notes directory in the native file tree") { app.row("Notes", in: list) }
        XCTAssertEqual(app.attribute(kAXRoleAttribute, of: list) as? String, kAXOutlineRole)
        XCTAssertNil(app.row("Details.md", in: list), "the nested file starts under a collapsed directory")
        XCTAssertNil(app.row("Escape.md", in: list))
        XCTAssertNil(app.row("Redirect", in: list))
        XCTAssertNil(app.row(".Hidden.md", in: list))

        let detailsResult = try app.quickFind("Notes/Details.md", expecting: "Details.md")
        try app.openSelection(using: detailsResult.open)
        let detailsWindow = try app.documentWindow(fixture.details, focused: true)
        try app.waitForEditorFocus(in: detailsWindow)

        let sameDetailsResult = try app.quickFind("Notes/Details.md", expecting: "Details.md")
        try app.openSelection(using: sameDetailsResult.open)
        XCTAssertTrue(CFEqual(try app.documentWindow(fixture.details, focused: true), detailsWindow))
        try app.waitForEditorFocus(in: detailsWindow)

        try app.pressFileCommand("Reveal in Folder Browser")
        try app.waitForTreeFocus()
        let detailsTree = try app.element("folder-file-list", in: detailsWindow)
        let detailsSearch = try app.element("folder-quick-open", in: detailsWindow)
        _ = try app.waitFor("Reveal clears search, expands Notes, and highlights Details in the tree") {
            guard app.value(detailsSearch) == "", app.row("Notes", in: detailsTree) != nil else { return nil }
            return app.currentFile("Details.md", in: detailsTree)
        }
        try app.waitForSelection(fixture.details, in: detailsTree)

        let guideResult = try app.quickFind("Guide Space.md", expecting: "Guide Space.md")
        try app.openSelection(using: guideResult.open)
        XCTAssertTrue(CFEqual(try app.documentWindow(fixture.guide, focused: true), original))
        try app.waitForEditorFocus(in: original)

        let draft = fixture.guideText + "\nUnsaved draft"
        try app.replaceEditorText(draft, in: editor)
        let guideAgain = try app.quickFind("Guide Space.md", expecting: "Guide Space.md")
        try app.openSelection(using: guideAgain.open)
        XCTAssertTrue(CFEqual(try app.documentWindow(fixture.guide, focused: true), original))
        try app.waitForEditorFocus(in: original)
        XCTAssertEqual(app.value(editor), draft)
        XCTAssertEqual(try String(contentsOf: fixture.guide, encoding: .utf8), fixture.guideText)
        try app.replaceEditorText(fixture.guideText, in: editor)

        let pending = try app.quickFind("Pending.md", expecting: "Pending.md")
        try FileManager.default.removeItem(at: fixture.pending)
        try FileManager.default.createSymbolicLink(at: fixture.pending, withDestinationURL: fixture.external)
        try app.key(kVK_Return)
        let status = try app.element("folder-status", in: original)
        _ = try app.waitFor("the stale file is rejected or removed from the search results") {
            guard app.row("Pending.md", in: pending.list) == nil ||
                  app.labels(status).contains(where: { $0.localizedCaseInsensitiveContains("changed on disk") })
            else { return nil }
            return status
        }
        XCTAssertFalse(app.windows.contains { app.isWindow($0, for: fixture.external) })
        XCTAssertTrue(CFEqual(try app.documentWindow(fixture.guide, focused: true), original))

        let added = fixture.folder.appendingPathComponent("Added.md")
        try "# Added externally\n".write(to: added, atomically: true, encoding: .utf8)
        try app.press(app.element("folder-refresh", in: original))
        let addedSearch = try app.element("folder-quick-open", in: original)
        let addedList = try app.element("folder-file-list", in: original)
        try app.key(kVK_ANSI_P, flags: [.maskCommand, .maskShift])
        try app.type(added.lastPathComponent)
        _ = try app.waitFor("typing immediately after Quick Open finds Added.md") {
            guard app.value(addedSearch) == added.lastPathComponent else { return nil }
            return app.row(added.lastPathComponent, in: addedList)
        }
        try app.openSelection(using: app.element("folder-open-selection", in: original))
        let addedWindow = try app.documentWindow(added, focused: true)
        let addedEditor = try app.editor(in: addedWindow)
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
        _ = try app.waitFor("external changes refresh the bounded list while the editor keeps focus") {
            guard let currentStatus = app.descendant(addedWindow, matching: { app.identifier($0) == "folder-status" }),
                  app.labels(currentStatus).contains(where: { $0.contains("Partial list") }),
                  app.focusedElement.map({ CFEqual($0, addedEditor) }) == true else { return nil }
            return currentStatus
        }
    }

    @MainActor
    func testKeyboardSkimsTenPreviewsInOneTabGroupAndReturnPins() async throws {
        try requireGUI()
        let fixture = try FolderPreviewFixture(numberOfNotes: 10)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let app = try await FolderTestApplication.launch(in: fixture.directory, arguments: [fixture.guide.path])
        defer { app.close() }

        let original = try app.chooseDocumentFolder(containing: fixture.guide)
        try app.focusFiles()
        let initialList = try app.element("folder-file-list", in: original)
        if app.selectedRow(in: initialList) == nil { try app.key(kVK_DownArrow) }
        try app.waitForSelection(fixture.guide, in: initialList)

        var active = fixture.guide
        for note in fixture.notes {
            try app.key(kVK_DownArrow)
            let window = try app.documentWindow(note, focused: true)
            try app.waitForTreeFocus()
            let list = try app.element("folder-file-list", in: window)
            try app.waitForSelection(note, in: list)
            _ = try app.waitFor("the tree highlights \(note.lastPathComponent) as the current document") {
                app.currentFile(note.lastPathComponent, in: list)
            }
            try app.waitForPreview(note, in: window)
            active = note
        }

        let last = try app.documentWindow(active, focused: true)
        XCTAssertEqual(try app.nativeTabs(in: last).count, 2, "the starter and the one preview share one tab group")
        XCTAssertEqual(app.onScreenWindowCount, 1)
        try app.key(kVK_Return)
        try app.waitForEditorFocus(in: last)
        try app.waitForPinned(active, in: last)

        let sections = try app.element("folder-sidebar-section", in: last)
        let outline = try app.waitFor("the Outline sidebar segment") {
            app.descendant(sections) { app.labels($0).contains("Outline") }
        }
        try app.press(outline)
        _ = try app.waitFor("the Outline replaces the Files tree") {
            guard app.descendant(last, matching: { app.identifier($0) == "folder-file-list" }) == nil
            else { return nil }
            return app.descendant(last) { app.labels($0).contains(active.deletingPathExtension().lastPathComponent) }
        }
        try app.press(app.element("document-sidebar-toggle", in: last))
        _ = try app.waitFor("the sidebar collapses") {
            app.descendant(last) { app.identifier($0) == "folder-sidebar-section" } == nil ? last : nil
        }

        try app.focusFiles()
        let previous = fixture.notes[fixture.notes.count - 2]
        try app.key(kVK_UpArrow)
        let freshPreview = try app.documentWindow(previous, focused: true)
        try app.waitForTreeFocus()
        try app.waitForSelection(previous, in: app.element("folder-file-list", in: freshPreview))
        try app.waitForPreview(previous, in: freshPreview)
        XCTAssertEqual(try app.nativeTabs(in: freshPreview).count, 3)
        XCTAssertEqual(app.onScreenWindowCount, 1)
    }

    @MainActor
    func testClickDoubleClickAndTypingPinWithoutLosingEdits() async throws {
        try requireGUI()
        let fixture = try FolderPreviewFixture(numberOfNotes: 3)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let app = try await FolderTestApplication.launch(in: fixture.directory, arguments: [fixture.guide.path])
        defer { app.close() }

        let original = try app.chooseDocumentFolder(containing: fixture.guide)
        let first = fixture.notes[0]
        let second = fixture.notes[1]
        let third = fixture.notes[2]
        try app.clickFolderRow(first, in: original)
        let firstWindow = try app.documentWindow(first, focused: true)
        try app.waitForTreeFocus()
        try app.waitForPreview(first, in: firstWindow)

        try app.clickFolderRow(first, in: firstWindow, count: 2)
        try app.waitForPinned(first, in: firstWindow)
        try app.clickFolderRow(second, in: firstWindow)
        let secondWindow = try app.documentWindow(second, focused: true)
        try app.waitForTreeFocus()
        try app.waitForPreview(second, in: secondWindow)

        let editor = try app.editor(in: secondWindow)
        try app.focus(editor)
        try app.waitForEditorFocus(in: secondWindow)
        let initial = try XCTUnwrap(app.value(editor))
        let draft = "# Draft in the preview"
        try app.key(kVK_ANSI_A, flags: .maskCommand)
        try app.type(draft)
        _ = try app.waitFor("native typing updates the preview source editor") { app.value(editor) == draft ? editor : nil }
        try app.waitForPinned(second, in: secondWindow)

        try app.clickFolderRow(third, in: secondWindow)
        let thirdWindow = try app.documentWindow(third, focused: true)
        try app.waitForPreview(third, in: thirdWindow)
        XCTAssertEqual(try app.nativeTabs(in: thirdWindow).count, 4)
        try app.clickFolderRow(second, in: thirdWindow)
        XCTAssertTrue(CFEqual(try app.documentWindow(second, focused: true), secondWindow))
        XCTAssertEqual(app.value(try app.editor(in: secondWindow)), draft)
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), initial)
        XCTAssertEqual(app.onScreenWindowCount, 1)
    }

    @MainActor
    func testFolderOpenReusesAStandaloneWindowWithUnsavedEdits() async throws {
        try requireGUI()
        let fixture = try FolderPreviewFixture(numberOfNotes: 1)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let app = try await FolderTestApplication.launch(in: fixture.directory, arguments: [fixture.guide.path])
        defer { app.close() }

        _ = try app.chooseDocumentFolder(containing: fixture.guide)
        let note = fixture.notes[0]
        try await app.openFileThroughWorkspace(note)
        let standalone = try app.documentWindow(note, focused: true)
        _ = try app.waitFor("the ordinary open starts outside the folder group") {
            app.onScreenWindowCount == 2 ? standalone : nil
        }
        let editor = try app.editor(in: standalone)
        let originalText = try XCTUnwrap(app.value(editor))
        let draft = "# Unsaved edits from the standalone editor"
        try app.replaceEditorText(draft, in: editor)

        let found = try app.quickFind(note.lastPathComponent, expecting: note.lastPathComponent)
        try app.openSelection(using: found.open)
        let reused = try app.documentWindow(note, focused: true)
        XCTAssertTrue(CFEqual(reused, standalone), "the existing document window joins the group")
        try app.waitForPinned(note, in: reused)
        XCTAssertEqual(try app.nativeTabs(in: reused).count, 2)
        _ = try app.waitFor("the adopted tab group settles into one on-screen window") {
            app.onScreenWindowCount == 1 ? reused : nil
        }
        XCTAssertEqual(app.value(try app.editor(in: reused)), draft)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), originalText)
    }

    @MainActor
    func testFolderIndexRefreshesForNestedChangesAndNotForFocusChanges() throws {
        try requireGUI()
        let fixture = try FolderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let root = try FolderIndex.authorize(fixture.folder)
        let scans = OSAllocatedUnfairLock(initialState: 0)
        let controller = FolderBrowserController(
            root: root,
            text: { L10n.text($0, language: .english) },
            favorites: FavoriteFoldersModel(recorder: FolderTestFavoritesRecorder()),
            onToggleFavorite: {},
            scan: { root in
                scans.withLock { $0 += 1 }
                return try FolderIndex.scan(root)
            },
            onOpen: { _, _, _ in XCTFail("Returning focus must not open a document") }
        )

        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 440),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
        controller.start()
        defer {
            controller.stop()
            window.close()
        }

        let nestedDirectory = root.url.appending(path: "Notes", directoryHint: .isDirectory)
        let original = nestedDirectory.appending(path: fixture.details.lastPathComponent)
        try waitForIndex("initial scan") { controller.canReveal(original) }
        // The watcher may still receive the batch for creating the fixture.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let initialCount = scans.withLock { $0 }
        XCTAssertGreaterThanOrEqual(initialCount, 1)
        for _ in 0..<10 {
            controller.focusQuickOpen()
            XCTAssertTrue(controller.hasQuickOpenFocus)
            controller.focusTree()
            XCTAssertTrue(controller.hasTreeFocus)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(scans.withLock { $0 }, initialCount)

        let renamed = nestedDirectory.appending(path: "Renamed.md")
        try FileManager.default.moveItem(at: original, to: renamed)
        try waitForIndex("automatic refresh of the nested rename") {
            controller.canReveal(renamed) && !controller.canReveal(original)
        }
        XCTAssertGreaterThan(scans.withLock { $0 }, initialCount)
    }

    @MainActor
    private func waitForIndex(_ reason: String, until predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard predicate() else { throw FolderTestError("Timed out waiting for \(reason)") }
    }

    private func requireGUI() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 to run the native folder workflow.")
        guard AXIsProcessTrusted() else { throw FolderTestError("Folder workflow requires Accessibility trust") }
    }
}

@MainActor
private final class FolderTestFavoritesRecorder: FavoriteFoldersRecording {
    var favoriteFolderPaths: [String] = []
    var remoteImageGrantIDs: [String: String] = [:]
}

private struct FolderPreviewFixture {
    let directory: URL
    let guide: URL
    let notes: [URL]

    init(numberOfNotes: Int) throws {
        let fm = FileManager.default
        directory = fm.temporaryDirectory.appending(path: "MD2-Previews-\(UUID())", directoryHint: .isDirectory)
        let folder = directory.appending(path: "Preview Workspace", directoryHint: .isDirectory)
        guide = folder.appending(path: "00 Guide.md")
        notes = (1...numberOfNotes).map { folder.appending(path: String(format: "%02d Note.md", $0)) }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in [guide] + notes {
                try "# \(file.deletingPathExtension().lastPathComponent)\n".write(to: file, atomically: true, encoding: .utf8)
            }
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
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
struct FolderTestApplication {
    private let process: NSRunningApplication
    private let pid: pid_t
    private let priorApplication: NSRunningApplication?
    private let bundleIdentifier: String
    private let appURL: URL
    private let accessibility: AXUIElement

    static func launch(
        in directory: URL, arguments: [String], presentationMode: EditorMode = .write,
        favoriteFolderPaths: [String] = [], systemTabbingMode: String = "manual",
        preferTabsForDocuments: Bool? = nil
    ) async throws -> Self {
        let priorApplication = NSWorkspace.shared.frontmostApplication
        let identifier = "dev.codex.md2.folder-test.\(UUID().uuidString.lowercased())"
        let appURL = directory.appendingPathComponent("Markdown2.app", isDirectory: true)
        let productURL = Bundle(for: FolderWorkflowGUITests.self).bundleURL.deletingLastPathComponent()
        try RuntimeAppBundleBuilder(bundleIdentifier: identifier)
            .build(bundleURL: appURL, executableURL: productURL.appendingPathComponent("Markdown2"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        defaults.setPersistentDomain([
            "MD2.DefaultMode": presentationMode.rawValue, "MD2.NewDocumentMode": presentationMode.rawValue,
            "MD2.Language": "english", "AppleLanguages": ["en"],
            "MD2.ShowsOutlineByDefault": false, "AppleWindowTabbingMode": systemTabbingMode,
            "MD2.RestoresWindowsOnLaunch": false, "MD2.OpensBlankDocumentOnLaunch": false
        ], forName: identifier)
        if let preferTabsForDocuments {
            defaults.set(preferTabsForDocuments, forKey: "MD2.PreferTabsForDocuments")
        }
        UserDefaultsFavoriteFoldersRecorder(defaults: defaults).favoriteFolderPaths = favoriteFolderPaths
        defaults.synchronize()
        do {
            return try await launch(at: appURL, identifier: identifier, arguments: arguments,
                                    priorApplication: priorApplication)
        } catch {
            defaults.removePersistentDomain(forName: identifier)
            throw error
        }
    }

    private static func launch(
        at appURL: URL, identifier: String, arguments: [String], priorApplication: NSRunningApplication?
    ) async throws -> Self {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.arguments = arguments
        configuration.environment = ["MARKDOWN2_DISABLE_APP_BUNDLE_BOOTSTRAP": "1"]
        let process = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        let pid = process.processIdentifier
        guard pid > 0 else { throw FolderTestError("The isolated app exited before reporting its process ID") }
        let accessibility = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(accessibility, 2)
        return Self(process: process, pid: pid, priorApplication: priorApplication,
                    bundleIdentifier: identifier, appURL: appURL, accessibility: accessibility)
    }

    func relaunch(arguments: [String] = [], favoriteFolderPaths: [String]? = nil) async throws -> Self {
        let quitRequested = process.terminate()
        guard waitForExit(timeout: 10) else {
            throw FolderTestError("The isolated app did not quit (quit requested: \(quitRequested)). Windows: \(windows.map(title))")
        }
        if let favoriteFolderPaths {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: bundleIdentifier))
            UserDefaultsFavoriteFoldersRecorder(defaults: defaults).favoriteFolderPaths = favoriteFolderPaths
            defaults.synchronize()
        }
        return try await Self.launch(at: appURL, identifier: bundleIdentifier, arguments: arguments,
                                     priorApplication: priorApplication)
    }

    private func waitForExit(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while kill(pid, 0) == 0, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return kill(pid, 0) != 0
    }

    func close() {
        if kill(pid, 0) == 0 { process.forceTerminate() }
        _ = waitForExit()
        UserDefaults(suiteName: bundleIdentifier)?.removePersistentDomain(forName: bundleIdentifier)
        let files = FileManager.default
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
        if files.fileExists(atPath: support.path) { try? files.removeItem(at: support) }
        if let priorApplication, !priorApplication.isTerminated {
            priorApplication.activate()
            let deadline = Date().addingTimeInterval(5)
            while NSWorkspace.shared.frontmostApplication?.processIdentifier != priorApplication.processIdentifier,
                  Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
    }

    func openDocument(_ url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        let receiver = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
        guard receiver.processIdentifier == pid else {
            throw FolderTestError("Opening the document reached PID \(receiver.processIdentifier), expected \(pid)")
        }
    }

    var menuBar: AXUIElement? { elementAttribute(kAXMenuBarAttribute, of: accessibility) }
    var focusedWindow: AXUIElement? { elementAttribute(kAXFocusedWindowAttribute, of: accessibility) }
    var focusedElement: AXUIElement? { elementAttribute(kAXFocusedUIElementAttribute, of: accessibility) }
    var windows: [AXUIElement] { attribute(kAXWindowsAttribute, of: accessibility) as? [AXUIElement] ?? [] }

    func activateForInput() throws {
        _ = try waitFor("the isolated app to receive keyboard input") {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return accessibility }
            process.activate()
            return nil
        }
    }

    var folderWindows: [AXUIElement] {
        windows.filter { descendant($0) { identifier($0) == "folder-file-list" } != nil }
    }

    func press(_ element: AXUIElement) throws {
        // Actions opening or closing a modal surface can finish after AX replies.
        AXUIElementSetMessagingTimeout(element, 1)
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success || result == .cannotComplete else {
            throw FolderTestError("Could not press \(labels(element)): \(result.rawValue)")
        }
    }

    func chooseDocumentFolder(containing guide: URL) throws -> AXUIElement {
        _ = try documentWindow(guide, focused: true)
        return try chooseFolder(containing: guide, navigateToPath: false)
    }

    func chooseFolderByPath(containing guide: URL, viaQuickOpen: Bool = false) throws -> AXUIElement {
        try chooseFolder(containing: guide, navigateToPath: true, viaQuickOpen: viaQuickOpen)
    }

    private func chooseFolder(
        containing guide: URL, navigateToPath: Bool, viaQuickOpen: Bool = false
    ) throws -> AXUIElement {
        if navigateToPath {
            try pressFileCommand(viaQuickOpen ? "Quick Open…" : "Open Folder…")
        } else {
            try key(kVK_ANSI_O, flags: [.maskCommand, .maskShift])
        }
        let picker = try waitFor("the Open Folder picker") { windows.first { title($0).hasPrefix("Open Folder") } }
        if navigateToPath {
            // AppKit's remote picker services Go to Folder outside the app PID.
            try activateForInput()
            let previousFocus = focusedElement
            try postKey(UInt16(kVK_ANSI_G), flags: [.maskCommand, .maskShift], toWindowServer: true)
            let location = try waitFor("Go to Folder's path field") {
                if let focused = focusedElement,
                   attribute(kAXRoleAttribute, of: focused) as? String == kAXTextFieldRole,
                   previousFocus.map({ !CFEqual($0, focused) }) ?? true {
                    return focused
                }
                guard let sheet = descendant(picker, matching: { attribute(kAXRoleAttribute, of: $0) as? String == kAXSheetRole })
                else { return nil }
                return descendant(sheet) {
                    attribute(kAXRoleAttribute, of: $0) as? String == kAXTextFieldRole && pickerFieldHasFocus($0)
                }
            }
            let path = guide.deletingLastPathComponent().path
            try enterPickerPath(path, in: location)
            try postKey(UInt16(kVK_Return), flags: [], toWindowServer: true)

            // On macOS 15 the first Return can precede the path suggestions.
            // Repeat once only if the same path field still has the exact input.
            let deadline = Date().addingTimeInterval(1.5)
            while pickerFieldHasFocus(location), value(location) == path, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            if pickerFieldHasFocus(location), value(location) == path,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                try postKey(UInt16(kVK_Return), flags: [], toWindowServer: true)
            }
            _ = try waitFor("Go to Folder dismisses its path field") {
                value(location) == nil ? picker : nil
            }
        }
        let choose = try waitFor("the Open Folder picker's enabled Open button") {
            descendant(picker) { title($0) == "Open" && (attribute(kAXEnabledAttribute, of: $0) as? Bool) == true }
        }
        try press(choose)
        return try waitForFolder(containing: guide)
    }

    private func pickerFieldHasFocus(_ field: AXUIElement) -> Bool {
        focusedElement.map { CFEqual($0, field) } == true ||
            (attribute(kAXFocusedAttribute, of: field) as? Bool) == true
    }

    private func enterPickerPath(_ path: String, in location: AXUIElement) throws {
        _ = try waitFor("the native Go to Folder field owns keyboard focus") {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  pickerFieldHasFocus(location), value(location) != nil else { return nil }
            return location
        }
        let previousPath = try XCTUnwrap(value(location))
        // Go to Folder can retain its last path. In that case no edit is
        // needed to submit this test's destination.
        guard previousPath != path else { return }

        func canSet(_ name: String) -> Bool {
            var settable = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(location, name as CFString, &settable) == .success
                && settable.boolValue
        }
        let canSelect = canSet(kAXSelectedTextRangeAttribute)
        let canReplace = canSet(kAXSelectedTextAttribute)
        if !previousPath.isEmpty {
            if canSelect {
                var range = CFRange(location: 0, length: previousPath.utf16.count)
                try set(kAXSelectedTextRangeAttribute, to: XCTUnwrap(AXValueCreate(.cfRange, &range)), on: location)
            } else {
                try postKey(UInt16(kVK_ANSI_A), flags: .maskCommand, toWindowServer: true)
            }
            _ = try waitFor("the native picker selected its previous path") {
                guard pickerFieldHasFocus(location),
                      (attribute(kAXSelectedTextAttribute, of: location) as? String) == previousPath else { return nil }
                return location
            }
        }
        if canReplace {
            try set(kAXSelectedTextAttribute, to: path as CFString, on: location)
            try waitForPickerPath(path, in: location)
        } else {
            try pastePickerPath(path, in: location)
        }
    }

    private func pastePickerPath(_ path: String, in location: AXUIElement) throws {
        let board = NSPasteboard.general
        let saved = board.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        var writtenChangeCount = board.clearContents()
        defer {
            if board.changeCount == writtenChangeCount {
                board.clearContents()
                if !saved.isEmpty {
                    board.writeObjects(saved.map { entries in
                        let item = NSPasteboardItem()
                        for (type, data) in entries { item.setData(data, forType: type) }
                        return item
                    })
                }
            }
        }
        guard board.setString(path, forType: .string) else {
            throw FolderTestError("Could not put the folder path on the pasteboard")
        }
        writtenChangeCount = board.changeCount
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              pickerFieldHasFocus(location) else {
            throw FolderTestError("The Go to Folder field lost focus before paste")
        }
        try postKey(UInt16(kVK_ANSI_V), flags: .maskCommand, toWindowServer: true)
        try waitForPickerPath(path, in: location)
    }

    private func waitForPickerPath(_ path: String, in location: AXUIElement) throws {
        _ = try waitFor("the picker has received the complete folder path") {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let field = focusedElement ?? (pickerFieldHasFocus(location) ? location : nil),
                  attribute(kAXRoleAttribute, of: field) as? String == kAXTextFieldRole,
                  value(field) == path else { return nil }
            return field
        }
    }

    var recentDocumentURLs: [URL] {
        guard let defaults = UserDefaults(suiteName: bundleIdentifier) else { return [] }
        return SystemRecentDocumentsRecorder(defaults: defaults).recentDocumentURLs
    }

    func recoverySnapshots() throws -> [DocumentRecoverySnapshot] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appending(path: bundleIdentifier).appending(path: "Document Recovery")
        return try DocumentRecoveryRepository(directory: directory).load()
    }

    func waitForFolder(containing guide: URL) throws -> AXUIElement {
        let folder = guide.deletingLastPathComponent()
        let parent = folder.deletingLastPathComponent().lastPathComponent
        let expectedSuffix = "/\(parent)/\(folder.lastPathComponent)"
        return try waitFor("a folder sidebar at \(expectedSuffix) containing \(guide.lastPathComponent)") {
            [focusedWindow].compactMap { $0 }.first { window in
                guard let path = descendant(window, matching: { identifier($0) == "folder-root-path" }),
                      labels(path).contains(where: { $0.hasSuffix(expectedSuffix) }),
                      let list = descendant(window, matching: { identifier($0) == "folder-file-list" }) else { return false }
                return row(guide.lastPathComponent, in: list) != nil
            }
        }
    }

    func frame(of element: AXUIElement) throws -> CGRect {
        func geometry(_ name: String) throws -> AXValue {
            let value = try XCTUnwrap(attribute(name, of: element))
            guard CFGetTypeID(value) == AXValueGetTypeID() else {
                throw FolderTestError("No geometry in \(name) for \(labels(element))")
            }
            return value as! AXValue
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        XCTAssertTrue(AXValueGetValue(try geometry(kAXPositionAttribute), .cgPoint, &origin))
        XCTAssertTrue(AXValueGetValue(try geometry(kAXSizeAttribute), .cgSize, &size))
        return CGRect(origin: origin, size: size)
    }

    func openFileThroughWorkspace(_ url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let application = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
        XCTAssertEqual(application.processIdentifier, pid)
    }

    func documentWindow(_ url: URL, focused: Bool = false) throws -> AXUIElement {
        try waitFor("\(focused ? "focused " : "")document \(url.lastPathComponent)") {
            let candidates = focused ? [focusedWindow].compactMap { $0 } : windows
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

    var onScreenWindowCount: Int {
        let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return visible.filter { window in
            window[kCGWindowOwnerPID as String] as? pid_t == pid &&
                window[kCGWindowLayer as String] as? Int == 0
        }.count
    }

    func editor(in window: AXUIElement) throws -> AXUIElement {
        try waitFor("native Markdown editor in \(title(window))") {
            descendant(window) { attribute(kAXRoleAttribute, of: $0) as? String == kAXTextAreaRole }
        }
    }

    func waitForEditorFocus(in window: AXUIElement) throws {
        let editor = try editor(in: window)
        _ = try waitFor("editor focus in \(title(window))") {
            focusedElement.flatMap { CFEqual($0, editor) ? $0 : nil }
        }
    }

    func waitForTreeFocus() throws {
        _ = try waitFor("keyboard focus in the active file tree") {
            guard let focused = focusedElement else { return nil }
            if identifier(focused) == "folder-file-list" { return focused }
            return elementAttribute(kAXParentAttribute, of: focused).flatMap {
                identifier($0) == "folder-file-list" ? focused : nil
            }
        }
    }

    func focusFiles() throws {
        try key(kVK_ANSI_B, flags: [.maskCommand, .maskShift])
        try waitForTreeFocus()
    }

    func quickFind(_ query: String, expecting name: String) throws -> (list: AXUIElement, open: AXUIElement) {
        if focusedElement.flatMap(identifier) != "folder-quick-open" {
            try key(kVK_ANSI_P, flags: [.maskCommand, .maskShift])
        }
        let search = try waitFor("Quick Open gives keyboard focus to the search field") {
            focusedElement.flatMap { identifier($0) == "folder-quick-open" ? $0 : nil }
        }
        let window = try XCTUnwrap(focusedWindow)
        let list = try element("folder-file-list", in: window)
        let open = try element("folder-open-selection", in: window)
        try self.search(query, field: search, list: list, expecting: name)
        return (list, open)
    }

    func pressFileCommand(_ name: String) throws {
        try pressMenuCommand("File", name)
    }

    func pressMenuCommand(_ menuName: String, _ name: String) throws {
        try press(menuCommand(menuName, name))
    }

    func pressTabBarMenuCommand(_ name: String) throws {
        let command = try waitFor("the enabled \(name) command") {
            enabledMenuCommand(name, menus: ["View", "Window"])
        }
        try press(command)
    }

    func menuCommand(_ menuName: String, _ name: String, enabled: Bool = true) throws -> AXUIElement {
        try waitFor("the \(enabled ? "enabled" : "disabled") \(menuName) → \(name) command") {
            menuItems(in: [menuName]).first {
                title($0) == name && (attribute(kAXEnabledAttribute, of: $0) as? Bool) == enabled
            }
        }
    }

    func menuItems(in path: [String]) -> [AXUIElement] {
        guard let menuBar else { return [] }
        var items = children(menuBar)
        for name in path {
            guard let item = items.first(where: { title($0) == name }),
                  let menu = children(item).first(where: { attribute(kAXRoleAttribute, of: $0) as? String == kAXMenuRole }) else {
                return []
            }
            items = children(menu)
        }
        return items
    }

    private func enabledMenuCommand(_ name: String, menus: Set<String>) -> AXUIElement? {
        guard let menuBar else { return nil }
        return children(menuBar)
            .filter { menus.contains(title($0)) }
            .compactMap { children($0).first }
            .flatMap(children)
            .first { title($0) == name && (attribute(kAXEnabledAttribute, of: $0) as? Bool) == true }
    }

    func currentFile(_ name: String, in list: AXUIElement) -> AXUIElement? {
        descendant(list) { identifier($0) == "folder-current-file" && labels($0).contains(name) }
    }

    func selectedRow(in list: AXUIElement) -> AXUIElement? {
        (attribute(kAXSelectedRowsAttribute, of: list) as? [AXUIElement])?.first
    }

    func waitForSelection(_ url: URL, in list: AXUIElement) throws {
        _ = try waitFor("selection of \(url.lastPathComponent)") {
            guard let selected = selectedRow(in: list) else { return nil }
            return row(url.lastPathComponent, in: selected)
        }
    }

    private func tabGroup(in window: AXUIElement) -> AXUIElement? {
        descendant(window) { attribute(kAXRoleAttribute, of: $0) as? String == kAXTabGroupRole }
    }

    private func tabs(in window: AXUIElement) -> [AXUIElement] {
        guard let group = tabGroup(in: window) else { return [] }
        return attribute(kAXTabsAttribute, of: group) as? [AXUIElement] ?? []
    }

    func tabTitles(in window: AXUIElement) -> [String] { tabs(in: window).map(title) }

    func waitForDocumentChrome(in window: AXUIElement, title expected: String, tabs expectedTabs: Set<String>) throws {
        // AXTitle survives hiding NSWindow.titleVisibility. AppKit separately
        // exposes the visible title bar text as AXTitleUIElement.
        _ = try waitFor("title \(expected), native tabs \(expectedTabs.sorted()), and matching title-bar visibility") {
            guard title(window) == expected else { return nil }
            let titleElement = elementAttribute(kAXTitleUIElementAttribute, of: window)
            if expectedTabs.isEmpty {
                guard tabGroup(in: window) == nil, let titleElement,
                      labels(titleElement).contains(expected) else { return nil }
            } else {
                guard Set(tabTitles(in: window)) == expectedTabs, titleElement == nil else { return nil }
            }
            return window
        }
    }

    func waitForOneWindow(showing expected: AXUIElement) throws {
        _ = try waitFor("one visible window titled \(title(expected))") {
            guard let focused = focusedWindow, CFEqual(focused, expected), windows.count == 1,
                  onScreenWindowCount == 1 else { return nil }
            return focused
        }
    }

    func waitForOnScreenWindowCount(_ count: Int) throws {
        _ = try waitFor("\(count) on-screen windows") {
            onScreenWindowCount == count ? accessibility : nil
        }
    }

    func nativeTabs(in window: AXUIElement) throws -> [AXUIElement] {
        _ = try waitFor("native document tabs in the active tab group") { tabs(in: window).first }
        return tabs(in: window)
    }

    func waitForPreview(_ url: URL, in window: AXUIElement) throws {
        try waitForTab(url, in: window, preview: true)
    }

    func waitForPinned(_ url: URL, in window: AXUIElement) throws {
        try waitForTab(url, in: window, preview: false)
    }

    private func waitForTab(_ url: URL, in window: AXUIElement, preview: Bool) throws {
        _ = try waitFor("the \(preview ? "preview" : "pinned") tab for \(url.lastPathComponent)") {
            tabs(in: window).first { tab in
                guard title(tab).contains(url.lastPathComponent) else { return false }
                let help = attribute(kAXHelpAttribute, of: tab) as? String ?? ""
                return help.localizedCaseInsensitiveContains("Preview Tab") == preview
            }
        }
    }

    func clickFolderRow(_ url: URL, in window: AXUIElement, count: Int = 1) throws {
        let list = try element("folder-file-list", in: window)
        let row = try waitFor("the clickable file row for \(url.lastPathComponent)") {
            self.row(url.lastPathComponent, in: list)
        }
        let bounds = try frame(of: row)
        XCTAssertGreaterThan(bounds.width, 0)
        XCTAssertGreaterThan(bounds.height, 0)
        let point = CGPoint(x: bounds.midX, y: bounds.midY)
        _ = try waitFor("the isolated app is frontmost before clicking a file row") {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
            return focusedWindow.flatMap { CFEqual($0, window) ? $0 : nil }
        }
        for clickNumber in 1...count {
            for kind: CGEventType in [.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: kind,
                                                  mouseCursorPosition: point, mouseButton: .left))
                event.setIntegerValueField(.mouseEventClickState, value: Int64(clickNumber))
                event.post(tap: .cghidEventTap)
            }
        }
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

    func key(_ key: Int, flags: CGEventFlags = []) throws {
        // A background app can accept PID-directed text while ignoring its menu shortcut.
        try activateForInput()
        try postKey(UInt16(key), flags: flags)
    }

    func type(_ text: String) throws {
        for character in text { try postKey(0, flags: [], text: String(character)) }
    }

    private func postKey(
        _ key: CGKeyCode, flags: CGEventFlags, text: String? = nil, toWindowServer: Bool = false
    ) throws {
        if toWindowServer, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            throw FolderTestError("The isolated picker lost foreground keyboard focus")
        }
        for down in [true, false] {
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down))
            event.flags = flags
            if let text {
                let units = Array(text.utf16)
                units.withUnsafeBufferPointer { buffer in
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                }
            }
            if toWindowServer {
                event.post(tap: .cghidEventTap)
            } else {
                event.postToPid(pid)
            }
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

    func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

struct FolderTestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
