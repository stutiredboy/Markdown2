import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

final class SplitScrollPauseGUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Requires the native split editor and WebKit preview.")
    }

    @MainActor func testHoldingTableThroughSourceScrollAndEditThenResumingFromEditor() throws {
        let host = InteractionTestWindow()
        defer { host.close() }
        let web = try mount(in: host, settings: host.settings)
        let editor = try XCTUnwrap(host.store.editorSession.textView)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        try showTable(in: web, host: host)
        try waitForSource("Reference value", in: editor, host: host)
        let heldY = try tableY(in: web, host: host)
        XCTAssertEqual(heldY, 42, accuracy: 2)
        try toggle(in: host, paused: false)
        try observeFollows(in: web, host: host)

        // Scroll toward the earlier summary with an AppKit wheel event. Then
        // move the caret there and insert a new paragraph above the table.
        let beforeScroll = scroll.contentView.bounds.minY
        try scrollEditor(by: 450, in: host, editor: editor)
        XCTAssertLessThan(scroll.contentView.bounds.minY, beforeScroll - 30)
        host.spin()
        XCTAssertEqual(try tableY(in: web, host: host), heldY, accuracy: 1)
        let summary = (editor.string as NSString).range(of: "Draft summary.")
        XCTAssertNotEqual(summary.location, NSNotFound)
        let caret = NSRange(location: NSMaxRange(summary), length: 0)
        XCTAssertTrue(host.window.makeFirstResponder(editor))
        editor.setSelectedRange(caret)
        editor.scrollRangeToVisible(caret)
        editor.insertText("\n\nSummary updated.", replacementRange: caret)
        try host.waitForPage("document.querySelector('main').textContent.includes('Summary updated.')",
                             in: web, context: "the edited summary must render above the reference")
        XCTAssertEqual(try tableY(in: web, host: host), heldY, accuracy: 1,
                       "the visible table moved during the live render")
        XCTAssertEqual(try host.js("resumeCalls.length", web) as? Int, 0)

        let editorY = scroll.contentView.bounds.minY
        let topLine = try XCTUnwrap(MarkdownEditorView.Coordinator.topVisibleFractionalLine(in: scroll))
        try toggle(in: host, paused: true)
        try host.waitForPage("resumeCalls.length > 0 && document.querySelector('table').getBoundingClientRect().top > innerHeight",
                             in: web, context: "resume must bring the preview back to the editor")
        host.spin(for: 0.4)
        XCTAssertEqual(try host.js("resumeCalls.length", web) as? Int, 1, "one alignment per resume")
        XCTAssertEqual(try XCTUnwrap(try host.js("resumeCalls[0]", web) as? Double), topLine, accuracy: 0.01)
        XCTAssertEqual(scroll.contentView.bounds.minY, editorY, accuracy: 1)

        // A second editor scroll follows continuously, then a preview scroll
        // can drive the editor back to the table.
        let previewY = try XCTUnwrap(try host.js("scrollY", web) as? Double)
        try scrollEditor(by: -450, in: host, editor: editor)
        try host.waitForPage("resumeCalls.length > 1 && scrollY > \(previewY) + 50",
                             in: web, context: "ordinary editor-to-preview scrolling resumed")
        host.spin(for: 0.35)
        try showTable(in: web, host: host)
        try waitForSource("Reference value", in: editor, host: host)
    }

    @MainActor func testHoldingTableWhenAnEditLoadsANewPreviewEngine() throws {
        let host = InteractionTestWindow()
        defer { host.close() }
        let web = try mount(in: host, settings: host.settings)
        let editor = try XCTUnwrap(host.store.editorSession.textView)
        try showTable(in: web, host: host)
        try waitForSource("Reference value", in: editor, host: host)
        try toggle(in: host, paused: false)
        // Leave a sliver of the paragraph immediately above the table on
        // screen, then edit that very paragraph until it wraps across rows.
        let preceding = "Working notes for paragraph 71."
        _ = try host.js("""
            const preceding = Array.from(document.querySelectorAll('main > p')).find(p => p.textContent === '\(preceding)');
            window.scrollBy(0, preceding.getBoundingClientRect().top + 4);
            """, web)
        let heldY = try tableY(in: web, host: host)
        XCTAssertGreaterThan(heldY, 0)
        XCTAssertLessThan(heldY, 100)
        let precedingRange = (editor.string as NSString).range(of: preceding)
        XCTAssertNotEqual(precedingRange.location, NSNotFound)
        let end = NSRange(location: NSMaxRange(precedingRange), length: 0)
        let addition = String(repeating: " More detail about the reference.", count: 15)
        XCTAssertTrue(host.window.makeFirstResponder(editor))
        editor.setSelectedRange(end)
        editor.insertText(addition, replacementRange: end)
        try host.waitForPage("!preceding.isConnected && document.querySelector('main').textContent.includes('\(addition)')",
                             in: web, context: "the partially visible paragraph was replaced")
        XCTAssertEqual(try tableY(in: web, host: host), heldY, accuracy: 2,
                       "the table stays put even when the preceding visible paragraph changes height")
        _ = try host.js("window.beforeDiagram = true", web)

        let summary = (editor.string as NSString).range(of: "Draft summary.")
        XCTAssertNotEqual(summary.location, NSNotFound)
        let caret = NSRange(location: NSMaxRange(summary), length: 0)
        XCTAssertTrue(host.window.makeFirstResponder(editor))
        editor.setSelectedRange(caret)
        editor.scrollRangeToVisible(caret)
        editor.insertText("\n\n```mermaid\ngraph LR; A-->B;\n```", replacementRange: caret)
        try host.waitForPage("!window.beforeDiagram && !!document.querySelector('.diagram svg')",
                             in: web, context: "adding Mermaid should render a diagram in a fresh preview page")
        try host.waitForPage("Math.abs(document.querySelector('table').getBoundingClientRect().top - \(heldY)) <= 2",
                             in: web, context: "the replacement page should restore the reference")
        host.spin(for: 0.4)
        XCTAssertEqual(try tableY(in: web, host: host), heldY, accuracy: 2)
    }

    @MainActor func testEditingAndResumingBeforeAnAllowedImageFinishesLoading() throws {
        let server = try HeldPreviewImageServer()
        defer { server.stop() }
        let host = InteractionTestWindow()
        defer { host.close() }
        host.spin(until: { server.port != nil })
        let port = try XCTUnwrap(server.port)
        host.store.setRemoteImagesAllowed(true)
        let web = try mount(in: host, settings: host.settings, imageURL: "http://127.0.0.1:\(port)/held.png")
        let editor = try XCTUnwrap(host.store.editorSession.textView)
        let coordinator = try XCTUnwrap(web.navigationDelegate as? MarkdownPreviewView.Coordinator)
        host.spin(until: { server.hasRequest })
        XCTAssertTrue(server.hasRequest)
        XCTAssertTrue(web.isLoading)
        XCTAssertFalse(coordinator.isLoaded)
        try toggle(in: host, paused: false)
        try showTable(in: web, host: host)
        let heldY = try tableY(in: web, host: host)
        _ = try host.js("window.initialImage = document.querySelector('img'); true", web)

        let summary = (editor.string as NSString).range(of: "Draft summary.")
        XCTAssertNotEqual(summary.location, NSNotFound)
        let caret = NSRange(location: NSMaxRange(summary), length: 0)
        XCTAssertTrue(host.window.makeFirstResponder(editor))
        editor.setSelectedRange(caret)
        editor.scrollRangeToVisible(caret)
        editor.insertText("\n\nPending image summary.", replacementRange: caret)
        try host.waitForPage("""
            document.querySelector('main')?.textContent.includes('Pending image summary.')
                && window.initialImage === document.querySelector('img') && !initialImage.complete
            """, in: web, context: "the pending image survives an ordinary edit", requireLoaded: false)
        XCTAssertEqual(try tableY(in: web, host: host), heldY, accuracy: 1)

        // Adding the first diagram needs a fresh document. Its DOM and scroll
        // helpers are ready to use even while the same image is still pending.
        editor.insertText("\n\n```mermaid\ngraph LR; A-->B;\n```", replacementRange: editor.selectedRange())
        try host.waitForPage("""
            !window.initialImage && !!document.querySelector('.diagram')
                && document.querySelector('img')?.complete === false
                && Math.abs(document.querySelector('table').getBoundingClientRect().top - \(heldY)) <= 2
            """, in: web, context: "the replacement page restores the table before image load", requireLoaded: false)
        XCTAssertTrue(web.isLoading)
        XCTAssertFalse(coordinator.isLoaded)
        try observeFollows(in: web, host: host)
        try toggle(in: host, paused: true)
        try host.waitForPage("""
            resumeCalls.length === 1 && document.querySelector('table').getBoundingClientRect().top > innerHeight
                && document.querySelector('img')?.complete === false
            """, in: web, context: "resume aligns with the editor while the image is loading", requireLoaded: false)
        let alignedY = try XCTUnwrap(try host.js("scrollY", web) as? Double)

        server.release()
        try host.waitForPage("document.querySelector('img')?.naturalWidth === 1", in: web,
                             context: "the previously held image completed")
        XCTAssertEqual(try host.js("resumeCalls.length", web) as? Int, 1)
        XCTAssertEqual(try XCTUnwrap(try host.js("scrollY", web) as? Double), alignedY, accuracy: 2)
    }

    @MainActor func testResumingFromPreviewAndKeepingPauseLocalToOneWindow() throws {
        let first = InteractionTestWindow()
        defer { first.close() }
        let web = try mount(in: first, settings: first.settings)
        let editor = try XCTUnwrap(first.store.editorSession.textView)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        try toggle(in: first, paused: false)

        // The windows observe the same app preferences. Opening the second
        // while the first is paused must still produce a working follower.
        let other = InteractionTestWindow()
        defer { other.close() }
        let otherWeb = try mount(in: other, settings: first.settings)
        let otherEditor = try XCTUnwrap(other.store.editorSession.textView)
        XCTAssertNotNil(item(in: other, paused: false))
        try showTable(in: otherWeb, host: other)
        try waitForSource("Reference value", in: otherEditor, host: other)

        first.window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(first.window.makeFirstResponder(editor))
        let initial = scroll.contentView.bounds.minY
        try showTable(in: web, host: first)
        first.spin(for: 0.35)
        XCTAssertEqual(scroll.contentView.bounds.minY, initial, accuracy: 1,
                       "preview scrolling must leave the paused editor in place")
        let heldY = try tableY(in: web, host: first)
        try toggle(in: first, paused: true)
        try waitForSource("Reference value", in: editor, host: first)
        first.spin(for: 0.35)
        XCTAssertEqual(try tableY(in: web, host: first), heldY, accuracy: 1,
                       "the preview was the latest scroll source even with the insertion point in the editor")
    }

    @MainActor func testPausedPreviewKeepsTheCurrentFindOccurrenceWhenEditingAnEarlierMatch() throws {
        let host = InteractionTestWindow()
        defer { host.close() }
        let paragraphs = ["First Needle"] + (1...100).map { "Meeting notes \($0)" }
            + ["Second Needle"] + (1...30).map { "Footer \($0)" }
        host.store.text = paragraphs.joined(separator: "\n\n")
        let second = "Array.from(document.querySelectorAll('main p')).find(p => p.textContent === 'Second Needle')"
        let web = try mountDocument(in: host, settings: host.settings, marker: "Second Needle", ready: "!!(\(second))")
        let find = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: host.window.windowNumber, context: nil, characters: "f",
                                                  charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        XCTAssertTrue(web.performKeyEquivalent(with: find))
        host.spin(until: { host.queryField != nil })
        try host.enterQuery("Needle")
        try host.waitForPage("\(PreviewFindRanges.count) === 2 && \(PreviewFindRanges.currentIndex) === 0", in: web,
                             context: "the first of two matches is current before navigating")
        host.store.requestFind(.next)
        let highlight = "CSS.highlights.get('md2-find-current')?.values().next().value"
        let currentIsSecond = "(\(highlight))?.startContainer.parentElement.closest('p') === (\(second))"
        try host.waitForPage(currentIsSecond, in: web, context: "Find Next selected the second paragraph")
        try toggle(in: host, paused: false)
        let y = try visibleTop(of: second, in: web, host: host)
        let matchY = try visibleTop(of: highlight, in: web, host: host)

        let field = try XCTUnwrap(host.queryField)
        var owner: NSResponder? = field
        while let responder = owner, !(responder is NativeFindPaneOwner) { owner = responder.nextResponder }
        let bar = try XCTUnwrap(owner as? NativeFindBarController<PreviewFindBar>)
        try insert("Edited ", before: "First Needle", in: host)
        try host.waitForPage("""
            \(PreviewFindRanges.all)[0]?.startContainer.textContent.includes('Edited First Needle')
                && \(PreviewFindRanges.count) === 2 && (\(currentIsSecond))
            """, in: web, context: "both highlights were repainted with the second still current")
        host.spin(until: { bar.rootView.statusText == "2 of 2" })
        XCTAssertEqual(bar.rootView.statusText, "2 of 2")
        XCTAssertEqual(try visibleTop(of: second, in: web, host: host), y, accuracy: 2)
        let editedMatchY = try visibleTop(of: highlight, in: web, host: host)
        XCTAssertEqual(editedMatchY, matchY, accuracy: 2)

        // The same occurrence changes index when an earlier match is added.
        try insert("New Needle. ", before: "Edited First Needle", in: host)
        try host.waitForPage("\(PreviewFindRanges.count) === 3 && \(PreviewFindRanges.currentIndex) === 2 && (\(currentIsSecond))",
                             in: web, context: "the original current result is now third")
        host.spin(until: { bar.rootView.statusText == "3 of 3" })
        XCTAssertEqual(bar.rootView.statusText, "3 of 3")
        XCTAssertEqual(try visibleTop(of: second, in: web, host: host), y, accuracy: 2)
        let insertedMatchY = try visibleTop(of: highlight, in: web, host: host)
        XCTAssertEqual(insertedMatchY, matchY, accuracy: 2)

        _ = try host.js("window.beforeMermaid = true", web)
        try insert("```mermaid\ngraph LR; A-->B;\n```\n\n", before: "New Needle.", in: host)
        try host.waitForPage("""
            !window.beforeMermaid && window.__md2DiagramsSettled === true && !!document.querySelector('.diagram svg')
                && \(PreviewFindRanges.count) === 3 && (\(currentIsSecond))
            """, in: web, context: "the fresh page restores the same current result")
        XCTAssertEqual(try visibleTop(of: second, in: web, host: host), y, accuracy: 2)
        let reloadedMatchY = try visibleTop(of: highlight, in: web, host: host)
        XCTAssertEqual(reloadedMatchY, matchY, accuracy: 2)
        print("Paused preview second Find occurrence in CSS px: before y=\(matchY), edited y=\(editedMatchY), "
              + "inserted y=\(insertedMatchY), reloaded y=\(reloadedMatchY)")

        // A selected result can remain current after a reader scrolls away.
        // A repaint after the next edit must hold what is actually visible.
        let reading = "Array.from(document.querySelectorAll('main p')).find(p => p.textContent === 'Meeting notes 50')"
        _ = try host.js("window.dispatchEvent(new WheelEvent('wheel', { deltaY: -800 }))", web)
        let readingY = try positionReference(reading, at: 60, in: web, host: host)
        XCTAssertEqual(try host.js("(\(second)).getBoundingClientRect().top > innerHeight", web) as? Bool, true)
        try insert("Checked ", before: "New Needle.", in: host)
        try host.waitForPage("""
            \(PreviewFindRanges.all)[0]?.startContainer.textContent.includes('Checked New Needle.')
                && \(PreviewFindRanges.count) === 3 && (\(currentIsSecond))
            """, in: web, context: "the offscreen result remains current after repaint")
        XCTAssertEqual(try visibleTop(of: reading, in: web, host: host), readingY, accuracy: 2)
        XCTAssertTrue(host.window.makeFirstResponder(field))
        host.store.requestFind(.previous)
        try host.waitForPage("\(PreviewFindRanges.currentIndex) === 1 && !(\(currentIsSecond))", in: web,
                             context: "an explicit Previous moves from the preserved match")
        _ = try visibleTop(of: highlight, in: web, host: host)
    }

    @MainActor func testPausedPreviewKeepsRecord60WhenTableHeaderGrows() throws {
        let host = InteractionTestWindow()
        defer { host.close() }
        let rows = (1...150).map { "| Record \($0) | Value \($0) |" }.joined(separator: "\n")
        let source = "# audit-title\n\n| Key | Value |\n|---|---|\n" + rows + "\n\nClosing note.\n"
        host.store.text = source
        let web = try mountDocument(in: host, settings: host.settings, marker: "Record 150",
                                    ready: "document.querySelectorAll('tbody tr').length === 150",
                                    size: NSSize(width: 1046, height: 650))
        try toggle(in: host, paused: false)
        let record = "Array.from(document.querySelectorAll('tbody td')).find(cell => cell.textContent === 'Record 60')"
        _ = try positionReference(record, at: 70, in: web, host: host)
        host.spin(for: 0.3)
        let before = try visibleTop(of: record, in: web, host: host)
        XCTAssertEqual(before, 71, accuracy: 2)

        let editor = try XCTUnwrap(host.store.editorSession.textView)
        let key = (editor.string as NSString).range(of: "Key")
        let start = try XCTUnwrap(key.location == NSNotFound ? nil : key.location)
        let caret = NSRange(location: start, length: 0)
        XCTAssertTrue(host.window.makeFirstResponder(editor))
        editor.setSelectedRange(caret)
        editor.scrollRangeToVisible(caret)
        XCTAssertEqual(try visibleTop(of: record, in: web, host: host), before, accuracy: 2)
        let tallHeader = "Key<br>Region<br>Office<br>Department<br>Owner"
        editor.insertText(tallHeader, replacementRange: key)
        XCTAssertEqual(editor.string, (source as NSString).replacingCharacters(in: key, with: tallHeader))
        try host.waitForPage("""
            document.querySelector('thead th')?.textContent === 'KeyRegionOfficeDepartmentOwner'
                && document.querySelectorAll('thead th br').length === 4
                && document.querySelectorAll('tbody tr').length === 150
            """, in: web, context: "the five-line header and all data rows rendered")
        host.spin(for: 0.65)
        let after = try visibleTop(of: record, in: web, host: host)
        let height = try XCTUnwrap(try host.js("innerHeight", web) as? Double)
        print("Paused preview Record 60 after header growth in CSS px: before y=\(before), after y=\(after), viewport=\(height)")
        XCTAssertEqual(after, before, accuracy: 2, "the same visible record must stay in place when the header grows")
    }

    @MainActor func testPausedPreviewKeepsRecord60AcrossFourSeparateHeaderEdits() throws {
        let host = InteractionTestWindow()
        defer { host.close() }
        let (web, y0) = try pausedTableFixture(in: host)
        let record = "Record 60"
        print("Paused table B \(record) y0=\(y0) CSS px")
        var header = "Key"
        for (index, field) in ["Region", "Office", "Department", "Owner"].enumerated() {
            let suffix = "<br>\(field)"
            try editPausedTableHeader(header, replacement: suffix, append: true, in: web, host: host)
            header += suffix
            try expectHeldTableCell(record, at: y0, step: "B step \(index + 1) +\(field)", in: web, host: host)
        }
    }

    @MainActor func testPausedPreviewKeepsRecord60AcrossSixHeaderGrowthAndRestoreCycles() throws {
        let host = InteractionTestWindow()
        defer { host.close() }
        let (web, y0) = try pausedTableFixture(in: host)
        let record = "Record 60"
        let tallHeader = "Key<br>Region<br>Office<br>Department<br>Owner"
        print("Paused table C \(record) y0=\(y0) CSS px")
        for cycle in 1...6 {
            try editPausedTableHeader("Key", replacement: tallHeader, in: web, host: host)
            try expectHeldTableCell(record, at: y0, step: "C cycle \(cycle) grow", in: web, host: host)
            try editPausedTableHeader(tallHeader, replacement: "Key", in: web, host: host)
            try expectHeldTableCell(record, at: y0, step: "C cycle \(cycle) restore", in: web, host: host)
        }
    }

    @MainActor func testPausedPreviewUsesTheNewVisibleRecordAfterUserScrolls() throws {
        let host = InteractionTestWindow()
        defer { host.close() }
        let (web, y0) = try pausedTableFixture(in: host)
        let tallHeader = "Key<br>Region<br>Office<br>Department<br>Owner"
        print("Paused table user scroll Record 60 y0=\(y0) CSS px")
        try editPausedTableHeader("Key", replacement: tallHeader, in: web, host: host)
        try expectHeldTableCell("Record 60", at: y0, step: "before user scroll", in: web, host: host)

        let nearbyRecord = tableCell(named: "Record 58")
        let nearbyY0 = try visibleTop(of: nearbyRecord, in: web, host: host)
        let originalScroll = try XCTUnwrap(try host.js("scrollY", web) as? Double)
        _ = try host.js("""
            window.nativeWheelSeen = false;
            window.addEventListener('wheel', event => { window.nativeWheelSeen ||= event.isTrusted; });
            true;
            """, web)
        // Keep the old held area in view. Its visibility alone must not let
        // the next edit restore the pre-scroll position.
        let targetY = try XCTUnwrap(try host.js("(\(tableCell(named: "Record 55"))).getBoundingClientRect().top", web) as? Double)
        web.scrollWheel(with: try nativeWheelEvent(by: Int32((70 - targetY).rounded()), in: web, host: host))
        try host.waitForPage("window.nativeWheelSeen && scrollY < \(originalScroll) - 150",
                             in: web, context: "a trusted preview wheel event moved to an earlier group of rows")
        host.spin(for: 0.4)
        let newRecord = try XCTUnwrap(try host.js("""
            Array.from(document.querySelectorAll('tbody tr'), row => row.cells[0])
                .find(cell => cell.getBoundingClientRect().top >= 70 && cell.getBoundingClientRect().bottom < innerHeight)
                ?.textContent
            """, web) as? String)
        let recordNumber = try XCTUnwrap(Int(newRecord.dropFirst("Record ".count)))
        XCTAssertLessThan(recordNumber, 60)
        let shiftedRecord60 = try visibleTop(of: tableCell(named: "Record 60"), in: web, host: host)
        let shiftedRecord58 = try visibleTop(of: nearbyRecord, in: web, host: host)
        XCTAssertGreaterThan(shiftedRecord60 - y0, 150)
        XCTAssertGreaterThan(shiftedRecord58 - nearbyY0, 150)
        let newY0 = try visibleTop(of: tableCell(named: newRecord), in: web, host: host)
        print("Paused table user scroll \(newRecord) new y0=\(newY0), Record 58 y=\(shiftedRecord58), Record 60 y=\(shiftedRecord60) CSS px")
        try editPausedTableHeader(tallHeader, replacement: "Key", in: web, host: host)
        try expectHeldTableCell(newRecord, at: newY0, step: "after user scroll and next edit", in: web, host: host)
        try expectHeldTableCell("Record 60", at: shiftedRecord60, step: "after user scroll and next edit", in: web, host: host)
    }

    @MainActor private func pausedTableFixture(in host: InteractionTestWindow) throws -> (WKWebView, Double) {
        let rows = (1...150).map { "| Record \($0) | Value \($0) |" }.joined(separator: "\n")
        host.store.text = "# audit-title\n\n| Key | Value |\n|---|---|\n" + rows + "\n\nClosing note.\n"
        let web = try mountDocument(in: host, settings: host.settings, marker: "Record 150",
                                    ready: "document.querySelectorAll('tbody tr').length === 150",
                                    size: NSSize(width: 1046, height: 650))
        try toggle(in: host, paused: false)
        let record = tableCell(named: "Record 60")
        _ = try positionReference(record, at: 70, in: web, host: host)
        host.spin(for: 0.3)
        let y0 = try visibleTop(of: record, in: web, host: host)
        XCTAssertEqual(y0, 71, accuracy: 2)
        return (web, y0)
    }

    @MainActor private func editPausedTableHeader(_ header: String, replacement: String, append: Bool = false,
                                                in web: WKWebView, host: InteractionTestWindow) throws {
        let editor = try XCTUnwrap(host.store.editorSession.textView)
        let source = editor.string as NSString
        let line = source.range(of: "| \(header) | Value |")
        let start = try XCTUnwrap(line.location == NSNotFound ? nil : line.location) + 2
        let cell = NSRange(location: start, length: header.utf16.count)
        let edit = append ? NSRange(location: NSMaxRange(cell), length: 0) : cell
        let expected = source.replacingCharacters(in: edit, with: replacement)
        XCTAssertTrue(host.window.makeFirstResponder(editor))
        editor.setSelectedRange(edit)
        editor.scrollRangeToVisible(edit)
        editor.insertText(replacement, replacementRange: edit)
        XCTAssertEqual(editor.string, expected)
        let lines = (append ? header + replacement : replacement).components(separatedBy: "<br>")
        try host.waitForPage("""
            document.querySelector('thead th')?.textContent === '\(lines.joined())'
                && document.querySelectorAll('thead th br').length === \(lines.count - 1)
                && document.querySelectorAll('tbody tr').length === 150
            """, in: web, context: "the edited header and all data rows rendered")
        host.spin(for: 0.65)
    }

    private func tableCell(named record: String) -> String {
        "Array.from(document.querySelectorAll('tbody td')).find(cell => cell.textContent === '\(record)')"
    }

    @MainActor private func expectHeldTableCell(_ record: String, at y0: Double, step: String, in web: WKWebView,
                                               host: InteractionTestWindow, file: StaticString = #filePath,
                                               line: UInt = #line) throws {
        let geometry = try host.js("""
            (() => {
                const rect = (\(tableCell(named: record)))?.getBoundingClientRect();
                return { viewport: innerHeight, y: rect?.top ?? null,
                    visible: !!rect && rect.height > 0 && rect.bottom > 0 && rect.top < innerHeight };
            })()
            """, web) as? [String: Any]
        let y = (geometry?["y"] as? NSNumber)?.doubleValue
        let visible = geometry?["visible"] as? Bool == true
        let viewport = (geometry?["viewport"] as? NSNumber)?.doubleValue
        let position = y.map { "y=\($0) delta=\($0 - y0)" } ?? "y=missing"
        print("Paused table \(step) \(record) y0=\(y0) \(position) viewport=\(viewport ?? 0) visible=\(visible) CSS px")
        XCTAssertTrue(visible, "\(step): \(record) must be visible", file: file, line: line)
        if let y { XCTAssertEqual(y, y0, accuracy: 2, "\(step): \(record) drift from y0", file: file, line: line) }
    }

    @MainActor func testPausedPreviewKeepsRecord60WhenTwentyTableRowsAreInserted() throws {
        let host = InteractionTestWindow()
        defer { host.close() }
        // The rows just above Record 60 repeat a run from twenty rows
        // earlier. After insertion, the same ordinal can point to the wrong run.
        let rows = (1...150).map { row in
            let label = (32...39).contains(row) ? row + 20 : row
            return "| Record \(label) | Value \(label) |"
        }.joined(separator: "\n")
        host.store.text = "| Key | Value |\n| --- | --- |\n" + rows
        let web = try mountDocument(in: host, settings: host.settings, marker: "Record 150",
                                    ready: "document.querySelectorAll('tbody tr').length === 150")
        try toggle(in: host, paused: false)
        let record = "Array.from(document.querySelectorAll('tbody tr')).find(row => row.cells[0].textContent === 'Record 60')"
        let y = try positionReference(record, at: 70, in: web, host: host)
        try insert((1...20).map { "| Added \($0) | check |\n" }.joined(), before: "| Record 1 |", in: host)
        try host.waitForPage("""
            window.initialPage && document.querySelectorAll('tbody tr').length === 170
                && document.querySelector('tbody').rows[19].cells[0].textContent === 'Added 20'
                && document.querySelector('tbody').rows[79] === (\(record))
            """, in: web, context: "all twenty new rows rendered above the original record in a live update")
        let insertedY = try visibleTop(of: record, in: web, host: host)
        XCTAssertEqual(insertedY, y, accuracy: 2)

        // The new page now starts with another table that has identical
        // headers. Only the original table contains the held record.
        try insert("| Key | Value |\n| --- | --- |\n| Draft | Pending |\n\n"
                   + "```mermaid\ngraph LR; A-->B;\n```\n\n", before: "| Key | Value |", in: host)
        try host.waitForPage("""
            !window.initialPage && window.__md2DiagramsSettled === true && !!document.querySelector('.diagram svg')
                && document.querySelectorAll('table').length === 2
                && document.querySelector('table tbody tr').cells[0].textContent === 'Draft'
                && document.querySelectorAll('table')[1].tBodies[0].rows[79] === (\(record))
            """, in: web, context: "the original record belongs to the second table after the fresh navigation")
        let reloadedY = try visibleTop(of: record, in: web, host: host)
        print("Paused preview Record 60 in CSS px: before y=\(y), inserted y=\(insertedY), reloaded y=\(reloadedY)")
        XCTAssertEqual(reloadedY, y, accuracy: 2)
    }

    @MainActor func testPausedPreviewKeepsRecord60WhenTwentyListItemsAreInserted() throws {
        let host = InteractionTestWindow()
        defer { host.close() }
        host.store.text = (1...150).map { "- Record \($0)" }.joined(separator: "\n")
        let web = try mountDocument(in: host, settings: host.settings, marker: "Record 150",
                                    ready: "document.querySelectorAll('main li').length === 150")
        try toggle(in: host, paused: false)
        let record = "Array.from(document.querySelectorAll('main li')).find(li => li.textContent.trim() === 'Record 60')"
        let y = try positionReference(record, at: 70, in: web, host: host)
        try insert((1...20).map { "- Added \($0)\n" }.joined(), before: "- Record 1\n", in: host)
        try host.waitForPage("""
            window.initialPage && document.querySelectorAll('main li').length === 170
                && document.querySelectorAll('main li')[19].textContent.trim() === 'Added 20'
                && document.querySelectorAll('main li')[79] === (\(record))
            """, in: web, context: "all twenty new list items rendered above the original item")
        XCTAssertEqual(try visibleTop(of: record, in: web, host: host), y, accuracy: 2)
    }

    @MainActor func testPausedPreviewKeepsTheSecondLocalImageAfterLoadingMermaid() throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("HeldPreviewImages-\(UUID())", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        // Both paragraphs have the same tag, alt text and empty textContent.
        // The two genuinely different image files identify what is being read.
        try writeImage(height: 950, color: .red, to: directory.appendingPathComponent("first.png"))
        try writeImage(height: 1050, color: .blue, to: directory.appendingPathComponent("second.png"))
        let url = directory.appendingPathComponent("Photos.md")
        let text = "# Photos\n\n![Photo](first.png)\n\n![Photo](second.png)\n\n"
            + (1...30).map { "End note \($0)." }.joined(separator: "\n\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let host = InteractionTestWindow()
        defer { host.store.closeDocument(discardRecovery: true); host.close() }
        host.store.open(url)
        let second = "Array.from(document.querySelectorAll('main img')).find(img => img.naturalHeight === 1050)"
        let bothDecoded = """
            document.querySelectorAll('main img').length === 2
                && document.querySelector('main img')?.naturalHeight === 950 && !!(\(second))
            """
        let web = try mountDocument(in: host, settings: host.settings, marker: "Photos", ready: bothDecoded)
        try toggle(in: host, paused: false)
        let secondSource = try XCTUnwrap(try host.js("(\(second)).currentSrc", web) as? String)
        XCTAssertTrue(secondSource.hasPrefix("md2-local-image://"))
        let y = try positionReference(second, at: -90, in: web, host: host)
        try insert("```mermaid\ngraph LR; A-->B;\n```\n\n", before: "![Photo](first.png)", in: host)
        try host.waitForPage("""
            !window.initialPage && window.__md2DiagramsSettled === true && !!document.querySelector('.diagram svg')
                && (\(bothDecoded))
            """, in: web, context: "new page has painted Mermaid and both local images")
        XCTAssertEqual(try host.js("(\(second)).currentSrc", web) as? String, secondSource)
        let reloadedY = try visibleTop(of: second, in: web, host: host)
        print("Paused preview second local image in CSS px: before y=\(y), reloaded y=\(reloadedY)")
        XCTAssertEqual(reloadedY, y, accuracy: 2)
    }

    @MainActor private func positionReference(_ expression: String, at top: Double, in web: WKWebView,
                                              host: InteractionTestWindow) throws -> Double {
        _ = try host.js("window.initialPage = true; scrollBy(0, (\(expression)).getBoundingClientRect().top - (\(top)))", web)
        let y = try visibleTop(of: expression, in: web, host: host)
        XCTAssertEqual(y, top, accuracy: 2)
        return y
    }

    @MainActor private func visibleTop(of expression: String, in web: WKWebView, host: InteractionTestWindow,
                                        file: StaticString = #filePath, line: UInt = #line) throws -> Double {
        let result = try host.js("""
            (() => {
                const rect = (\(expression)).getBoundingClientRect();
                return { top: rect.top, visible: rect.bottom > 0 && rect.top < innerHeight && rect.height > 0 };
            })()
            """, web)
        let bounds = try XCTUnwrap(result as? [String: NSNumber], file: file, line: line)
        XCTAssertEqual(bounds["visible"]?.boolValue, true, "the reference should be visible: \(bounds)", file: file, line: line)
        return try XCTUnwrap(bounds["top"]?.doubleValue, file: file, line: line)
    }

    @MainActor private func insert(_ text: String, before marker: String, in host: InteractionTestWindow) throws {
        let editor = try XCTUnwrap(host.store.editorSession.textView)
        let target = (editor.string as NSString).range(of: marker)
        let offset = try XCTUnwrap(target.location == NSNotFound ? nil : target.location, "missing source marker \(marker)")
        let caret = NSRange(location: offset, length: 0)
        XCTAssertTrue(host.window.makeFirstResponder(editor))
        editor.setSelectedRange(caret)
        editor.scrollRangeToVisible(caret)
        editor.insertText(text, replacementRange: caret)
    }

    @MainActor private func writeImage(height: Int, color: NSColor, to url: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 320, height: height))
        let image = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
    }

    @MainActor private func mount(in host: InteractionTestWindow, settings: AppSettings, imageURL: String? = nil) throws -> WKWebView {
        let paragraphs = (1...110).map { index in
            switch index {
            case 12: "Draft summary."
            case 72: "| Reference value | Units |\n| --- | --- |\n| 42 | hours |"
            default: "Working notes for paragraph \(index)."
            }
        }
        host.store.text = paragraphs.joined(separator: "\n\n")
            + (imageURL.map { "\n\n![Image still loading](\($0))" } ?? "")
        return try mountDocument(in: host, settings: settings, marker: "Reference value",
                                 ready: "!!document.querySelector('table')", requireLoaded: imageURL == nil)
    }

    @MainActor private func mountDocument(in host: InteractionTestWindow, settings: AppSettings, marker: String,
                                           ready: String, requireLoaded: Bool = true,
                                           size: NSSize = NSSize(width: 1020, height: 610)) throws -> WKWebView {
        settings.language = .english
        settings.newDocumentMode = .split
        settings.defaultMode = .split
        // Mount the fixture after its first render. Otherwise a blank page
        // can still be restoring its initial scroll during our first gesture.
        host.spin(until: { host.store.rendered.body.contains(marker) })
        host.window.setContentSize(size)
        host.window.contentView = NSHostingView(rootView: ContentView(document: host.store, settings: settings, onOpen: {}))
        host.window.makeKeyAndOrderFront(nil)
        host.spin(until: { !host.descendants(WKWebView.self).isEmpty })
        let web = try XCTUnwrap(host.descendants(WKWebView.self).first)
        try host.waitForPage("(\(ready)) && typeof window.__md2CaptureAnchor === 'function'",
                             in: web, context: "fixture in split preview", requireLoaded: requireLoaded)
        host.spin(for: 0.35)
        return web
    }

    @MainActor private func item(in host: InteractionTestWindow, paused: Bool) -> NSToolbarItem? {
        let title = paused ? "Resume Synchronized Scrolling" : "Pause Synchronized Scrolling"
        return host.window.toolbar?.visibleItems?.first { $0.label == title }
    }

    @MainActor private func toggle(in host: InteractionTestWindow, paused: Bool) throws {
        let control = try XCTUnwrap(item(in: host, paused: paused), "visible split scroll control")
        let view = try XCTUnwrap(control.view)
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: host.window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        host.window.postEvent(try event(.leftMouseUp), atStart: true)
        host.window.sendEvent(try event(.leftMouseDown))
        if let up = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            host.window.sendEvent(up)
        }
        host.spin(until: { self.item(in: host, paused: !paused) != nil })
        _ = try XCTUnwrap(item(in: host, paused: !paused), "the native control must change state")
    }

    @MainActor private func observeFollows(in web: WKWebView, host: InteractionTestWindow) throws {
        _ = try host.js("""
            window.resumeCalls = [];
            const follow = window.__md2FollowToAnchor;
            window.__md2FollowToAnchor = line => { window.resumeCalls.push(line); return follow(line); };
            true;
            """, web)
    }

    @MainActor private func tableY(in web: WKWebView, host: InteractionTestWindow) throws -> Double {
        try XCTUnwrap(try host.js("document.querySelector('table').getBoundingClientRect().top", web) as? Double)
    }

    @MainActor private func showTable(in web: WKWebView, host: InteractionTestWindow) throws {
        _ = try host.js("""
            window.dispatchEvent(new WheelEvent('wheel', {bubbles: true, deltaY: 600}));
            window.scrollBy(0, document.querySelector('table').getBoundingClientRect().top - 42);
            """, web)
        try host.waitForPage("Math.abs(document.querySelector('table').getBoundingClientRect().top - 42) < 2",
                             in: web, context: "the reader placed the table near the top of the preview", requireLoaded: false)
    }

    @MainActor private func waitForSource(_ text: String, in editor: NSTextView, host: InteractionTestWindow) throws {
        let range = (editor.string as NSString).range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound)
        try host.waitForTarget(range, in: editor, context: "the editor should follow the preview to \(text)")
    }

    @MainActor private func scrollEditor(by delta: Int32, in host: InteractionTestWindow, editor: NSTextView) throws {
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        let origin = scroll.contentView.bounds.minY
        // Target the mounted scroll view directly: an in-process CGEvent does
        // not carry an NSWindow target, even when its screen coordinates match.
        scroll.scrollWheel(with: try nativeWheelEvent(by: delta, in: scroll, host: host))
        host.spin(until: { abs(scroll.contentView.bounds.minY - origin) > 30 }, timeout: 2)
    }

    @MainActor private func nativeWheelEvent(by delta: Int32, in view: NSView, host: InteractionTestWindow) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                          wheel1: delta, wheel2: 0, wheel3: 0))
        // Dequeue the wheel through NSApplication so the bounds observer sees
        // NSApp.currentEvent, the same user-scroll signal as in the app.
        let center = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        let point = host.window.convertPoint(toScreen: view.convert(center, to: nil))
        event.location = CGPoint(x: point.x, y: try XCTUnwrap(NSScreen.screens.first).frame.maxY - point.y)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(host.window.windowNumber))
        let wheel = try XCTUnwrap(NSEvent(cgEvent: event))
        NSApp.postEvent(wheel, atStart: true)
        return try XCTUnwrap(NSApp.nextEvent(matching: .scrollWheel, until: Date().addingTimeInterval(2),
                                            inMode: .default, dequeue: true))
    }
}
