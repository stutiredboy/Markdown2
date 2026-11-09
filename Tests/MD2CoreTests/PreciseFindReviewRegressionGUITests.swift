// GUI regressions promoted from the independent C-package review.
import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import MD2App
@testable import MD2Core

final class PreciseFindReviewRegressionGUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1", "review GUI lease required")
    }

    @MainActor func testHardBreakIsAWordBoundaryInRenderedSearch() throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        harness.settings.newDocumentMode = .read
        harness.store.text = "foo  \nbar"
        harness.host(ContentView(document: harness.store, settings: harness.settings, onOpen: {}))
        let web = try XCTUnwrap(harness.descendants(WKWebView.self).first)
        try harness.waitForPage("!!document.querySelector('main br') && typeof window.__md2FindSnapshot === 'function'", in: web, context: "hard break rendered")
        let snapshot = try XCTUnwrap(try harness.js("window.__md2FindSnapshot().text", web) as? String)
        print("REVIEW hard break snapshot", snapshot.debugDescription)
        XCTAssertEqual(TextSearch.matches(of: "foo", in: harness.store.text, options: .init(wholeWord: true)).count, 1)
        XCTAssertEqual(PreviewTextSearch.ranges(query: "foo", text: snapshot, options: .init(wholeWord: true))?.count, 1)
        XCTAssertEqual(PreviewTextSearch.ranges(query: "foobar", text: snapshot, options: .init())?.count, 0)
        harness.store.editorSession.find.options.wholeWord = true
        harness.store.requestFind(.show)
        harness.spin(until: { harness.queryField != nil })
        try harness.enterQuery("foo")
        try harness.waitForPage("document.querySelectorAll('mark.md2-find').length === 1 && document.querySelector('mark.md2-find').textContent === 'foo'", in: web, context: "native search matches before a hard break")
        try harness.enterQuery("foobar")
        try harness.waitForPage("document.querySelectorAll('mark.md2-find').length === 0", in: web, context: "native search cannot invent a word across BR")
    }

    @MainActor func testSnapshotNodeBudgetAndEmptyQueryReset() throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        harness.settings.newDocumentMode = .read
        harness.store.text = "needle"
        harness.host(ContentView(document: harness.store, settings: harness.settings, onOpen: {}))
        let web = try XCTUnwrap(harness.descendants(WKWebView.self).first)
        try harness.waitForPage("typeof window.__md2FindSnapshot === 'function'", in: web, context: "API ready")
        _ = try harness.js("const main = document.querySelector('main'); main.replaceChildren(); for(let i=0;i<20001;i++){ const s=document.createElement('span'); s.textContent='x'; main.appendChild(s); } true;", web)
        XCTAssertEqual(try harness.js("window.__md2FindSnapshot().unavailable", web) as? Bool, true)
        harness.store.requestFind(.show)
        harness.spin(until: { harness.queryField != nil })
        try harness.enterQuery("x")
        harness.spin(until: { harness.store.editorSession.find.previewUnavailable })
        XCTAssertTrue(harness.store.editorSession.find.previewUnavailable)
        try harness.enterQuery("")
        harness.spin(until: { !harness.store.editorSession.find.previewUnavailable })
        XCTAssertFalse(harness.store.editorSession.find.previewUnavailable)
    }

    @MainActor func testRealReplaceClickThenSourceMutationCancels() throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        harness.store.text = "cat cat"
        harness.host(ContentView(document: harness.store, settings: harness.settings, onOpen: {}))
        harness.store.requestFind(.showReplace)
        harness.spin(until: { harness.queryField != nil })
        try harness.enterQuery("cat")
        let field = try XCTUnwrap(harness.descendants(NSTextField.self).first { $0.placeholderString == harness.settings.text(.replace) })
        XCTAssertTrue(harness.window.makeFirstResponder(field))
        try XCTUnwrap(field.currentEditor()).insertText("dog")
        harness.spin(until: { field.stringValue == "dog" })
        let row = field.convert(field.bounds, to: nil)
        let button = try XCTUnwrap(harness.descendants(NSButton.self).filter { let f = $0.convert($0.bounds, to: nil); return f.midY >= row.minY && f.midY <= row.maxY && f.minX >= row.maxX }.max { $0.convert($0.bounds,to:nil).midX < $1.convert($1.bounds,to:nil).midX })
        harness.spin(until: { button.isEnabled })
        // Hold the production scheduling boundary: performClick may itself
        // spin AppKit's run loop. Only the queued closure is delayed; the native
        // button, click-time snapshot and all execution guards remain real.
        let session = harness.store.editorSession
        let originalScheduler = session.scheduleFindReplacement
        defer { session.scheduleFindReplacement = originalScheduler }
        var pending: (@MainActor () -> Void)?
        var queuedCount = 0
        session.scheduleFindReplacement = { queuedCount += 1; pending = $0 }
        button.performClick(nil)
        harness.spin(until: { pending != nil })
        let performPending = try XCTUnwrap(pending)
        XCTAssertEqual(queuedCount, 1, "one real button action queues one production replacement closure")
        let editor = try XCTUnwrap(session.textView)
        editor.insertText("!", replacementRange: NSRange(location: 0, length: 0))
        performPending()
        pending = nil
        harness.spin(until: { harness.store.editorSession.find.replacementCancelled })
        XCTAssertTrue(harness.store.editorSession.find.replacementCancelled)
        XCTAssertEqual(harness.store.text, "!cat cat")
        // Wait for the source edit's actual render publication, so the token
        // has also survived the resulting SwiftUI updates without re-enqueueing.
        harness.spin(until: { harness.store.renderedSourceLineRevision == harness.store.sourceLineRevision })
        XCTAssertEqual(harness.store.renderedSourceLineRevision, harness.store.sourceLineRevision)
        XCTAssertEqual(queuedCount, 1, "a consumed command must not be scheduled again by the edit/result re-render")
        XCTAssertNil(pending, "the harness released the queued production closure exactly once")
        XCTAssertTrue(harness.store.editorSession.find.replacementCancelled)
        XCTAssertEqual(harness.store.text, "!cat cat")
    }

    @MainActor func testLateNavigationCallbackCannotOverwriteNewQueryResult() throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        let web = HeldFindNavigationResultWebView(frame: .zero)
        let coordinator = MarkdownPreviewView.Coordinator()
        var observed: [(Int, Int)] = []
        coordinator.onFindResult = { observed.append(($0, $1)) }
        _ = try harness.js("window.__md2Find = q => ({total:q === 'old' ? 9 : 1,index:1}); window.__md2FindNext = forward => ({total:9,index:2}); true;", web)
        coordinator.lastFindQuery = "old"
        coordinator.runFindWhenReady("old", in: web)
        coordinator.webView(web, didFinish: nil)
        harness.spin(until: { observed.last?.0 == 9 })
        XCTAssertEqual(observed.last?.0, 9)
        web.holdNavigation = true
        coordinator.handleFindNavigation(.next, in: web)
        harness.spin(until: { web.heldResult != nil })
        XCTAssertNotNil(web.heldResult)
        coordinator.lastFindQuery = "new"
        coordinator.runFindWhenReady("new", in: web)
        harness.spin(until: { observed.last?.0 == 1 })
        XCTAssertEqual(observed.last?.0, 1)
        web.heldResult?()
        print("REVIEW late navigation results", observed)
        XCTAssertEqual(observed.last?.0, 1, "Old generation callback must not replace current query count")
        XCTAssertEqual(observed.last?.1, 1, "Old generation callback must not replace current query index")
    }

    @MainActor func testOptionsReloadAndHostInvalidateOldNavigationWithoutLosingCurrentQueue() throws {
        for change in ["options", "reload", "host"] {
            let harness = InteractionTestWindow()
            defer { harness.close() }
            let coordinator = MarkdownPreviewView.Coordinator()
            let configuration = WKWebViewConfiguration()
            coordinator.documentLoader.install(on: configuration)
            let oldWeb = HeldFindNavigationResultWebView(frame: .zero, configuration: configuration)
            oldWeb.navigationDelegate = coordinator
            var web: WKWebView = oldWeb
            var observed: [(Int, Int)] = []
            coordinator.onFindResult = { observed.append(($0, $1)) }
            let script = """
                window.searchTotal = 9; window.searchIndex = 1;
                window.__md2Find = q => { window.searchIndex = 1; return {total:window.searchTotal,index:window.searchIndex}; };
                window.__md2FindNext = forward => {
                    window.searchIndex = ((window.searchIndex - 1 + (forward ? 1 : -1) + window.searchTotal) % window.searchTotal) + 1;
                    return {total:window.searchTotal,index:window.searchIndex};
                };
                true;
                """
            _ = try harness.js(script, oldWeb)
            coordinator.lastFindQuery = "needle"
            coordinator.runFindWhenReady("needle", in: oldWeb)
            coordinator.webView(oldWeb, didFinish: nil)
            harness.spin(until: { observed.last?.0 == 9 })
            XCTAssertEqual(observed.last?.1, 1, change)
            oldWeb.holdNavigation = true
            coordinator.handleFindNavigation(.next, in: oldWeb)
            harness.spin(until: { oldWeb.heldResult != nil })
            let late = try XCTUnwrap(oldWeb.heldResult)
            oldWeb.holdNavigation = false
            oldWeb.heldResult = nil
            let beforeCurrent = observed.count

            switch change {
            case "options":
                _ = try harness.js("window.searchTotal = 3; true;", web)
                coordinator.findOptions.wholeWord = true
                coordinator.runFindWhenReady("needle", in: web)
            case "reload":
                coordinator.beginLoading()
                coordinator.runFindWhenReady("needle", in: web)
                coordinator.documentLoader.load("<html><head><script>" + script.replacingOccurrences(of: "searchTotal = 9", with: "searchTotal = 3") + "</script></head><body>new page</body></html>", baseURL: nil, in: web)
            default:
                MarkdownPreviewView.dismantleNSView(oldWeb, coordinator: coordinator)
                let countAtDetach = observed.count
                late()
                XCTAssertEqual(observed.count, countAtDetach, "detached host must not publish a pending completion")
                web = WKWebView(frame: .zero)
                _ = try harness.js(script.replacingOccurrences(of: "searchTotal = 9", with: "searchTotal = 3"), web)
                coordinator.attachFindHost(web)
                coordinator.runFindWhenReady("needle", in: web)
            }
            // These are current-generation commands, queued behind the new
            // search/page. All three must run once and in order.
            coordinator.handleFindNavigation(.next, in: web)
            coordinator.handleFindNavigation(.next, in: web)
            coordinator.handleFindNavigation(.previous, in: web)
            harness.spin(until: { observed.count == beforeCurrent + 4 })
            XCTAssertEqual(observed.count, beforeCurrent + 4, change)
            XCTAssertEqual(Array(observed.suffix(4)).map { $0.0 }, [3, 3, 3, 3], change)
            XCTAssertEqual(Array(observed.suffix(4)).map { $0.1 }, [1, 2, 3, 2], change)
            let acceptedCount = observed.count
            late()
            XCTAssertEqual(observed.count, acceptedCount, "\(change): old completion must not publish")
            XCTAssertEqual(observed.last?.0, 3, change)
            XCTAssertEqual(observed.last?.1, 2, change)
            coordinator.handleFindNavigation(.next, in: web)
            harness.spin(until: { observed.count == acceptedCount + 1 })
            XCTAssertEqual(observed.last?.1, 3, "\(change): current navigation must remain usable")
        }
    }

}

@MainActor
private final class HeldFindNavigationResultWebView: WKWebView {
    var holdNavigation = false
    var heldResult: (() -> Void)?
    override func evaluateJavaScript(_ javaScriptString: String, completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)? = nil) {
        if holdNavigation && javaScriptString.contains("__md2FindNext") {
            super.evaluateJavaScript(javaScriptString) { [weak self] result, error in
                self?.heldResult = { completionHandler?(result, error) }
            }
        } else { super.evaluateJavaScript(javaScriptString, completionHandler: completionHandler) }
    }
}
