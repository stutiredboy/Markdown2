import AppKit
import ApplicationServices
import Carbon
import XCTest

@testable import MD2App

final class ConflictComparisonGUITests: XCTestCase {
    @MainActor
    func testCompareBothPassagesSaveEditorCopyAndReloadOriginal() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 to exercise the native conflict sheet.")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Conflict-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("Draft.md")
        let copy = directory.appendingPathComponent("Draft copy.md")
        let base = "# Draft\n\nFirst paragraph.\n\nUnchanged middle.\n\nLast paragraph.\n"
        let mine = base.replacingOccurrences(of: "First paragraph.", with: "Editor rewrote the beginning.")
        let theirs = base.replacingOccurrences(of: "Last paragraph.", with: "Disk rewrote the ending.")
        let bom = Data([0xEF, 0xBB, 0xBF])
        try (bom + Data(base.utf8)).write(to: original)

        let app = try await FolderTestApplication.launch(in: directory, arguments: [original.path])
        defer { app.close() }
        let window = try app.documentWindow(original)
        let editor = try app.editor(in: window)
        try app.replaceEditorText(mine, in: editor)
        try (bom + Data(theirs.utf8)).write(to: original, options: .atomic)

        func find(_ id: String) -> AXUIElement? {
            for root in app.windows {
                if let control = app.descendant(root, matching: { app.identifier($0) == id }) { return control }
            }
            return nil
        }
        func control(_ id: String) throws -> AXUIElement {
            try app.waitFor(id) { find(id) }
        }
        func expectText(_ text: String, in id: String) throws {
            _ = try app.waitFor("\(id) displays \(text)") {
                guard let container = find(id) else { return nil }
                return app.descendant(container) { element in
                    app.labels(element).contains { $0.contains(text) }
                        && (try? app.frame(of: element).isEmpty) == false
                }
            }
        }
        func pressEnabled(_ id: String) throws {
            let button = try app.waitFor("\(id) is ready") {
                guard let button = find(id), app.attribute(kAXEnabledAttribute, of: button) as? Bool == true else { return nil }
                return button
            }
            try app.press(button)
        }
        try expectText("Editor Version", in: "conflictEditorVersion")
        try expectText("Disk Version", in: "conflictDiskVersion")
        try expectText("Editor rewrote the beginning.", in: "conflictEditorText-0")
        try expectText("First paragraph.", in: "conflictDiskText-0")
        try expectText("Last paragraph.", in: "conflictEditorText-1")
        try expectText("Disk rewrote the ending.", in: "conflictDiskText-1")

        // Stay in the comparison beyond the real five-second idle autosave deadline.
        try await Task.sleep(for: .seconds(5.25))
        XCTAssertEqual(try Data(contentsOf: original), bom + Data(theirs.utf8))
        try pressEnabled("conflictSaveEditorCopy")
        let filename = try control("conflictCopyFilename")
        XCTAssertEqual(app.value(filename), copy.lastPathComponent)
        try pressEnabled("conflictConfirmCopy")
        _ = try control("openCreatedCopy")
        XCTAssertEqual(try Data(contentsOf: original), bom + Data(theirs.utf8))
        XCTAssertEqual(try Data(contentsOf: copy), bom + Data(mine.utf8))
        XCTAssertEqual(app.value(editor), mine)

        // Saving the separate copy must leave the original decision available.
        try app.key(kVK_ANSI_S, flags: .maskCommand)
        try expectText("Disk rewrote the ending.", in: "conflictDiskText-1")
        // A second disk write after the comparison cannot be overwritten using the old consent.
        let latest = theirs.replacingOccurrences(of: "Disk rewrote the ending.", with: "Disk revised the ending again.")
        try (bom + Data(latest.utf8)).write(to: original, options: .atomic)
        try pressEnabled("conflictKeep")
        _ = try control("conflictStatus")
        try expectText("Disk revised the ending again.", in: "conflictDiskText-1")
        XCTAssertEqual(try Data(contentsOf: original), bom + Data(latest.utf8))
        try pressEnabled("conflictReload")
        _ = try app.waitFor("the original window adopts the disk version") {
            app.value(editor) == latest ? editor : nil
        }
        XCTAssertEqual(try Data(contentsOf: copy), bom + Data(mine.utf8))
        XCTAssertEqual(try Data(contentsOf: original), bom + Data(latest.utf8))
    }
}

extension ConflictComparisonGUITests {
    @MainActor
    func testMinimumWidthActionsAndLargePassagePagesInBothLanguages() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 to exercise the native conflict sheet.")
        for language in [AppLanguage.english, .zhHans] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConflictLayout-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("长稿.md")
            try "编辑前".write(to: url, atomically: true, encoding: .utf8)
            let app = try await FolderTestApplication.launch(in: directory, arguments: [url.path], language: language)
            defer { app.close() }
            let window = try app.documentWindow(url)
            try app.resize(window, toWidth: 720)
            let editor = try app.editor(in: window)
            let local = (1...90).map { "本地段落 \($0)" }.joined(separator: "\n") + "\n编辑稿结束"
            let disk = (1...90).map { "磁盘段落 \($0)" }.joined(separator: "\n") + "\n磁盘稿结束"
            try app.replaceEditorText(local, in: editor)
            try disk.write(to: url, atomically: true, encoding: .utf8)

            let sheet = try app.waitFor("comparison sheet at 720 pt") {
                app.windows.lazy.compactMap { root in
                    app.descendant(root) {
                        app.attribute(kAXRoleAttribute, of: $0) as? String == kAXSheetRole
                        && app.descendant($0, matching: { app.identifier($0) == "conflictEditorVersion" }) != nil
                    }
                }.first
            }
            let bounds = try app.frame(of: sheet)
            XCTAssertLessThanOrEqual(bounds.width, 720)
            var previousMaxX = bounds.minX
            let actions: [(String, L10nKey)] = [
                ("conflictLater", .linkedSaveLater), ("conflictSaveEditorCopy", .conflictSaveEditorCopy),
                ("conflictReload", .reloadFromDisk), ("conflictKeep", .keepMyVersion)
            ]
            for (identifier, key) in actions {
                let button = try app.waitFor("enabled \(identifier)") {
                    app.descendant(sheet) { app.identifier($0) == identifier
                        && app.attribute(kAXEnabledAttribute, of: $0) as? Bool == true }
                }
                XCTAssertTrue(app.labels(button).contains(L10n.text(key, language: language)))
                let frame = try app.frame(of: button)
                XCTAssertTrue(bounds.contains(frame))
                XCTAssertFalse(frame.isEmpty)
                XCTAssertGreaterThanOrEqual(frame.minX, previousMaxX)
                previousMaxX = frame.maxX
            }

            for (id, marker) in [("conflictEditorText-0", "编辑稿结束"), ("conflictDiskText-0", "磁盘稿结束")] {
                for firstLine in [41, 81] {
                    let next = try app.waitFor("next page for \(id)") { app.descendant(sheet) { app.identifier($0) == "\(id)-next" } }
                    try app.press(next)
                    _ = try app.waitFor("page beginning with line \(firstLine)") {
                        app.descendant(sheet) { element in
                            app.identifier(element) == id && app.labels(element).contains { $0.contains("段落 \(firstLine)\n") }
                        }
                    }
                }
                let lastPage = try XCTUnwrap(app.descendant(sheet) { app.identifier($0) == id })
                XCTAssertTrue(app.labels(lastPage).contains { $0.contains(marker) })
            }
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), disk)
        }
    }
}
