import AppKit
import MD2Core
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

/// GUI-gated verification that a checkbox click from a preview older than the
/// text never changes another task, and that the box it flipped goes back.
///
/// The clicks are real mouse events, since the bridge takes only trusted ones,
/// and the document is a real `DocumentStore`. `HeldPreview` keeps the page on
/// the text it was given until a test calls `catchUp`, so a stale page is a
/// state rather than a race against the render and live-update debounces.
/// `MD2_RUN_GUI_TESTS=1 swift test --filter PreviewTaskToggleGUITests`.
final class PreviewTaskToggleGUITests: XCTestCase {
    private let firstBox = "document.querySelectorAll('input[data-md2-task-line]')[0]"
    private let secondBox = "document.querySelectorAll('input[data-md2-task-line]')[1]"

    // MARK: - A stale click

    /// F05 in the 2026-10-15 review, through the page: N lands above A while
    /// the page still shows A on line 1, and the click is on A.
    @MainActor
    func testStaleClickLeavesTheTextAloneAndTheBoxGoesBack() throws {
        try skipUnlessGUITestsEnabled()
        let preview = try HeldPreview(test: self, text: "- [ ] A\n- [ ] B")
        defer { preview.close() }

        preview.store.text = "- [ ] N\n- [ ] A\n- [ ] B"
        try preview.page.click(firstBox)
        XCTAssertTrue(preview.waitForClicks(1))

        XCTAssertEqual(preview.store.text, "- [ ] N\n- [ ] A\n- [ ] B", "the click on A must not check N")
        XCTAssertTrue(try preview.page.waitFor("\(firstBox).checked === false"), "the refused click must not leave its box flipped")

        // Once the page has caught up, the same task takes a click.
        try preview.catchUp()
        XCTAssertTrue(try preview.page.waitForRevision(preview.store.sourceLineRevision))
        try preview.page.click(secondBox)
        XCTAssertTrue(preview.waitForClicks(2))
        XCTAssertEqual(preview.store.text, "- [ ] N\n- [x] A\n- [ ] B")
    }

    /// A live update keeps a block whose HTML did not change, and the block's
    /// HTML holds the box's `checked` attribute, not the state the click gave
    /// it. So the update repairs nothing: the box stays flipped until the
    /// refusal puts it back, whichever of the two reaches the page first.
    @MainActor
    func testRefusalReachingAKeptBlockAfterTheUpdateStillPutsTheBoxBack() throws {
        try skipUnlessGUITestsEnabled()
        let preview = try HeldPreview(test: self, text: "Intro.\n\n- [ ] A\n- [ ] B")
        defer { preview.close() }
        preview.holdsRefusals = true
        _ = try preview.page.evaluate("window.__list = document.querySelector('main > ul'); window.__box = \(firstBox); true")

        preview.store.text = "New.\n\nIntro.\n\n- [ ] A\n- [ ] B"
        try preview.page.click(firstBox)
        XCTAssertTrue(preview.waitForClicks(1))
        try preview.catchUp()
        XCTAssertTrue(try preview.page.waitFor("document.body.textContent.indexOf('New.') >= 0"))

        XCTAssertEqual(try preview.page.evaluate("window.__list.isConnected && document.querySelector('main > ul') === window.__list") as? Bool, true,
                       "the list did not change, so it stays")
        XCTAssertEqual(try preview.page.evaluate("window.__box.getAttribute('data-md2-task-line')") as? String, "5")
        XCTAssertEqual(try preview.page.evaluate("window.__box.checked") as? Bool, true,
                       "precondition: the update does not repair a kept box")

        preview.releaseRefusals()
        XCTAssertTrue(try preview.page.waitFor("window.__box.checked === false"))
        XCTAssertEqual(preview.store.text, "New.\n\nIntro.\n\n- [ ] A\n- [ ] B")
    }

    /// Read mode has no live update: every change is a new page.
    @MainActor
    func testStaleClickOnAFullLoadPageIsRefusedAndTheNextPageWorks() throws {
        try skipUnlessGUITestsEnabled()
        let preview = try HeldPreview(test: self, text: "- [ ] A\n- [ ] B", liveUpdate: false)
        defer { preview.close() }

        preview.store.text = "- [ ] N\n- [ ] A\n- [ ] B"
        try preview.page.click(firstBox)
        XCTAssertTrue(preview.waitForClicks(1))
        XCTAssertEqual(preview.store.text, "- [ ] N\n- [ ] A\n- [ ] B")
        XCTAssertTrue(try preview.page.waitFor("\(firstBox).checked === false"))

        try preview.catchUp()
        XCTAssertTrue(try preview.page.waitFor("document.querySelectorAll('input[data-md2-task-line]').length === 3"))
        XCTAssertTrue(preview.waitForLoad())
        try preview.page.click(secondBox)
        XCTAssertTrue(preview.waitForClicks(2))
        XCTAssertEqual(preview.store.text, "- [ ] N\n- [x] A\n- [ ] B")
    }

    // MARK: - A current click

    /// The click after a toggle reaches a page one toggle behind. A toggle
    /// moves no line, so that page's numbers are still right.
    @MainActor
    func testSecondClickBeforeTheRerenderLands() throws {
        try skipUnlessGUITestsEnabled()
        let preview = try HeldPreview(test: self, text: "- [ ] A\n- [ ] B")
        defer { preview.close() }

        try preview.page.click(firstBox)
        XCTAssertTrue(preview.waitForClicks(1))
        try preview.page.click(secondBox)
        XCTAssertTrue(preview.waitForClicks(2))

        XCTAssertEqual(preview.store.text, "- [x] A\n- [x] B")
        XCTAssertEqual(try preview.page.evaluate("\(firstBox).checked && \(secondBox).checked") as? Bool, true)
    }

    // MARK: - The page's revision

    /// A kept page gets no new content, but its revision must still move, or
    /// every later click on it would be refused.
    @MainActor
    func testTextThatRendersToTheSamePageStillMovesItsRevision() throws {
        try skipUnlessGUITestsEnabled()
        let preview = try HeldPreview(test: self, text: "- [ ] A\n- [ ] B")
        defer { preview.close() }
        let page = preview.store.rendered.html

        preview.store.text = "- [ ] A\n- [ ] B\n"
        try preview.catchUp()
        XCTAssertEqual(preview.store.rendered.html, page, "precondition: the new text renders to the same page")
        XCTAssertTrue(try preview.page.waitForRevision(preview.store.sourceLineRevision))

        try preview.page.click(firstBox)
        XCTAssertTrue(preview.waitForClicks(1))
        XCTAssertEqual(preview.store.text, "- [x] A\n- [ ] B\n")
    }

    /// While the caret's line is followed, a live update takes its own path.
    @MainActor
    func testEditFollowUpdateMovesTheRevision() throws {
        try skipUnlessGUITestsEnabled()
        let preview = try HeldPreview(test: self, text: "Intro.\n\n- [ ] A")
        defer { preview.close() }

        preview.viewport.setPendingEditFollow(1)
        preview.store.text = "Intro, edited.\n\n- [ ] A"
        try preview.catchUp()
        XCTAssertTrue(try preview.page.waitForRevision(preview.store.sourceLineRevision))
    }

    @MainActor
    func testLabelNeverLeadsALiveUpdate() throws {
        try skipUnlessGUITestsEnabled()
        try assertLabelFollowsContent(liveUpdate: true)
    }

    @MainActor
    func testLabelNeverLeadsAFullLoad() throws {
        try skipUnlessGUITestsEnabled()
        try assertLabelFollowsContent(liveUpdate: false)
    }

    /// A label ahead of its content would pass a stale click as current. The
    /// DOM is shared between the worlds, so one isolated script reads the label
    /// and the content at a single instant, however long the update takes.
    @MainActor
    private func assertLabelFollowsContent(liveUpdate: Bool) throws {
        let preview = try HeldPreview(test: self, text: "Intro.\n\n- [ ] A", liveUpdate: liveUpdate)
        defer { preview.close() }

        preview.store.text = "Intro, edited.\n\n- [ ] A"
        try preview.catchUp()
        XCTAssertTrue(preview.waitForHandOver())
        // SwiftUI updates the view for its own reasons too. A pass with nothing
        // new in it finds the HTML unchanged, makes this call, and must not
        // label the old page.
        preview.coordinator.labelPage(in: preview.page.webView)
        let revision = preview.store.sourceLineRevision
        let deadline = Date().addingTimeInterval(15)
        var snapshot: String?
        while snapshot != "\(revision) true", Date() < deadline {
            snapshot = try preview.page.isolated("""
                String(window.__md2SourceLineRevision) + ' ' + (document.body.textContent.indexOf('edited') >= 0)
                """) as? String
            XCTAssertNotEqual(snapshot, "\(revision) false", "the page was labelled before its content arrived")
        }
        XCTAssertEqual(snapshot, "\(revision) true")
    }

    /// An update that failed left the old content in the page, whatever the
    /// document has moved on to, so the page keeps its old label.
    @MainActor
    func testUpdateThatThrowsLeavesTheLabelAlone() throws {
        try skipUnlessGUITestsEnabled()
        let preview = try HeldPreview(test: self, text: "Intro.\n\n- [ ] A")
        defer { preview.close() }
        let shown = preview.store.sourceLineRevision
        XCTAssertTrue(try preview.page.waitForRevision(shown))
        _ = try preview.page.evaluate("window.__md2ApplyContent = function () { window.__threw = true; throw new Error('failed'); }; true")

        preview.store.text = "Intro, edited.\n\n- [ ] A"
        try preview.catchUp()
        XCTAssertTrue(try preview.page.waitFor("window.__threw === true"))

        // The update's completion comes back before this script's, so a label
        // sent from it would be in the page by the read that follows.
        _ = try preview.page.evaluate("true")
        XCTAssertEqual(try preview.page.isolated("String(window.__md2SourceLineRevision)") as? String, String(shown))
    }

    /// A load that is on its way has not changed what the page shows, so a
    /// view update meanwhile must not move the old page's label.
    @MainActor
    func testViewUpdateDuringALoadLeavesTheOldPageLabelAlone() throws {
        try skipUnlessGUITestsEnabled()
        let preview = try HeldPreview(test: self, text: "- [ ] A")
        defer { preview.close() }
        let shown = try XCTUnwrap(preview.page.isolated("String(window.__md2SourceLineRevision)") as? String)

        preview.coordinator.sourceLineRevision = 1_000
        preview.coordinator.beginLoading()
        preview.coordinator.labelPage(in: preview.page.webView)

        XCTAssertEqual(try preview.page.isolated("String(window.__md2SourceLineRevision)") as? String, shown)
    }

    /// A page some newer load will replace shows older text, so it stays
    /// unlabelled however far its navigation gets.
    @MainActor
    func testACommitThatANewerLoadSupersededIsNotLabelled() throws {
        try skipUnlessGUITestsEnabled()
        let preview = try HeldPreview(test: self, text: "- [ ] A")
        defer { preview.close() }
        let shown = try XCTUnwrap(preview.page.isolated("String(window.__md2SourceLineRevision)") as? String)
        let superseded = try XCTUnwrap(preview.coordinator.documentLoader.currentNavigation)

        preview.coordinator.sourceLineRevision = 1_000
        preview.coordinator.beginLoading()
        // The newer load goes elsewhere, so this page stays put to be checked.
        let elsewhere = WKWebView()
        preview.coordinator.documentLoader.load("<p>Newer</p>", baseURL: nil, in: elsewhere)
        preview.coordinator.webView(preview.page.webView, didCommit: superseded)

        XCTAssertEqual(try preview.page.isolated("String(window.__md2SourceLineRevision)") as? String, shown)
    }

    /// The older page finishes while a load is on its way, and an edit follows.
    /// Going into that page, the edit would be overwritten by the load's older
    /// text, under a label that passes the page as current.
    @MainActor
    func testEditDuringALoadIsNotOverwrittenByThatLoad() throws {
        try skipUnlessGUITestsEnabled()
        let preview = try HeldPreview(test: self, text: "Intro.\n\n- [ ] A")
        defer { preview.close() }
        let older = try XCTUnwrap(preview.coordinator.documentLoader.currentNavigation)
        let gate = NavigationGate(in: preview)
        defer { gate.open() }
        _ = try preview.page.evaluate("window.__olderPage = true; true")

        // A new diagram engine takes a full load, which stops at the gate.
        preview.store.text = "Older.\n\n```mermaid\ngraph TD; A-->B;\n```"
        try preview.catchUp()
        XCTAssertTrue(gate.waitForHeld(1))
        preview.coordinator.webView(preview.page.webView, didFinish: older)

        preview.store.text = "Newest.\n\n- [ ] A"
        try preview.catchUp()
        XCTAssertTrue(gate.waitForHeld(2), "the edit must load its own page, not go into one on its way out")
        gate.open()

        XCTAssertTrue(try preview.page.waitFor("window.__olderPage !== true"))
        XCTAssertTrue(preview.waitForLoad())
        XCTAssertEqual(try preview.page.isolated("""
            String(window.__md2SourceLineRevision) + ' ' + document.body.textContent.includes('Newest')
            """) as? String, "\(preview.store.sourceLineRevision) true")
    }

    /// What `didFinish` does is for the page the preview is waiting for. On a
    /// page some newer load will replace it would go with that page, and use
    /// up the scroll target and the search on the way.
    @MainActor
    func testPostLoadWorkWaitsForTheLatestNavigation() throws {
        try skipUnlessGUITestsEnabled()
        let text = (1...200).map { "Paragraph \($0)." }.joined(separator: "\n\n")
        let preview = try HeldPreview(test: self, text: text)
        defer { preview.close() }
        let webView: WKWebView = preview.page.webView
        let superseded = try XCTUnwrap(preview.coordinator.documentLoader.currentNavigation)
        let gate = NavigationGate(in: preview)
        defer { gate.open() }
        let typography = "document.getElementById('md2-typography')"
        let found = "document.querySelector('mark.md2-find')"
        _ = try preview.page.evaluate("\(typography).remove(); true")

        // One turn of the main actor, so the load is still being prepared.
        preview.coordinator.beginLoading()
        preview.coordinator.documentLoader.load(preview.store.rendered.html, baseURL: nil, in: webView)
        XCTAssertNil(preview.coordinator.documentLoader.currentNavigation)
        preview.coordinator.setPendingScroll(.fraction(1), in: webView)
        preview.coordinator.runFindWhenReady("Paragraph 200.", in: webView)
        preview.coordinator.webView(webView, didFinish: superseded)

        XCTAssertFalse(preview.coordinator.isLoaded)
        // Scripts run in order, so anything the finish sent has run by this one.
        XCTAssertEqual(try preview.page.evaluate("[!!\(typography), !!\(found)].join(' ')") as? String, "false false")

        XCTAssertTrue(gate.waitForHeld(1))
        gate.open()
        XCTAssertTrue(preview.waitForLoad())
        XCTAssertTrue(try preview.page.waitFor("\(typography) && \(found) && window.scrollY > 0"))
    }

    // MARK: - Reload

    /// The web view's own context menu has a Reload, and its page has to count
    /// as finished, or the preview stays unloaded.
    @MainActor
    func testAReloadFinishesLikeAnyLoad() throws {
        try skipUnlessGUITestsEnabled()
        let preview = try HeldPreview(test: self, text: "- [ ] A")
        defer { preview.close() }
        let typography = "document.getElementById('md2-typography')"
        _ = try preview.page.evaluate("\(typography).remove(); true")

        preview.page.webView.reload()

        XCTAssertTrue(try preview.page.waitFor("\(typography) !== null"))
        XCTAssertTrue(preview.coordinator.isLoaded)
    }

    /// A live update goes into the page, not into the page WebKit would reload,
    /// which is still the last full load's.
    @MainActor
    func testReloadAfterALiveEditShowsTheNewestTextAndItsBoxesWork() throws {
        try skipUnlessGUITestsEnabled()
        let preview = try HeldPreview(test: self, text: "Intro.\n\n- [ ] A")
        defer { preview.close() }

        preview.store.text = "Edited.\n\n- [ ] A"
        try preview.catchUp()
        XCTAssertTrue(try preview.page.waitForRevision(preview.store.sourceLineRevision))
        XCTAssertEqual(try preview.page.evaluate("document.body.textContent.includes('Edited.')") as? Bool, true,
                       "precondition: the edit went in place")

        try preview.reload()

        XCTAssertEqual(try preview.page.isolated("""
            String(window.__md2SourceLineRevision) + ' ' + document.body.textContent.includes('Edited.')
            """) as? String, "\(preview.store.sourceLineRevision) true")
        try preview.page.click(firstBox)
        XCTAssertTrue(preview.waitForClicks(1))
        XCTAssertEqual(preview.store.text, "Edited.\n\n- [x] A")
    }

    /// A page that had no edit is a new page after a Reload all the same, and
    /// its revision is the one the old page already carried.
    @MainActor
    func testReloadWithNoEditKeepsTheBoxesWorking() throws {
        try skipUnlessGUITestsEnabled()
        let preview = try HeldPreview(test: self, text: "- [ ] A", liveUpdate: false)
        defer { preview.close() }

        try preview.reload()

        XCTAssertTrue(try preview.page.waitForRevision(preview.store.sourceLineRevision))
        try preview.page.click(firstBox)
        XCTAssertTrue(preview.waitForClicks(1))
        XCTAssertEqual(preview.store.text, "- [x] A")
    }

    /// WebKit restores the place of a page the user scrolled, so a load in its
    /// place has to as well. The new page starts at the top on its way there,
    /// and reporting that would take the outline with it.
    @MainActor
    func testReloadKeepsTheReadersPlace() throws {
        try skipUnlessGUITestsEnabled()
        let text = (1...200).map { "Paragraph \($0)." }.joined(separator: "\n\n")
        let preview = try HeldPreview(test: self, text: text)
        defer { preview.close() }
        // The page scrolls to its place on animation frames, which a window off
        // the screen never gets. A user script, since the page will be new.
        preview.page.webView.configuration.userContentController.addUserScript(WKUserScript(
            source: "window.requestAnimationFrame = function (callback) { return setTimeout(callback, 16); };",
            injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        _ = try preview.page.evaluate("window.scrollTo(0, document.documentElement.scrollHeight / 2); true")
        // The report of this scroll comes first, or it would use up the one
        // report a Reload has suppressed.
        XCTAssertTrue(preview.waitForAnchor { $0.scrollFraction > 0 })
        let place = try XCTUnwrap(preview.page.evaluate("window.scrollY") as? Double)
        preview.anchors = []

        try preview.reload()

        XCTAssertTrue(try preview.page.waitFor("Math.abs(window.scrollY - \(place)) < 40"),
                      "the page must come back near \(place)")
        XCTAssertEqual(preview.anchors.filter { $0.scrollFraction == 0 }.count, 0,
                       "the top of the page is no place the reader went")
    }

    /// The new page's blocks have no keys yet, so its first live update has to
    /// send the body to key them from, or it replaces every block.
    @MainActor
    func testEditAfterAReloadKeepsTheBlocksItDidNotChange() throws {
        try skipUnlessGUITestsEnabled()
        let preview = try HeldPreview(test: self, text: "Intro.\n\n- [ ] A")
        defer { preview.close() }
        preview.store.text = "Edited.\n\n- [ ] A"
        try preview.catchUp()
        XCTAssertTrue(try preview.page.waitForRevision(preview.store.sourceLineRevision))
        try preview.reload()
        _ = try preview.page.evaluate("window.__list = document.querySelector('main > ul'); true")

        preview.store.text = "Newest.\n\n- [ ] A"
        try preview.catchUp()

        XCTAssertTrue(try preview.page.waitFor("document.body.textContent.includes('Newest.')"))
        XCTAssertEqual(try preview.page.evaluate("document.querySelector('main > ul') === window.__list") as? Bool, true,
                       "the list did not change, so it stays")
    }

    /// The marks are in the page, so a new page needs the search run again, or
    /// the find bar counts matches nothing shows.
    @MainActor
    func testReloadRunsTheSearchAgain() throws {
        try skipUnlessGUITestsEnabled()
        let preview = try HeldPreview(test: self, text: "Needle.", findQuery: "Needle")
        defer { preview.close() }
        let found = "document.querySelector('mark.md2-find') !== null"
        XCTAssertTrue(try preview.page.waitFor(found))

        try preview.reload()

        XCTAssertTrue(try preview.page.waitFor(found))
    }

    /// A Reload can stop a load that is still at its policy decision, and it
    /// asks for the page that load is about to replace. The newest text has to
    /// land anyway, or the preview is left on the older page for good.
    @MainActor
    func testReloadDuringALoadStillLandsTheNewestText() throws {
        try skipUnlessGUITestsEnabled()
        let preview = try HeldPreview(test: self, text: "Intro.\n\n- [ ] A")
        defer { preview.close() }
        let gate = NavigationGate(in: preview)
        defer { gate.open() }
        _ = try preview.page.evaluate("window.__olderPage = true; true")

        // A new diagram engine takes a full load, which stops at the gate.
        preview.store.text = "Newest.\n\n```mermaid\ngraph TD; A-->B;\n```"
        try preview.catchUp()
        XCTAssertTrue(gate.waitForHeld(1))
        preview.page.webView.reload()
        XCTAssertTrue(gate.waitForHeld(2))
        gate.open()

        XCTAssertTrue(try preview.page.waitFor("window.__olderPage !== true"))
        XCTAssertTrue(preview.waitForLoad())
        XCTAssertEqual(try preview.page.isolated("""
            String(window.__md2SourceLineRevision) + ' ' + document.body.textContent.includes('Newest.')
            """) as? String, "\(preview.store.sourceLineRevision) true")
    }

    /// The label lives in the isolated world. Page script must not be able to
    /// read it, and with no DOM trace it has nothing to rewrite either.
    @MainActor
    func testRevisionIsOutOfPageScriptsReach() throws {
        try skipUnlessGUITestsEnabled()
        let preview = try HeldPreview(test: self, text: "- [ ] A")
        defer { preview.close() }
        XCTAssertTrue(try preview.page.waitForRevision(preview.store.sourceLineRevision))

        XCTAssertEqual(try preview.page.evaluate("typeof window.__md2SourceLineRevision") as? String, "undefined")
        XCTAssertEqual(try preview.page.evaluate("""
            Array.from(document.querySelectorAll('*')).some(function (node) {
                return Array.from(node.attributes).some(function (attribute) { return /revision/i.test(attribute.name); });
            })
            """) as? Bool, false)
        XCTAssertFalse(preview.store.rendered.html.contains("__md2SourceLineRevision"))
    }

    /// Writing the label in the page world labels nothing, so a page script
    /// cannot pass a stale click off as current.
    @MainActor
    func testPageScriptCannotForgeTheRevision() throws {
        try skipUnlessGUITestsEnabled()
        let preview = try HeldPreview(test: self, text: "- [ ] A\n- [ ] B")
        defer { preview.close() }

        preview.store.text = "- [ ] N\n- [ ] A\n- [ ] B"
        _ = try preview.page.evaluate("window.__md2SourceLineRevision = \(preview.store.sourceLineRevision); true")
        try preview.page.click(firstBox)
        XCTAssertTrue(preview.waitForClicks(1))

        XCTAssertEqual(preview.store.text, "- [ ] N\n- [ ] A\n- [ ] B")
    }

    /// Nothing says what a line means on a page without a label, which is what
    /// a click would meet between the end of parsing and the label's arrival.
    @MainActor
    func testClickWithoutARevisionPutsTheBoxBack() throws {
        try skipUnlessGUITestsEnabled()
        let preview = try HeldPreview(test: self, text: "- [ ] A")
        defer { preview.close() }

        _ = try preview.page.isolated("delete window.__md2SourceLineRevision; true")
        try preview.page.watchClicks()
        try preview.page.click(firstBox)

        XCTAssertTrue(try preview.page.waitFor("window.__clickedTo === true"), "the click must flip the box first")
        XCTAssertTrue(try preview.page.waitFor("\(firstBox).checked === false"))
        XCTAssertEqual(preview.clicks, 0, "the document is never asked")
        XCTAssertEqual(preview.store.text, "- [ ] A")
    }

    // MARK: - The real window

    /// `ContentView` owns the last step of the refusal, after its viewport
    /// capture. An old label stands in for a page behind the text, which the
    /// window's own debounces would otherwise race.
    @MainActor
    func testContentViewPutsARefusedBoxBack() throws {
        try skipUnlessGUITestsEnabled()
        let host = try TaskWindow(text: "- [ ] A\n- [ ] B", mode: .read, test: self)
        defer { host.close() }
        let text = host.store.text

        _ = try host.page.isolated("window.__md2SourceLineRevision = -1; true")
        try host.page.watchClicks()
        try host.page.click(firstBox)

        XCTAssertTrue(try host.page.waitFor("window.__clickedTo === true"), "the click must flip the box first")
        XCTAssertTrue(try host.page.waitFor("\(firstBox).checked === false"))
        XCTAssertEqual(host.store.text, text)
        XCTAssertEqual(host.store.undoManager.canUndo, false, "a refused click leaves no undo step")
    }

    /// A click on a current page is one undo step, and its box stays checked.
    @MainActor
    func testContentViewClickOnACurrentPageIsOneUndoStep() throws {
        try skipUnlessGUITestsEnabled()
        let host = try TaskWindow(text: "- [ ] A\n- [ ] B", mode: .split, test: self)
        defer { host.close() }

        try host.page.click(firstBox)
        host.spin(until: { host.store.text == "- [x] A\n- [ ] B" })
        XCTAssertEqual(host.store.text, "- [x] A\n- [ ] B")
        XCTAssertTrue(try host.page.waitFor("\(firstBox).checked === true && \(firstBox).hasAttribute('checked')"))

        host.store.undoManager.undo()
        XCTAssertEqual(host.store.text, "- [ ] A\n- [ ] B")
        XCTAssertEqual(host.store.undoManager.canUndo, false)
    }

    private func skipUnlessGUITestsEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed test."
        )
    }
}

/// Scripts and real mouse events for one web view.
@MainActor private struct PreviewPage {
    let test: XCTestCase
    let webView: WKWebView

    func evaluate(_ script: String) throws -> Any? {
        let done = test.expectation(description: "page script")
        var output: Any?
        var failure: Error?
        webView.evaluateJavaScript(script) { value, error in
            output = value
            failure = error
            done.fulfill()
        }
        test.wait(for: [done], timeout: 5)
        if let failure { throw failure }
        return output
    }

    /// `script` must end in a value: a script that yields `undefined` traps in
    /// WebKit's `Result` overlay.
    func isolated(_ script: String) throws -> Any? {
        let done = test.expectation(description: "isolated script")
        nonisolated(unsafe) var outcome: Result<Any, Error>?
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
            outcome = result
            done.fulfill()
        }
        test.wait(for: [done], timeout: 5)
        return try outcome?.get()
    }

    /// Waits for the page's label to read `revision`. Native sets it only once
    /// that revision's content is in the page.
    func waitForRevision(_ revision: Int) throws -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if try isolated("String(window.__md2SourceLineRevision)") as? String == String(revision) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return false
    }

    /// Records the state a click gave its box in `__clickedTo`: a box that went
    /// back looks exactly like a box that was never clicked.
    func watchClicks() throws {
        _ = try evaluate("""
            document.addEventListener('click', function (event) { window.__clickedTo = event.target.checked; }, true);
            true
            """)
    }

    func waitFor(_ condition: String) throws -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if try evaluate("(function () { try { return !!(\(condition)); } catch (e) { return false; } })()") as? Bool == true {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return false
    }

    /// Clicks the center of the element `expression` yields, so the page sees a
    /// trusted click. It waits until the element stops moving: a window settles
    /// after its page loads, and a box is a small target for a reflow to take
    /// away. The events go to the web view itself: the test process cannot make
    /// a window key, and a window that is not key may spend the first click on
    /// activating itself.
    func click(_ expression: String) throws {
        let window = try XCTUnwrap(webView.window)
        var box = try center(of: expression)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let next = try center(of: expression)
            if next == box { break }
            box = next
        }
        let y = webView.isFlipped ? box[1] : Double(webView.bounds.height) - box[1]
        let location = webView.convert(NSPoint(x: box[0], y: y), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ))
            if type == .leftMouseDown { webView.mouseDown(with: event) } else { webView.mouseUp(with: event) }
        }
    }

    private func center(of expression: String) throws -> [Double] {
        try XCTUnwrap(
            evaluate("(function () { var r = (\(expression)).getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()") as? [Double],
            "no element for \(expression)"
        )
    }
}

/// A preview of a real document that shows the text it was last given and
/// nothing newer, however the document moves on, until `catchUp`. The click
/// handling is `ContentView`'s without the viewport capture.
@MainActor private final class HeldPreview {
    let store = DocumentStore()
    let viewport = PreviewViewportReader()
    private let test: XCTestCase
    private let liveUpdate: Bool
    private let findQuery: String
    private let focusToken = UUID()
    private var hosting: NSHostingView<MarkdownPreviewView>!
    private let window: NSWindow
    private(set) var page: PreviewPage!
    private(set) var coordinator: MarkdownPreviewView.Coordinator!
    /// The clicks that reached the document.
    private(set) var clicks = 0
    /// The places the page reported, latest last.
    var anchors: [ViewportAnchor] = []
    /// Keeps refusals back until `releaseRefusals`, to order one after an update.
    var holdsRefusals = false
    private var heldRefusals: [() -> Void] = []

    init(test: XCTestCase, text: String, liveUpdate: Bool = true, findQuery: String = "") throws {
        _ = NSApplication.shared
        self.test = test
        self.liveUpdate = liveUpdate
        self.findQuery = findQuery
        window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 700, height: 900),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.text = text
        flushRender()
        let hosting = NSHostingView(rootView: preview())
        self.hosting = hosting
        window.contentView = hosting
        window.orderFrontRegardless()
        _ = Self.spin { Self.webView(in: hosting) != nil }
        let webView = try XCTUnwrap(Self.webView(in: hosting), "the preview never created its web view")
        coordinator = try XCTUnwrap(webView.navigationDelegate as? MarkdownPreviewView.Coordinator)
        page = PreviewPage(test: test, webView: webView)
        XCTAssertTrue(waitForLoad(), "the preview never finished its first load")
    }

    /// Hands the preview what the document renders to now.
    func catchUp() throws {
        flushRender()
        hosting.rootView = preview()
    }

    func waitForLoad() -> Bool {
        Self.spin { self.coordinator.isLoaded }
    }

    /// Reloads the way the web view's context menu does, and waits for the page
    /// that brings. The mark is how a new page tells from the one it replaced.
    func reload() throws {
        _ = try page.evaluate("window.__beforeReload = true; true")
        page.webView.reload()
        XCTAssertTrue(try page.waitFor("window.__beforeReload !== true"), "the Reload never brought a new page")
        XCTAssertTrue(waitForLoad())
    }

    /// Waits for the view update that gives the coordinator the current render.
    func waitForHandOver() -> Bool {
        Self.spin { self.coordinator.lastHTML == self.store.rendered.html }
    }

    func waitForClicks(_ count: Int) -> Bool {
        Self.spin { self.clicks >= count }
    }

    func waitForAnchor(_ condition: (ViewportAnchor) -> Bool) -> Bool {
        Self.spin { self.anchors.contains(where: condition) }
    }

    func releaseRefusals() {
        heldRefusals.forEach { $0() }
        heldRefusals = []
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }

    private func flushRender() {
        let flushed = test.expectation(description: "render")
        Task { [store] in
            await store.flushPendingRender()
            flushed.fulfill()
        }
        test.wait(for: [flushed], timeout: 15)
    }

    private func preview() -> MarkdownPreviewView {
        MarkdownPreviewView(
            html: store.rendered.html, bodyHTML: store.rendered.body, mathMacros: store.rendered.mathMacros,
            baseURL: nil, liveUpdate: liveUpdate, sourceLineRevision: store.renderedSourceLineRevision,
            jumpHeadingID: .constant(nil), jumpFraction: .constant(nil), jumpAnchor: .constant(nil),
            viewportReader: viewport,
            onAnchorChange: { [weak self] anchor, _ in self?.anchors.append(anchor) },
            onToggleTask: { [weak self] line, checked, revision, restoreBoxes in
                guard let self else { return }
                self.clicks += 1
                guard !self.store.toggleTask(atLine: line, to: checked, renderedAt: revision) else { return }
                if self.holdsRefusals {
                    self.heldRefusals.append(restoreBoxes)
                } else {
                    restoreBoxes()
                }
            },
            findQuery: .constant(findQuery), findNavigation: .constant(nil), focusToken: focusToken
        )
    }

    private static func webView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { webView(in: $0) }.first
    }

    fileprivate static func spin(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return predicate()
    }
}

/// Stands in front of the coordinator and keeps each navigation at its policy
/// decision until `open`, so a load that takes its time is a state rather than
/// a race against the rewrite ahead of it. The rest goes straight through.
@MainActor private final class NavigationGate: NSObject, WKNavigationDelegate {
    private let coordinator: MarkdownPreviewView.Coordinator
    private var decisions: [() -> Void] = []
    private var isOpen = false

    init(in preview: HeldPreview) {
        coordinator = preview.coordinator
        super.init()
        preview.page.webView.navigationDelegate = self
    }

    func waitForHeld(_ count: Int) -> Bool {
        HeldPreview.spin { self.decisions.count >= count }
    }

    /// A test must get here: WebKit raises over a decision nobody made.
    func open() {
        isOpen = true
        decisions.forEach { $0() }
        decisions = []
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let decide = { [coordinator] in
            coordinator.webView(webView, decidePolicyFor: navigationAction, decisionHandler: decisionHandler)
        }
        if isOpen {
            decide()
        } else {
            decisions.append(decide)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        coordinator.webView(webView, didCommit: navigation)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        coordinator.webView(webView, didFinish: navigation)
    }
}

/// The real `ContentView` in a window, with the document's own undo manager.
@MainActor private final class TaskWindow: NSObject, NSWindowDelegate {
    private let suite = "PreviewTaskToggleGUITests-\(UUID())"
    let store = DocumentStore()
    private let settings: AppSettings
    private let window: NSWindow
    private let hosting: NSHostingView<ContentView>
    private(set) var page: PreviewPage!

    init(text: String, mode: EditorMode, test: XCTestCase) throws {
        _ = NSApplication.shared
        settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.language = .english
        settings.newDocumentMode = mode
        settings.showsOutlineByDefault = false
        store.text = text
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        hosting = NSHostingView(rootView: ContentView(document: store, settings: settings, onOpen: {}))
        super.init()
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.delegate = self
        window.contentView = hosting
        window.orderFrontRegardless()
        spin(until: { self.webView() != nil }, timeout: 10)
        let webView = try XCTUnwrap(self.webView(), "the preview never mounted")
        page = PreviewPage(test: test, webView: webView)
        // The window can open on the starter document, which has boxes of its
        // own, and the document's page then replaces it, taking along anything
        // a test put on the first page. Only the label says which page this is.
        XCTAssertTrue(try page.waitForRevision(store.sourceLineRevision), "the document's page never arrived")
        XCTAssertTrue(try page.waitFor("!!document.querySelector('input[data-md2-task-line]')"))
        // Layout settles after the first page, and a click must not miss a box
        // that moved between measuring and clicking.
        spin(0.6)
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { store.undoManager }

    private func webView(in view: NSView? = nil) -> WKWebView? {
        let view = view ?? hosting
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { self.webView(in: $0) }.first
    }

    func spin(_ duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    func spin(until condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { spin(0.02) }
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.delegate = nil
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}
