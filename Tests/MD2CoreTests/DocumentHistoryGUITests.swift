import AppKit
import SwiftUI
import XCTest
@testable import MD2App

final class DocumentHistoryGUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 to run native history sheet tests.")
    }

    @MainActor
    func testLocalHistoryAttachesOnceToItsDocumentWindow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("md2-history-gui-\(UUID())")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = directory.appendingPathComponent("Origin.md")
        let originalBytes = Data("# Sample\n".utf8)
        try originalBytes.write(to: original)
        let repository = DocumentHistoryRepository(directory: directory.appendingPathComponent("history"))
        let store = DocumentStore(historyRepository: repository, autosaveDelay: 3_600, maximumAutosaveDelay: 3_600)
        defer { store.closeDocument(discardRecovery: false) }
        store.open(original)
        await repository.flush()

        let harness = InteractionTestWindow()
        func presentedSheets() -> [NSWindow] { NSApp.windows.filter { $0.sheetParent === harness.window } }
        defer {
            for sheet in presentedSheets() { harness.window.endSheet(sheet, returnCode: .cancel) }
            harness.close()
        }
        harness.settings.language = .english
        harness.window.setContentSize(NSSize(width: 780, height: 540))
        harness.window.contentView = NSHostingView(rootView: ContentView(document: store, settings: harness.settings, onOpen: {}))
        harness.window.makeKeyAndOrderFront(nil)

        var copiesOpened = 0
        func browse() {
            DocumentHistorySheet.present(in: harness.window, store: store, settings: harness.settings,
                                         makeStore: { DocumentStore() }, onOpen: { _ in copiesOpened += 1 })
        }

        // Opening a sheet would move focus away from the composing text view.
        harness.spin(until: { store.editorSession.textView != nil })
        let editor = try XCTUnwrap(store.editorSession.textView)
        XCTAssertTrue(harness.window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        let markedRange = editor.markedRange()
        let provisional = editor.string
        XCTAssertTrue(editor.hasMarkedText())
        browse()
        XCTAssertTrue(presentedSheets().isEmpty)
        XCTAssertEqual(editor.markedRange(), markedRange)
        XCTAssertEqual(editor.string, provisional)
        XCTAssertEqual(store.text, "# Sample\n")
        XCTAssertFalse(store.isDirty)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)

        editor.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(editor.hasMarkedText())
        harness.spin(until: { store.text == "# Sample\n你好" })
        XCTAssertEqual(store.text, "# Sample\n你好")
        browse()
        let sheet = try XCTUnwrap(presentedSheets().first)
        XCTAssertEqual(sheet.title, "Local History")
        XCTAssertTrue(sheet.contentViewController?.view is NSHostingView<DocumentHistoryView>)
        browse()
        XCTAssertEqual(presentedSheets().count, 1, "a repeated command must not attach another sheet")

        harness.window.endSheet(sheet, returnCode: .cancel)
        harness.spin(until: { presentedSheets().isEmpty })
        XCTAssertTrue(presentedSheets().isEmpty)
        XCTAssertEqual(copiesOpened, 0)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
    }
}
