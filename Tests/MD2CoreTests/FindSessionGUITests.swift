import AppKit
import Network
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

final class FindSessionGUITests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 to run interaction GUI tests.")
    }

    @MainActor
    func testUnchangedFindFieldFocusRoutesMenuNavigationToItsSplitPane() throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        harness.settings.newDocumentMode = .split
        harness.store.text = "needle one\n\nneedle two\n\nneedle three"
        harness.host(ContentView(document: harness.store, settings: harness.settings, onOpen: {}))
        try waitForNative(harness, "both native split panes are mounted") {
            harness.store.editorSession.textView?.window === harness.window
                && harness.descendants(WKWebView.self).contains { $0.window === harness.window }
        }
        let editor = try XCTUnwrap(harness.store.editorSession.textView)
        let web = try XCTUnwrap(harness.descendants(WKWebView.self).first)
        harness.store.requestFind(.show)
        try waitForNative(harness, "source query field is focused") {
            guard let fieldEditor = harness.queryField?.currentEditor() else { return false }
            return fieldEditor === harness.window.firstResponder
        }
        try harness.enterQuery("needle")
        try waitForSourceMatch(endingAt: 6, in: harness)
        let show = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                   timestamp: 0, windowNumber: harness.window.windowNumber, context: nil,
                                   characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
        XCTAssertTrue(web.performKeyEquivalent(with: show))
        try harness.waitForPage("""
            document.querySelector('main')?.textContent.includes('needle three') &&
            document.querySelectorAll('mark.md2-find').length === 3 &&
            document.querySelectorAll('mark.md2-find')[0].classList.contains('md2-find-current')
            """, in: web, context: "split preview restores its query before menu navigation")
        try waitForNative(harness, "both pane queries are restored and the preview field is focused") {
            let fields = harness.descendants(NSTextField.self).filter { $0.placeholderString == harness.settings.text(.findPlaceholder) }
            let previewField = fields.max { $0.convert($0.bounds, to: nil).midX < $1.convert($1.bounds, to: nil).midX }
            guard let fieldEditor = previewField?.currentEditor() else { return false }
            return fields.count == 2 && fields.allSatisfy { $0.stringValue == "needle" }
                && fieldEditor === harness.window.firstResponder
        }
        harness.store.requestFind(.next)
        let index = "Array.from(document.querySelectorAll('mark.md2-find')).findIndex(e=>e.classList.contains('md2-find-current'))"
        try harness.waitForPage("\(index) === 1", in: web, context: "split preview advances to the second match")
        XCTAssertEqual(try harness.js(index, web) as? Int, 1)
        let fields = harness.descendants(NSTextField.self).filter { $0.placeholderString == harness.settings.text(.findPlaceholder) }
        XCTAssertEqual(fields.count, 2)
        let sourceField = try XCTUnwrap(fields.min { $0.convert($0.bounds, to: nil).midX < $1.convert($1.bounds, to: nil).midX })
        XCTAssertTrue(harness.window.makeFirstResponder(sourceField))
        // A user's next menu action is a later event. Let the native focus
        // notification reach SwiftUI before dispatching that separate action;
        // currentEditor itself changes synchronously in makeFirstResponder.
        var focusEventDelivered = false
        DispatchQueue.main.async { focusEventDelivered = true }
        try waitForNative(harness, "unchanged source query field owns the keyboard") {
            guard let fieldEditor = sourceField.currentEditor() else { return false }
            return focusEventDelivered && fieldEditor === harness.window.firstResponder && sourceField.stringValue == "needle"
        }
        XCTAssertTrue(sourceField.currentEditor() === harness.window.firstResponder, "source find field must own keyboard")
        // Merely refocus the unchanged query. No binding setter fires here.
        harness.store.requestFind(.next)
        try waitForSourceMatch(endingAt: 18, in: harness)
        XCTAssertEqual(editor.selectedRange().location, 18)
        XCTAssertEqual(try harness.js(index, web) as? Int, 1, "menu navigation must leave the other pane's match alone")
    }

    @MainActor
    func testPreviewNavigationWaitsForPendingSearchAfterModeSwitch() throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        let web = WKWebView(frame: .zero)
        let coordinator = MarkdownPreviewView.Coordinator()
        var resultCount = 0
        coordinator.onFindResult = { _, _ in resultCount += 1 }
        // Real WebKit, held before didFinish, with the same page API contract.
        _ = try harness.js("""
            window.index = 0;
            window.__md2Find = function(q) { window.index = 1; return {total:3,index:window.index}; };
            window.__md2FindNext = function(forward) { window.index += forward ? 1 : -1; return {total:3,index:window.index}; };
            true;
            """, web)
        coordinator.runFindWhenReady("needle", in: web)
        coordinator.handleFindNavigation(.next, in: web)
        coordinator.handleFindNavigation(.next, in: web)
        coordinator.handleFindNavigation(.previous, in: web)
        XCTAssertEqual(try harness.js("window.index", web) as? Int, 0, "navigation must wait for the incoming page's matches")
        coordinator.webView(web, didFinish: nil)
        try waitForNative(harness, "the pending search and three navigations all returned") { resultCount == 4 }
        try harness.waitForPage("window.index === 2", in: web, context: "queued navigation completes after didFinish", requireLoaded: false)
        XCTAssertEqual(try harness.js("window.index", web) as? Int, 2, "queued commands execute once and in order after search")
    }

    @MainActor
    func testHiddenFindSurvivesAnActuallyDelayedPageLoad() throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        let server = try HeldFindImageServer()
        defer { server.stop() }
        try waitForNative(harness, "loopback load barrier is listening") { server.port != nil }
        let port = try XCTUnwrap(server.port)
        let original = "needle one\n\nneedle two\n\nneedle three\n\n![load barrier](http://127.0.0.1:\(port)/held.png)"
        harness.store.text = original
        harness.host(ContentView(document: harness.store, settings: harness.settings, onOpen: {}))
        harness.store.requestFind(.show)
        try waitForNative(harness, "source query field is focused") {
            guard let fieldEditor = harness.queryField?.currentEditor() else { return false }
            return fieldEditor === harness.window.firstResponder
        }
        try harness.enterQuery("needle")
        try waitForSourceMatch(endingAt: 6, in: harness)
        try harness.press(.closeFind)
        harness.store.requestMode(.read)
        try waitForNative(harness, "Read preview is mounted") { !harness.descendants(WKWebView.self).isEmpty }
        let web = try XCTUnwrap(harness.descendants(WKWebView.self).first)
        // Hold an actual image response, so the current document has parsed but
        // WebKit cannot send didFinish. No fake find implementation or timers.
        try harness.waitForPage("document.querySelector('main')?.textContent.includes('needle three') && typeof window.__md2Find === 'function'",
                                in: web, context: "delayed current document parsed", requireLoaded: false)
        try waitForNative(harness, "WebKit reached the held image request") { server.hasRequest }
        XCTAssertTrue(server.hasRequest)
        XCTAssertTrue(web.isLoading)
        let coordinator = try XCTUnwrap(web.navigationDelegate as? MarkdownPreviewView.Coordinator)
        XCTAssertFalse(coordinator.isLoaded)
        XCTAssertNil(harness.queryField)
        // Observe each real page operation's result without replacing its find
        // algorithm or issuing any extra searches/navigation from the fixture.
        _ = try harness.js("""
            window.__testFindResults = [];
            for (const name of ['__md2Find', '__md2FindNext']) {
                const operation = window[name];
                window[name] = function(...args) {
                    const result = operation.apply(this, args);
                    if (result.total === 3) window.__testFindResults.push(result.index);
                    return result;
                };
            }
            true;
            """, web)
        for previous in [false, false, true] {
            let consumed = coordinator.lastFindNavigationToken
            XCTAssertTrue(web.performKeyEquivalent(with: harness.findKey(previous: previous)))
            // Observe the real representable consuming each command token;
            // fixed delays can collapse successive SwiftUI state assignments.
            try waitForNative(harness, "preview accepted the next hidden navigation token") {
                coordinator.lastFindNavigationToken != consumed
            }
        }
        XCTAssertEqual(try harness.js("document.querySelectorAll('mark.md2-find').length", web) as? Int, 0)
        server.release()
        try harness.waitForPage("document.querySelectorAll('mark.md2-find').length === 3 && Array.from(document.querySelectorAll('mark.md2-find')).findIndex(e=>e.classList.contains('md2-find-current')) === 1",
                                in: web, context: "delayed page restores query and all three queued commands")
        XCTAssertEqual(try harness.js("window.__testFindResults", web) as? [Int], [1, 2, 3, 2],
                       "the pending query and navigation must execute once, in order")
        XCTAssertNil(harness.queryField)
        XCTAssertEqual(harness.store.text, original)
    }

    @MainActor
    func testHiddenFindNavigatesAndReopensWithLastQueryAcrossAllModes() throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        let original = "needle one\n\nneedle two\n\n[needle three](https://example.com/needle)"
        harness.store.text = original
        harness.host(ContentView(document: harness.store, settings: harness.settings, onOpen: {}))
        try waitForNative(harness, "the native source editor is mounted") {
            harness.store.editorSession.textView?.window === harness.window
        }
        let editor = try XCTUnwrap(harness.store.editorSession.textView)
        harness.store.requestFind(.show)
        try waitForNative(harness, "source query field is focused") {
            guard let fieldEditor = harness.queryField?.currentEditor() else { return false }
            return fieldEditor === harness.window.firstResponder
        }
        try harness.enterQuery("needle")
        try waitForSourceMatch(endingAt: 6, in: harness)
        XCTAssertEqual(editor.selectedRange().location, 6)
        try harness.press(.closeFind)
        XCTAssertTrue(editor.performKeyEquivalent(with: harness.findKey()))
        try waitForSourceMatch(endingAt: 18, in: harness)
        XCTAssertEqual(editor.selectedRange().location, 18)
        XCTAssertNil(harness.queryField)
        XCTAssertTrue(editor.performKeyEquivalent(with: harness.findKey(previous: true)))
        try waitForSourceMatch(endingAt: 6, in: harness)
        XCTAssertEqual(editor.selectedRange().location, 6)
        XCTAssertTrue(editor.performKeyEquivalent(with: harness.findKey(previous: true)))
        let sourceOnlyMatch = (original as NSString).range(of: "needle", options: .backwards)
        try waitForSourceMatch(endingAt: NSMaxRange(sourceOnlyMatch), in: harness)
        XCTAssertEqual(editor.selectedRange().location, NSMaxRange(sourceOnlyMatch), "source search includes link destinations")
        XCTAssertTrue(editor.performKeyEquivalent(with: harness.findKey()))
        try waitForSourceMatch(endingAt: 6, in: harness)
        XCTAssertEqual(editor.selectedRange().location, 6)
        harness.store.requestFind(.show)
        try waitForNative(harness, "source Find reopens with its saved query and keyboard focus") {
            guard let field = harness.queryField, let fieldEditor = field.currentEditor() else { return false }
            return field.stringValue == "needle" && fieldEditor === harness.window.firstResponder
        }
        XCTAssertEqual(harness.queryField?.stringValue, "needle")
        try harness.press(.closeFind)

        harness.store.requestMode(.read)
        try waitForNative(harness, "Read replaces the source editor with a preview") {
            harness.descendants(WKWebView.self).first != nil && editor.window == nil
        }
        let web = try XCTUnwrap(harness.descendants(WKWebView.self).first)
        try harness.waitForPage("""
            document.readyState === 'complete' && document.querySelector('main')?.textContent.includes('needle three') &&
            document.querySelectorAll('mark.md2-find').length === 3
            """, in: web, context: "Read restores query on the current rendered document")
        XCTAssertEqual(try harness.js("document.querySelectorAll('mark.md2-find').length", web) as? Int, 3)
        XCTAssertTrue(web.performKeyEquivalent(with: harness.findKey()))
        try harness.waitForPage("Array.from(document.querySelectorAll('mark.md2-find')).findIndex(e=>e.classList.contains('md2-find-current')) === 1",
                                in: web, context: "hidden Read Cmd-G advances")
        XCTAssertEqual(try harness.js("Array.from(document.querySelectorAll('mark.md2-find')).findIndex(e=>e.classList.contains('md2-find-current'))", web) as? Int, 1)
        XCTAssertNil(harness.queryField)
        XCTAssertTrue(web.performKeyEquivalent(with: harness.findKey(previous: true)))
        try harness.waitForPage("Array.from(document.querySelectorAll('mark.md2-find')).findIndex(e=>e.classList.contains('md2-find-current')) === 0",
                                in: web, context: "hidden Read Shift-Cmd-G returns")
        XCTAssertEqual(try harness.js("Array.from(document.querySelectorAll('mark.md2-find')).findIndex(e=>e.classList.contains('md2-find-current'))", web) as? Int, 0)
        harness.store.requestFind(.show)
        try waitForNative(harness, "Read Find reopens with its saved query and keyboard focus") {
            guard let field = harness.queryField, let fieldEditor = field.currentEditor() else { return false }
            return field.stringValue == "needle" && fieldEditor === harness.window.firstResponder
        }
        XCTAssertEqual(harness.queryField?.stringValue, "needle")
        try harness.press(.closeFind)

        harness.store.requestMode(.split)
        try waitForSourceMatch(endingAt: 6, in: harness)
        harness.store.requestFind(.next)
        try waitForSourceMatch(endingAt: 18, in: harness)
        XCTAssertEqual(editor.selectedRange().location, 18)
        XCTAssertNil(harness.queryField)
        XCTAssertEqual(harness.store.text, original)
    }

    @MainActor
    private func waitForNative(_ harness: InteractionTestWindow, _ context: String,
                               file: StaticString = #filePath, line: UInt = #line,
                               until predicate: () -> Bool) throws {
        var satisfied = false
        harness.spin(until: { satisfied = predicate(); return satisfied })
        let fields = harness.descendants(NSTextField.self).filter { $0.placeholderString == harness.settings.text(.findPlaceholder) }
        _ = try XCTUnwrap(satisfied ? true : nil,
            "\(context): selection=\(String(describing: harness.store.editorSession.textView?.selectedRange())), fields=\(fields.map(\.stringValue)), firstResponder=\(String(describing: harness.window.firstResponder))",
            file: file, line: line)
    }

    @MainActor
    private func waitForSourceMatch(endingAt location: Int, in harness: InteractionTestWindow,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        try waitForNative(harness, "source needle match ends at \(location)", file: file, line: line) {
            guard let editor = harness.store.editorSession.textView, editor.window != nil,
                  editor.selectedRange() == NSRange(location: location, length: 0) else { return false }
            // The retained caret can already be at this offset before a new
            // host rebuilds the query. Its actual find highlight proves the
            // new match index was applied as well.
            return editor.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: location - 1,
                                                             effectiveRange: nil) != nil
        }
    }
}

/// Test-only load barrier. The test releases it after delivering the commands,
/// so its timing is independent of CPU/WebKit speed on a CI runner.
private final class HeldFindImageServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var boundPort: UInt16?
    private var connections: [NWConnection] = []
    private var waiting: [NWConnection] = []
    private var released = false
    private var stopped = false
    var port: UInt16? { lock.withLock { boundPort } }
    var hasRequest: Bool { lock.withLock { !waiting.isEmpty } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let self else { return }
            self.lock.withLock { self.boundPort = self.listener.port?.rawValue }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let accepted = self.lock.withLock {
                guard !self.stopped else { return false }
                self.connections.append(connection)
                return true
            }
            guard accepted else { connection.cancel(); return }
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] _, _, _, _ in
                guard let self else { connection.cancel(); return }
                let respond = self.lock.withLock {
                    guard !self.stopped else { return false }
                    self.waiting.append(connection)
                    return self.released
                }
                if respond { Self.respond(to: connection) }
            }
        }
        listener.start(queue: .global())
    }

    func release() {
        let waiting = lock.withLock { released = true; return stopped ? [] : self.waiting }
        waiting.forEach(Self.respond)
    }
    func stop() {
        listener.cancel()
        lock.withLock { stopped = true; return connections }.forEach { $0.cancel() }
    }
    private static func respond(to connection: NWConnection) {
        let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
        var response = Data("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(image.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(image)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
