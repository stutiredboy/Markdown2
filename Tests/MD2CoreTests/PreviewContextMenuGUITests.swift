import AppKit
import WebKit
import XCTest
@testable import MD2App

/// These exercise WebKit's displayed default menu, including its undocumented
/// item identifiers. Adapter-only tests cannot prove those items still exist.
final class PreviewContextMenuGUITests: XCTestCase, RenderedPageTesting {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed test.")
    }

    @MainActor func testDefaultLinkMenuOpensExactTargetAndKeepsNativeCopy() throws {
        let destination = URL(string: "https://example.com/menu?literal=%26copy%3B#target")!
        var opened: [URL] = []
        try withPage("[**Menu link**](\(destination.absoluteString))", on: .preview,
                     onOpenWithSystem: { opened.append($0) }) { webView in
            let page = webView.url
            try recordInput(in: webView)
            try useNativeMenu(on: "document.querySelector('main a strong')", in: webView,
                              action: .openLink, copyIdentifiers: ["WKMenuItemIdentifierCopyLink"])
            XCTAssertTrue(spin(5) { opened == [destination] }, "the selected native Open item did not hand off its URL")
            try assertContextEvent(in: webView, link: destination.absoluteString, image: "")
            XCTAssertEqual(webView.url, page, "a context-menu action replaced the preview")
        }
        XCTAssertEqual(opened, [destination])
    }

    @MainActor func testControlClickMenuOpensExactTargetAndKeepsNativeCopy() throws {
        let destination = URL(string: "https://example.com/control-click-menu#target")!
        var opened: [URL] = []
        try withPage("[**Control-click menu**](\(destination.absoluteString))", on: .preview,
                     onOpenWithSystem: { opened.append($0) }) { webView in
            let page = webView.url
            try recordInput(in: webView)
            try useNativeMenu(on: "document.querySelector('main a strong')", in: webView,
                              action: .openLink, copyIdentifiers: ["WKMenuItemIdentifierCopyLink"], controlClick: true)
            XCTAssertTrue(spin(5) { opened == [destination] }, "Control-click did not bind the native Open action")
            try assertContextEvent(in: webView, link: destination.absoluteString, image: "")
            XCTAssertEqual(webView.url, page)
        }
        XCTAssertEqual(opened, [destination])
    }

    @MainActor func testLinkedImageMenuOpensImageInsteadOfOuterLinkAndKeepsNativeCopy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("md2-menu-image-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("context-image.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        let imageColor = NSColor(deviceRed: 0.1, green: 0.4, blue: 0.8, alpha: 1)
        for x in 0..<32 {
            for y in 0..<32 { bitmap.setColor(imageColor, atX: x, y: y) }
        }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: image)
        let outerLink = URL(string: "https://example.com/outer-image-link")!
        var opened: [URL] = []
        try withPage("[![Linked image](context-image.png)](\(outerLink.absoluteString))", on: .preview,
                     baseURL: directory, onOpenWithSystem: { opened.append($0) }) { webView in
            let page = webView.url
            XCTAssertTrue(spin(5) {
                (try? self.evaluate("document.querySelector('main img')?.complete && document.querySelector('main img')?.naturalWidth > 0",
                                    in: webView)) as? Bool == true
            }, "a broken image cannot prove that the normal image menu works")
            _ = try evaluate("document.querySelector('main img').style.width = '80px'; true", in: webView)
            let imageSource = try XCTUnwrap(try evaluate("document.querySelector('main img').currentSrc", in: webView) as? String)
            try recordInput(in: webView)
            try useNativeMenu(on: "document.querySelector('main img')", in: webView,
                              action: .openImage, copyIdentifiers: ["WKMenuItemIdentifierCopyImage", "WKMenuItemIdentifierCopyLink"])
            XCTAssertTrue(spin(5) { opened == [image] },
                          "Open Image must resolve the image resource to its file, not the enclosing link: \(opened)")
            try assertContextEvent(in: webView, link: outerLink.absoluteString, image: imageSource)

            // The very same linked image also retains its ordinary Open Link.
            try useNativeMenu(on: "document.querySelector('main img')", in: webView,
                              action: .openLink, copyIdentifiers: ["WKMenuItemIdentifierCopyImage", "WKMenuItemIdentifierCopyLink"])
            XCTAssertTrue(spin(5) { opened == [image, outerLink] })
            try assertContextEvent(in: webView, link: outerLink.absoluteString, image: imageSource, count: 2)
            XCTAssertEqual(webView.url, page)
        }
        XCTAssertEqual(opened, [image, outerLink])
    }

    @MainActor func testCancellingNativeMenuDoesNotAuthorizeScriptedNavigation() throws {
        let destination = URL(string: "https://example.com/cancelled-menu-link")!
        let popup = URL(string: "https://example.com/after-cancel-window-open")!
        let control = URL(string: "https://example.com/after-cancel-trusted-click")!
        var opened: [URL] = []
        try withPage("[Cancel menu](\(destination))\n\n[Control](\(control))", on: .preview,
                     edit: RenderedPageEdit.removingPolicy,
                     onOpenWithSystem: { opened.append($0) }) { webView in
            let page = webView.url
            let coordinator = try XCTUnwrap(webView.navigationDelegate as? MarkdownPreviewView.Coordinator)
            let recorder = ContextMenuNavigationRecorder(coordinator)
            webView.navigationDelegate = recorder
            webView.uiDelegate = recorder
            defer { webView.navigationDelegate = coordinator; webView.uiDelegate = coordinator }
            webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
            try recordInput(in: webView)
            XCTAssertEqual(try evaluate("typeof window.__md2TakeContextMenu", in: webView) as? String, "undefined")
            try useNativeMenu(on: "document.querySelector('main a')", in: webView,
                              action: .cancel, copyIdentifiers: ["WKMenuItemIdentifierCopyLink"])
            try assertContextEvent(in: webView, link: destination.absoluteString, image: "")
            XCTAssertTrue(opened.isEmpty, "merely showing and cancelling the menu opened its link")

            _ = try evaluate("document.querySelector('main a').click(); true", in: webView)
            XCTAssertTrue(spin(5) { recorder.completed.contains(destination) },
                          "the synthetic click did not reach a navigation decision: \(recorder.diagnostics)")
            XCTAssertTrue(opened.isEmpty, "a cancelled menu authorized a later synthetic click")
            _ = try evaluate("window.open('\(popup.absoluteString)', '_blank'); true", in: webView)
            XCTAssertTrue(spin(5) { recorder.completed.contains(popup) },
                          "window.open did not reach a navigation decision: \(recorder.diagnostics)")
            XCTAssertTrue(opened.isEmpty, "a cancelled menu authorized a later script-created window")
            XCTAssertFalse(recorder.createdWindow)
            XCTAssertEqual(webView.url, page)

            try click("document.querySelectorAll('main a')[1]", in: webView)
            XCTAssertTrue(spin(5) { opened == [control] }, "the trusted positive-control click missed")
            XCTAssertEqual(try evaluate("window.__contextMenuClicks", in: webView) as? [[String: String]], [
                ["trusted": "false", "link": destination.absoluteString],
                ["trusted": "true", "link": control.absoluteString]
            ])
        }
        XCTAssertEqual(opened, [control])
    }

    @MainActor func testSuppressedMainFrameContextCannotAuthorizeAnIframeMenuAtTheSamePoint() throws {
        let original = URL(string: "https://example.com/suppressed-main-frame-menu")!
        let frameLink = URL(string: "https://example.com/iframe-menu")!
        var opened: [URL] = []
        try withPage("[**Suppressed main-frame menu**](\(original.absoluteString))", on: .preview,
                     edit: RenderedPageEdit.removingPolicy,
                     onOpenWithSystem: { opened.append($0) }) { webView in
            let page = webView.url
            try recordInput(in: webView)
            _ = try evaluate("""
                window.__originalContextLink = document.querySelector('main a');
                document.addEventListener('contextmenu', function suppressOnce(event) {
                    event.preventDefault();
                    window.__contextWasSuppressed = event.isTrusted && event.defaultPrevented;
                    document.removeEventListener('contextmenu', suppressOnce, true);
                }, true);
                true;
                """, in: webView)
            // The isolated capture listener runs before this page listener.
            // Keep its real main-frame snapshot pending by suppressing the menu.
            do {
                let unexpectedMenu = NativeMenuSession(action: .cancel, copyIdentifiers: [], webView: webView)
                unexpectedMenu.start()
                defer { unexpectedMenu.stop() }
                try sendContextClick(on: "window.__originalContextLink", in: webView)
                XCTAssertTrue(spin(5) {
                    (try? self.evaluate("window.__contextWasSuppressed === true", in: webView)) as? Bool == true
                }, "the initial trusted main-frame context event was not suppressed")
                XCTAssertFalse(unexpectedMenu.began, "preventDefault unexpectedly displayed a native menu")
            }
            try assertContextEvent(in: webView, link: original.absoluteString, image: "")
            XCTAssertTrue(opened.isEmpty)

            _ = try evaluate("""
                (() => {
                    const box = window.__originalContextLink.getBoundingClientRect();
                    const frame = document.createElement('iframe');
                    frame.id = 'contextFrame';
                    frame.style.cssText = 'position:fixed;width:200px;height:60px;border:0;z-index:9999';
                    frame.style.left = (box.left + box.width / 2 - 100) + 'px';
                    frame.style.top = (box.top + box.height / 2 - 30) + 'px';
                    frame.srcdoc = '<body style="margin:0"><a href="\(frameLink.absoluteString)" style="display:block;width:200px;height:60px">Frame link</a></body>';
                    document.body.appendChild(frame);
                    return true;
                })();
                """, in: webView)
            XCTAssertTrue(spin(5) {
                (try? self.evaluate("!!document.querySelector('#contextFrame').contentDocument?.querySelector('a')",
                                    in: webView)) as? Bool == true
            }, "the same-origin iframe fixture did not load")
            _ = try evaluate("""
                document.querySelector('#contextFrame').contentDocument.addEventListener('contextmenu', function (event) {
                    window.__iframeContextEvent = { trusted: String(event.isTrusted), link: event.target.closest('a')?.href || '' };
                }, true);
                true;
                """, in: webView)
            XCTAssertEqual(try evaluate("""
                (() => {
                    const box = window.__originalContextLink.getBoundingClientRect();
                    return window.__originalContextLink.isConnected &&
                        document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2) === document.querySelector('#contextFrame');
                })();
                """, in: webView) as? Bool, true, "the iframe must cover the original point while its old target stays connected")

            try useNativeMenu(on: "document.querySelector('#contextFrame')", in: webView,
                              action: .rejectOpen, copyIdentifiers: ["WKMenuItemIdentifierCopyLink"])
            XCTAssertEqual(try evaluate("window.__iframeContextEvent", in: webView) as? [String: String],
                           ["trusted": "true", "link": frameLink.absoluteString], "the real iframe context click missed")
            try assertContextEvent(in: webView, link: original.absoluteString, image: "")
            XCTAssertTrue(opened.isEmpty, "an iframe menu reused the suppressed main-frame target")
            XCTAssertEqual(webView.url, page)

            _ = try evaluate("document.querySelector('#contextFrame').remove(); true", in: webView)
            try useNativeMenu(on: "window.__originalContextLink", in: webView,
                              action: .openLink, copyIdentifiers: ["WKMenuItemIdentifierCopyLink"])
            XCTAssertTrue(spin(5) { opened == [original] }, "the main-frame native-menu positive control failed")
            try assertContextEvent(in: webView, link: original.absoluteString, image: "", count: 2)
        }
        XCTAssertEqual(opened, [original])
    }

    @MainActor private func recordInput(in webView: WKWebView) throws {
        _ = try evaluate("""
            window.__contextMenuEvents = [];
            window.__contextMenuClicks = [];
            document.addEventListener('contextmenu', function (event) {
                var link = event.target.closest('a'), image = event.target.closest('img');
                window.__contextMenuEvents.push({
                    trusted: String(event.isTrusted), link: link ? link.href : '',
                    image: image ? image.currentSrc : ''
                });
            }, true);
            document.addEventListener('click', function (event) {
                var link = event.target.closest('a');
                window.__contextMenuClicks.push({trusted: String(event.isTrusted), link: link ? link.href : ''});
            }, true);
            true;
            """, in: webView)
    }

    @MainActor private func assertContextEvent(in webView: WKWebView, link: String, image: String,
                                              count: Int = 1, file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = Array(repeating: ["trusted": "true", "link": link, "image": image], count: count)
        XCTAssertEqual(try evaluate("window.__contextMenuEvents", in: webView) as? [[String: String]], expected,
                       "the real context click missed or was not trusted", file: file, line: line)
    }

    /// No synthetic DOM event or manually constructed NSMenu can satisfy this:
    /// the right click must make WebKit enter and leave real native menu tracking.
    /// Only then do we select an actual displayed item via NSMenu's public API.
    @MainActor private func useNativeMenu(on element: String, in webView: WKWebView,
                                         action: NativeMenuSession.Action, copyIdentifiers: Set<String>,
                                         controlClick: Bool = false,
                                         file: StaticString = #filePath, line: UInt = #line) throws {
        let window = try XCTUnwrap(webView.window)
        let origin = window.frame.origin
        window.setFrameOrigin(NSPoint(x: 80, y: 80))
        window.makeKeyAndOrderFront(nil)
        defer { window.setFrameOrigin(origin) }
        let session = NativeMenuSession(action: action, copyIdentifiers: copyIdentifiers, webView: webView)
        session.start()
        defer { session.stop() }
        try sendContextClick(on: element, in: webView, controlClick: controlClick)
        XCTAssertTrue(spin(8) { session.finished }, "the native menu did not finish: \(session.diagnostics)",
                      file: file, line: line)
        XCTAssertTrue(session.began, "WebKit never displayed its native menu", file: file, line: line)
        XCTAssertTrue(session.performed, "the native Open item never became usable: \(session.diagnostics)",
                      file: file, line: line)
        XCTAssertEqual(session.preservedCopyIdentifiers, copyIdentifiers,
                       "the normal native Copy items lost their actions: \(session.diagnostics)", file: file, line: line)
        if action == .rejectOpen {
            XCTAssertTrue(session.rejectedOpenItems,
                          "stale main-frame metadata enabled an iframe Open item: \(session.diagnostics)", file: file, line: line)
        }
    }

    @MainActor private func sendContextClick(on element: String, in webView: WKWebView,
                                            controlClick: Bool = false) throws {
        let window = try XCTUnwrap(webView.window)
        let point = try XCTUnwrap(try evaluate("""
            (() => { const r = (\(element)).getBoundingClientRect();
                return [r.left + r.width / 2, r.top + r.height / 2]; })()
            """, in: webView) as? [Double])
        let location = webView.convert(NSPoint(x: point[0], y: point[1]), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: controlClick ? .control : [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        if controlClick {
            webView.mouseDown(with: try event(.leftMouseDown))
            webView.mouseUp(with: try event(.leftMouseUp))
        } else {
            webView.rightMouseDown(with: try event(.rightMouseDown))
            webView.rightMouseUp(with: try event(.rightMouseUp))
        }
    }
}

/// NSObject callbacks avoid crossing Swift concurrency boundaries while AppKit
/// runs its nested menu loop. A timer in both modes also bounds a broken menu.
@MainActor private final class NativeMenuSession: NSObject {
    enum Action { case openLink, openImage, cancel, rejectOpen }
    private let action: Action
    private let copyIdentifiers: Set<String>
    private var menu: NSMenu?
    private var timer: Timer?
    private var deadline = Date.distantPast
    private weak var webView: WKWebView?
    private var barrierStarted = false
    private var barrierCompleted = false
    private(set) var began = false
    private(set) var finished = false
    private(set) var performed = false
    private(set) var rejectedOpenItems = false
    private(set) var preservedCopyIdentifiers: Set<String> = []
    private(set) var diagnostics = "no native menu notification"

    init(action: Action, copyIdentifiers: Set<String>, webView: WKWebView) {
        self.action = action
        self.copyIdentifiers = copyIdentifiers
        self.webView = webView
    }

    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(didBegin(_:)),
                                                name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didEnd(_:)),
                                                name: NSMenu.didEndTrackingNotification, object: nil)
        deadline = Date().addingTimeInterval(6)
        let timer = Timer(timeInterval: 0.02, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    func stop() {
        timer?.invalidate()
        menu?.cancelTracking()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func didBegin(_ notification: Notification) {
        guard menu == nil, let shown = notification.object as? NSMenu else { return }
        menu = shown
        began = true
    }

    @objc private func didEnd(_ notification: Notification) {
        guard let ended = notification.object as? NSMenu, ended === menu else { return }
        finished = true
    }

    @objc private func tick() {
        guard let menu, !finished else { return }
        diagnostics = menu.items.map {
            "\($0.identifier?.rawValue ?? "nil") enabled=\($0.isEnabled) action=\($0.action.map(NSStringFromSelector) ?? "nil")"
        }.joined(separator: "; ")
        // Copy remains a separate assertion even when Open never binds. Inspect
        // the actual native items on every tick, including the timeout tick.
        preservedCopyIdentifiers = Set(menu.items.compactMap { copyItem in
            guard let identifier = copyItem.identifier?.rawValue, copyIdentifiers.contains(identifier),
                  copyItem.isEnabled, copyItem.action != nil,
                  copyItem.action != NSSelectorFromString("openMenuTarget:") else { return nil }
            return identifier
        })
        guard Date() < deadline else { menu.cancelTracking(); return }
        guard !performed else { return }
        let identifiers: Set<String> = action == .openImage ? ["WKMenuItemIdentifierOpenImageInNewWindow"] :
            ["WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierOpenLinkInNewWindow"]
        let openItems = menu.items.filter { identifiers.contains($0.identifier?.rawValue ?? "") }
        if action == .rejectOpen {
            guard !openItems.isEmpty else { return }
            if !barrierStarted {
                barrierStarted = true
                // The timer fires after willOpenMenu returned and issued its
                // isolated-world query. A later round trip on the same web view
                // prevents accepting its initial, not-yet-bound disabled state.
                webView?.evaluateJavaScript("true") { [weak self] result, error in
                    self?.barrierCompleted = error == nil && (result as? Bool) == true
                }
                return
            }
            guard barrierCompleted else { return }
            rejectedOpenItems = openItems.allSatisfy { !$0.isEnabled && $0.action == nil && $0.target == nil }
            performed = true
            menu.cancelTracking()
            return
        }
        guard let item = openItems.first,
              item.isEnabled, item.action == NSSelectorFromString("openMenuTarget:"), item.target != nil else { return }
        performed = true
        if action != .cancel {
            menu.performActionForItem(at: menu.index(of: item))
        }
        menu.cancelTracking()
    }
}

/// A policy completion is a barrier for each exact attempted URL. JavaScript
/// evaluation completion alone can precede WebKit's navigation callback.
@MainActor private final class ContextMenuNavigationRecorder: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let coordinator: MarkdownPreviewView.Coordinator
    private(set) var completed: [URL] = []
    private(set) var diagnostics: [String] = []
    private(set) var createdWindow = false

    init(_ coordinator: MarkdownPreviewView.Coordinator) { self.coordinator = coordinator }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        coordinator.webView(webView, decidePolicyFor: navigationAction) { policy in
            if let url = navigationAction.request.url { self.completed.append(url) }
            self.diagnostics.append("\(navigationAction.request.url?.absoluteString ?? "nil") policy=\(policy.rawValue)")
            decisionHandler(policy)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let created = coordinator.webView(webView, createWebViewWith: configuration,
                                          for: navigationAction, windowFeatures: windowFeatures)
        if let url = navigationAction.request.url { completed.append(url) }
        diagnostics.append("new-window \(navigationAction.request.url?.absoluteString ?? "nil")")
        createdWindow = createdWindow || created != nil
        return created
    }
}
