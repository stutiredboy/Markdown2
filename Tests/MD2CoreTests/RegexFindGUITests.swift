import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

final class RegexFindGUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 to run interaction GUI tests.")
    }

    @MainActor
    func testRegexIsOptInAndPreviewStillSearchesLiterally() throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        let source = "cat123\n\nCat456\n\ncat[0-9]+"
        harness.store.text = source
        harness.host(ContentView(document: harness.store, settings: harness.settings, onOpen: {}))
        let editor = try XCTUnwrap(harness.store.editorSession.textView)
        try showReplace(in: harness)
        let regex = try regexToggle(in: harness)
        XCTAssertEqual(regex.state, .off)
        try harness.enterQuery("cat[0-9]+")
        let literalLocation = (source as NSString).range(of: "cat[0-9]+").location
        try wait(in: harness, "literal query highlights its metacharacters verbatim") {
            self.isHighlighted(editor, at: literalLocation) && !self.isHighlighted(editor, at: 0)
        }

        regex.performClick(nil)
        try wait(in: harness, "source regex defaults to case-insensitive matching") {
            self.isHighlighted(editor, at: 0) && self.isHighlighted(editor, at: 8)
                && !self.isHighlighted(editor, at: literalLocation)
        }
        XCTAssertEqual(regex.state, .on)

        harness.store.requestMode(.read)
        try wait(in: harness, "Read has a rendered preview") {
            editor.window == nil && !harness.descendants(WKWebView.self).isEmpty
        }
        let preview = try XCTUnwrap(harness.descendants(WKWebView.self).first)
        harness.store.requestFind(.show)
        try wait(in: harness, "preview Find has restored the query") { harness.queryField?.stringValue == "cat[0-9]+" }
        XCTAssertFalse(harness.descendants(NSButton.self).contains { $0.accessibilityIdentifier() == "findRegex" })
        try harness.waitForPage("""
            document.querySelectorAll('mark.md2-find').length === 1 &&
            document.querySelector('mark.md2-find').textContent === 'cat[0-9]+'
            """, in: preview, context: "preview interprets source regex characters literally")

        harness.store.requestMode(.write)
        try wait(in: harness, "Write restores the source regex results") {
            editor.window === harness.window && self.isHighlighted(editor, at: 8)
                && !self.isHighlighted(editor, at: literalLocation)
        }
        try showReplace(in: harness)
        XCTAssertEqual(try regexToggle(in: harness).state, .on)
    }

    @MainActor
    func testCaptureReplaceAllInFrozenSelectionIsOneUndo() throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        let selected = "😀 cat1 and Cat2"
        let original = "😀 cat0 outside\n\(selected)\n😀 cat3 outside"
        harness.store.text = original
        harness.host(ContentView(document: harness.store, settings: harness.settings, onOpen: {}))
        let editor = try XCTUnwrap(harness.store.editorSession.textView)
        XCTAssertTrue(harness.window.makeFirstResponder(editor))
        let scope = (original as NSString).range(of: selected)
        editor.setSelectedRange(scope)
        try showReplace(in: harness)
        let selectionToggle = try XCTUnwrap(harness.descendants(NSButton.self).first {
            $0.accessibilityIdentifier() == "findOnlySelection"
        })
        selectionToggle.performClick(nil)
        try wait(in: harness, "scope freezes the original UTF-16 selection") {
            harness.store.editorSession.find.range == scope
        }
        try regexToggle(in: harness).performClick(nil)
        try harness.enterQuery("(cat)([0-9])")
        let replaceAll = try replacementButton(all: true, in: harness)
        try enterReplacement("$99", in: harness)
        try wait(in: harness, "an unknown capture prevents replacement") {
            harness.store.editorSession.find.regexReplacementStatus == .invalidReplacement && !replaceAll.isEnabled
        }
        XCTAssertEqual(harness.store.text, original)
        try enterReplacement("[$2]$1/$0", in: harness)
        try wait(in: harness, "the two frozen matches can be replaced") {
            replaceAll.isEnabled && harness.store.editorSession.find.regexStatus == .ready
        }
        try harness.capture("regex-replace-all-frozen-selection")

        replaceAll.performClick(nil)
        let updated = "😀 [1]cat/cat1 and [2]Cat/Cat2"
        let expected = "😀 cat0 outside\n\(updated)\n😀 cat3 outside"
        try wait(in: harness, "capture substitutions change only the frozen range") {
            harness.store.text == expected && editor.string == expected
        }
        let updatedScope = NSRange(location: scope.location, length: (updated as NSString).length)
        XCTAssertEqual(harness.store.editorSession.find.range, updatedScope)
        XCTAssertEqual(harness.store.editorSession.find.replacementCount, 2)

        harness.store.undoManager.undo()
        XCTAssertEqual(harness.store.text, original)
        XCTAssertEqual(editor.string, original)
        XCTAssertEqual(harness.store.editorSession.find.range, scope)
        XCTAssertFalse(harness.store.undoManager.canUndo, "both substitutions are a single undoable source edit")
        harness.store.undoManager.redo()
        XCTAssertEqual(harness.store.text, expected)
        XCTAssertEqual(harness.store.editorSession.find.range, updatedScope)
    }

    @MainActor
    func testEmptyMatchesNavigateByUTF16PositionAndReplaceAllOnce() async throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        let prefix = "😀a👩‍💻"
        let original = prefix + "😀"
        harness.store.text = original
        harness.host(ContentView(document: harness.store, settings: harness.settings, onOpen: {}))
        let editor = try XCTUnwrap(harness.store.editorSession.textView)
        harness.store.requestFind(.showReplace)
        try await waitAsync("native source Find and Replace fields are mounted") {
            harness.queryField != nil && self.replacementField(in: harness) != nil
        }
        try regexToggle(in: harness).performClick(nil)
        try harness.enterQuery(#"(?=😀)|\z"#)
        let replaceAll = try replacementButton(all: true, in: harness)
        try await waitAsync("empty matches can be replaced") {
            replaceAll.isEnabled && harness.store.editorSession.find.regexStatus == .ready
        }
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0))
        for offset in [(prefix as NSString).length, (original as NSString).length, 0] {
            XCTAssertTrue(editor.performKeyEquivalent(with: harness.findKey()))
            try await waitAsync("find advances and wraps through distinct UTF-16 offsets") {
                editor.selectedRange() == NSRange(location: offset, length: 0)
            }
        }

        let find = harness.store.editorSession.find
        let initialTemplateEpoch = find.regexReplacementEpoch
        try enterReplacement("|", in: harness)
        try await waitAsync("the new template, rather than the old blank template, is validated") {
            find.regexReplacementEpoch != initialTemplateEpoch && find.regexReplacementStatus == .ready
                && replaceAll.isEnabled
        }
        replaceAll.performClick(nil)
        try await waitAsync("Replace All inserts once per original zero-length match") {
            harness.store.text == "|😀a👩‍💻|😀|"
        }
        XCTAssertEqual(harness.store.editorSession.find.replacementCount, 3)
        harness.store.undoManager.undo()
        XCTAssertEqual(harness.store.text, original)
    }

    @MainActor
    func testSingleReplaceAdvancesPastItsZeroLengthInsertion() throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        harness.store.text = "😀 then 😀"
        harness.host(ContentView(document: harness.store, settings: harness.settings, onOpen: {}))
        let editor = try XCTUnwrap(harness.store.editorSession.textView)
        try showReplace(in: harness)
        try regexToggle(in: harness).performClick(nil)
        try harness.enterQuery("(?=😀)")
        try enterReplacement("-", in: harness)
        let replace = try replacementButton(in: harness)
        try wait(in: harness, "the first empty match can be replaced") { replace.isEnabled }
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0))

        replace.performClick(nil)
        try wait(in: harness, "single Replace inserts once and advances to the next original emoji") {
            harness.store.text == "-😀 then 😀" && replace.isEnabled
                && editor.selectedRange() == NSRange(location: ("-😀 then " as NSString).length, length: 0)
        }
        replace.performClick(nil)
        try wait(in: harness, "the next click acts on a distinct match") { harness.store.text == "-😀 then -😀" }
    }

    @MainActor
    func testInvalidAndPathologicalPatternsReportFailureAndRecover() throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        let original = String(repeating: "a", count: 240) + "!\nmarker"
        harness.store.text = original
        harness.settings.language = .english
        harness.settings.newDocumentMode = .split
        harness.host(ContentView(document: harness.store, settings: harness.settings, onOpen: {}), width: 1_046)
        let split = try XCTUnwrap(harness.descendants(NSSplitView.self).first)
        split.setPosition(360, ofDividerAt: 0)
        harness.spin()
        XCTAssertEqual(try XCTUnwrap(split.subviews.first).frame.width, 360, accuracy: 1)
        let editor = try XCTUnwrap(harness.store.editorSession.textView)
        try showReplace(in: harness)
        try regexToggle(in: harness).performClick(nil)
        let replaceAll = try replacementButton(all: true, in: harness)
        let marker = (original as NSString).range(of: "marker").location

        try harness.enterQuery("marker")
        try wait(in: harness, "valid regex has an actionable match") {
            replaceAll.isEnabled && self.isHighlighted(editor, at: marker)
        }
        try harness.enterQuery("(")
        try wait(in: harness, "malformed regex has a visible, actionable error and no stale matches") {
            harness.store.editorSession.find.regexStatus == .invalidPattern
                && !replaceAll.isEnabled && !self.isHighlighted(editor, at: marker)
        }
        try harness.capture("regex-invalid-pattern")
        try harness.enterQuery("^(a+)+$")
        try wait(in: harness, "pathological regex reaches the engine work limit and leaves no actionable matches") {
            harness.store.editorSession.find.regexStatus == .workLimit
                && !replaceAll.isEnabled
        }
        try harness.capture("regex-work-limit")
        XCTAssertEqual(harness.store.text, original)
        XCTAssertTrue(harness.queryField?.currentEditor() === harness.window.firstResponder)

        try harness.enterQuery("marker")
        try wait(in: harness, "valid input recovers without closing or reopening Find") {
            replaceAll.isEnabled && self.isHighlighted(editor, at: marker)
                && harness.store.editorSession.find.regexStatus == .ready
        }
    }

    @MainActor
    func testDisablingDenseRegexClearsTheCurrentHighlight() throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        harness.store.text = String(repeating: "x ", count: 1_001)
        harness.host(ContentView(document: harness.store, settings: harness.settings, onOpen: {}))
        let editor = try XCTUnwrap(harness.store.editorSession.textView)
        try showReplace(in: harness)
        let regex = try regexToggle(in: harness)
        regex.performClick(nil)
        try harness.enterQuery("x+")
        let replaceAll = try replacementButton(all: true, in: harness)
        try wait(in: harness, "dense regex paints its current hit and exposes replacement") {
            replaceAll.isEnabled && self.isHighlighted(editor, at: 0)
        }
        XCTAssertFalse(isHighlighted(editor, at: 2), "dense result limits painting to the current hit")
        regex.performClick(nil)
        try wait(in: harness, "literal x+ has no match and leaves no stale regex highlight") {
            regex.state == .off && !replaceAll.isEnabled && !self.isHighlighted(editor, at: 0)
        }
    }

    @MainActor
    func testPendingRegexSearchDoesNotMoveTheCaretAfterEditorRefocus() throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        let source = "writing here\nneedle target\nend"
        harness.store.text = source
        harness.host(ContentView(document: harness.store, settings: harness.settings, onOpen: {}))
        let editor = try XCTUnwrap(harness.store.editorSession.textView)
        try showReplace(in: harness)
        try regexToggle(in: harness).performClick(nil)
        try harness.enterQuery("nee.le")
        try wait(in: harness, "the latest source search is pending") {
            harness.store.editorSession.find.regexStatus == .searching
        }

        XCTAssertTrue(harness.window.makeFirstResponder(editor))
        let caret = NSRange(location: 2, length: 0)
        editor.setSelectedRange(caret)
        let target = (source as NSString).range(of: "needle").location
        try wait(in: harness, "the regex match is highlighted after the source is refocused") {
            harness.store.editorSession.find.regexStatus == .ready && self.isHighlighted(editor, at: target)
        }
        XCTAssertEqual(editor.selectedRange(), caret)
        XCTAssertTrue(harness.window.firstResponder === editor)
    }

    @MainActor
    func testQueuedRegexReplaceRejectsAnUpdatedQueryBeforeUsingCaptures() throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        let original = "cat1 cat2"
        harness.store.text = original
        harness.host(ContentView(document: harness.store, settings: harness.settings, onOpen: {}))
        let session = harness.store.editorSession
        let editor = try XCTUnwrap(session.textView)
        try showReplace(in: harness)
        try regexToggle(in: harness).performClick(nil)
        try harness.enterQuery("(cat)([0-9])")
        try enterReplacement("x$1", in: harness)
        let replaceAll = try replacementButton(all: true, in: harness)
        try wait(in: harness, "both original matches are actionable") {
            replaceAll.isEnabled && self.isHighlighted(editor, at: 5)
        }

        // Hold the real native click's edit after the invocation snapshot has
        // been captured. The new query keeps the first match and caret at the
        // same location, eliminating source, scope, and selection as guards.
        let scheduler = session.scheduleFindReplacement
        defer { session.scheduleFindReplacement = scheduler }
        var queued: (@MainActor () -> Void)?
        session.scheduleFindReplacement = { queued = $0 }
        let selection = editor.selectedRange()
        replaceAll.performClick(nil)
        try wait(in: harness, "native Replace All has queued its edit") { queued != nil }
        let commit = try XCTUnwrap(queued)

        try harness.enterQuery("cat(1)")
        try wait(in: harness, "new regex has only the first match") {
            replaceAll.isEnabled && self.isHighlighted(editor, at: 0) && !self.isHighlighted(editor, at: 5)
        }
        XCTAssertEqual(editor.selectedRange(), selection)
        commit()
        XCTAssertTrue(session.find.replacementCancelled)
        XCTAssertEqual(harness.store.text, original)

        session.scheduleFindReplacement = scheduler
        replaceAll.performClick(nil)
        try wait(in: harness, "a fresh click expands the new query's capture") { harness.store.text == "x1 cat2" }
    }

    @MainActor
    func testQueuedSingleReplaceCannotFollowNavigationToASameCaretMatch() throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        harness.store.text = "a"
        harness.host(ContentView(document: harness.store, settings: harness.settings, onOpen: {}))
        let session = harness.store.editorSession
        let editor = try XCTUnwrap(session.textView)
        try showReplace(in: harness)
        try regexToggle(in: harness).performClick(nil)
        try harness.enterQuery(#"a|\z"#)
        try enterReplacement("!", in: harness)
        let replace = try replacementButton(in: harness)
        try wait(in: harness, "the nonempty match is the current replacement target") {
            replace.isEnabled && session.find.currentRegexMatch == NSRange(location: 0, length: 1)
        }

        let scheduler = session.scheduleFindReplacement
        defer { session.scheduleFindReplacement = scheduler }
        var queued: (@MainActor () -> Void)?
        session.scheduleFindReplacement = { queued = $0 }
        let selection = editor.selectedRange()
        replace.performClick(nil)
        try wait(in: harness, "the click has captured the nonempty match") { queued != nil }
        let commit = try XCTUnwrap(queued)
        XCTAssertTrue(editor.performKeyEquivalent(with: harness.findKey()))
        try wait(in: harness, "navigation reaches a different match with the same caret") {
            session.find.currentRegexMatch == NSRange(location: 1, length: 0)
        }
        XCTAssertEqual(editor.selectedRange(), selection)

        commit()
        XCTAssertEqual(session.find.regexReplacementStatus, .ready, "the stale click must not start a replacement")
        XCTAssertEqual(harness.store.text, "a")
        session.scheduleFindReplacement = scheduler
        replace.performClick(nil)
        try wait(in: harness, "a fresh click inserts at the newly selected match") { harness.store.text == "a!" }
    }

    @MainActor
    private func showReplace(in harness: InteractionTestWindow) throws {
        harness.store.requestFind(.showReplace)
        try wait(in: harness, "native source Find and Replace fields are mounted") {
            harness.queryField != nil && self.replacementField(in: harness) != nil
        }
    }

    @MainActor
    private func regexToggle(in harness: InteractionTestWindow) throws -> NSButton {
        try XCTUnwrap(harness.descendants(NSButton.self).first { $0.accessibilityIdentifier() == "findRegex" })
    }

    @MainActor
    private func replacementField(in harness: InteractionTestWindow) -> NSTextField? {
        harness.descendants(NSTextField.self).first { $0.placeholderString == harness.settings.text(.replaceWith) }
    }

    @MainActor
    private func enterReplacement(_ text: String, in harness: InteractionTestWindow) throws {
        let field = try XCTUnwrap(replacementField(in: harness))
        XCTAssertTrue(harness.window.makeFirstResponder(field))
        let fieldEditor = try XCTUnwrap(field.currentEditor())
        fieldEditor.selectAll(nil)
        fieldEditor.insertText(text)
        try wait(in: harness, "replacement field accepted the template") { field.stringValue == text }
    }

    @MainActor
    private func replacementButton(all: Bool = false, in harness: InteractionTestWindow) throws -> NSButton {
        let field = try XCTUnwrap(replacementField(in: harness))
        // Borderless SwiftUI text buttons expose no AppKit titles on macOS 15.
        let row = field.convert(field.bounds, to: nil)
        let buttons = harness.descendants(NSButton.self).filter {
            let frame = $0.convert($0.bounds, to: nil)
            return frame.midY >= row.minY && frame.midY <= row.maxY && frame.minX >= row.maxX
        }.sorted { $0.convert($0.bounds, to: nil).midX < $1.convert($1.bounds, to: nil).midX }
        XCTAssertEqual(buttons.count, 2)
        return try XCTUnwrap(all ? buttons.last : buttons.first)
    }

    @MainActor
    private func isHighlighted(_ editor: NSTextView, at offset: Int) -> Bool {
        editor.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: offset, effectiveRange: nil) != nil
    }

    @MainActor
    private func waitAsync(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try XCTUnwrap(condition() ? true : nil, description, file: file, line: line)
    }

    @MainActor
    private func wait(in harness: InteractionTestWindow, _ description: String,
                      file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) throws {
        harness.spin(until: condition)
        _ = try XCTUnwrap(condition() ? true : nil, description, file: file, line: line)
    }
}
