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
        let editor = try XCTUnwrap(harness.store.editorSession.textView)
        let web = try XCTUnwrap(harness.descendants(WKWebView.self).first)
        harness.store.requestFind(.show)
        harness.spin()
        try harness.enterQuery("needle")
        harness.spin(for: 0.4)
        let show = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                   timestamp: 0, windowNumber: harness.window.windowNumber, context: nil,
                                   characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
        XCTAssertTrue(web.performKeyEquivalent(with: show))
        harness.spin(for: 0.4)
        harness.store.requestFind(.next)
        harness.spin()
        let index = "Array.from(document.querySelectorAll('mark.md2-find')).findIndex(e=>e.classList.contains('md2-find-current'))"
        XCTAssertEqual(try harness.js(index, web) as? Int, 1)
        let fields = harness.descendants(NSTextField.self).filter { $0.placeholderString == harness.settings.text(.findPlaceholder) }
        XCTAssertEqual(fields.count, 2)
        let sourceField = try XCTUnwrap(fields.min { $0.convert($0.bounds, to: nil).midX < $1.convert($1.bounds, to: nil).midX })
        XCTAssertTrue(harness.window.makeFirstResponder(sourceField))
        harness.spin()
        XCTAssertTrue(sourceField.currentEditor() === harness.window.firstResponder, "source find field must own keyboard")
        // Merely refocus the unchanged query. No binding setter fires here.
        harness.store.requestFind(.next)
        harness.spin()
        XCTAssertEqual(editor.selectedRange().location, 18)
        XCTAssertEqual(try harness.js(index, web) as? Int, 1, "menu navigation must leave the other pane's match alone")
    }

    @MainActor
    func testPreviewNavigationWaitsForPendingSearchAfterModeSwitch() throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        let web = WKWebView(frame: .zero)
        let coordinator = MarkdownPreviewView.Coordinator()
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
        harness.spin(for: 0.3)
        XCTAssertEqual(try harness.js("window.index", web) as? Int, 2, "queued commands execute once and in order after search")
    }

    @MainActor
    func testHiddenFindSurvivesAnActuallyDelayedPageLoad() throws {
        let harness = InteractionTestWindow()
        defer { harness.close() }
        let server = try HeldFindImageServer()
        defer { server.stop() }
        harness.spin(until: { server.port != nil })
        let port = try XCTUnwrap(server.port)
        let original = "needle one\n\nneedle two\n\nneedle three\n\n![load barrier](http://127.0.0.1:\(port)/held.png)"
        harness.store.text = original
        harness.host(ContentView(document: harness.store, settings: harness.settings, onOpen: {}))
        harness.store.requestFind(.show)
        harness.spin(until: { harness.queryField != nil })
        try harness.enterQuery("needle")
        try harness.press(.closeFind)
        harness.store.requestMode(.read)
        harness.spin(until: { !harness.descendants(WKWebView.self).isEmpty })
        let web = try XCTUnwrap(harness.descendants(WKWebView.self).first)
        // Hold an actual image response, so the current document has parsed but
        // WebKit cannot send didFinish. No fake find implementation or timers.
        try harness.waitForPage("document.querySelector('main')?.textContent.includes('needle three') && typeof window.__md2Find === 'function'",
                                in: web, context: "delayed current document parsed", requireLoaded: false)
        harness.spin(until: { server.hasRequest })
        XCTAssertTrue(server.hasRequest)
        XCTAssertTrue(web.isLoading)
        XCTAssertFalse(try XCTUnwrap(web.navigationDelegate as? MarkdownPreviewView.Coordinator).isLoaded)
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
        XCTAssertTrue(web.performKeyEquivalent(with: harness.findKey()))
        harness.spin()
        XCTAssertTrue(web.performKeyEquivalent(with: harness.findKey()))
        harness.spin()
        XCTAssertTrue(web.performKeyEquivalent(with: harness.findKey(previous: true)))
        harness.spin()
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
        let editor = try XCTUnwrap(harness.store.editorSession.textView)
        harness.store.requestFind(.show)
        harness.spin()
        try harness.enterQuery("needle")
        harness.spin(for: 0.5)
        XCTAssertEqual(editor.selectedRange().location, 6)
        try harness.press(.closeFind)
        XCTAssertTrue(editor.performKeyEquivalent(with: harness.findKey()))
        harness.spin()
        XCTAssertEqual(editor.selectedRange().location, 18)
        XCTAssertNil(harness.queryField)
        XCTAssertTrue(editor.performKeyEquivalent(with: harness.findKey(previous: true)))
        harness.spin()
        XCTAssertEqual(editor.selectedRange().location, 6)
        XCTAssertTrue(editor.performKeyEquivalent(with: harness.findKey(previous: true)))
        harness.spin()
        let sourceOnlyMatch = (original as NSString).range(of: "needle", options: .backwards)
        XCTAssertEqual(editor.selectedRange().location, NSMaxRange(sourceOnlyMatch), "source search includes link destinations")
        XCTAssertTrue(editor.performKeyEquivalent(with: harness.findKey()))
        harness.spin()
        XCTAssertEqual(editor.selectedRange().location, 6)
        harness.store.requestFind(.show)
        harness.spin()
        XCTAssertEqual(harness.queryField?.stringValue, "needle")
        try harness.press(.closeFind)

        harness.store.requestMode(.read)
        harness.spin(until: { harness.descendants(WKWebView.self).first != nil && editor.window == nil })
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
        harness.spin()
        XCTAssertEqual(harness.queryField?.stringValue, "needle")
        try harness.press(.closeFind)

        harness.store.requestMode(.split)
        harness.spin(until: { editor.window != nil })
        harness.spin(for: 0.6)
        harness.store.requestFind(.next)
        harness.spin()
        XCTAssertEqual(editor.selectedRange().location, 18)
        XCTAssertNil(harness.queryField)
        XCTAssertEqual(harness.store.text, original)
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
