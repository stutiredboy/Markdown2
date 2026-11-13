import AppKit
import WebKit
import XCTest
@testable import MD2App

final class PreviewLinkActivationGUITests: XCTestCase, RenderedPageTesting {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed test.")
    }

    @MainActor func testScriptedExternalNavigationsCannotInvokeHandlers() throws {
        let plain = URL(string: "https://example.com/script-plain")!
        let blank = URL(string: "https://example.com/script-blank")!
        let popup = URL(string: "https://example.com/script-window-open")!
        let location = URL(string: "https://example.com/script-location")!
        let control = URL(string: "https://example.com/trusted-control")!
        var external: [URL] = []
        var local: [URL] = []
        try withPage("""
            [Plain](\(plain))

            [Blank](\(blank))

            [Control](\(control))
            """, on: .preview, edit: RenderedPageEdit.removingPolicy,
            onOpenMarkdownLink: { local.append($0) }, onOpenWithSystem: { external.append($0) }) { webView in
            let page = webView.url
            let coordinator = try XCTUnwrap(webView.navigationDelegate as? MarkdownPreviewView.Coordinator)
            // This isolates the trusted-activation boundary, just as the fixture
            // removes CSP above. Native resource rules now stop window.open
            // before WebKit emits a navigation delegate callback; their separate
            // production-path tests must not make this delegate probe vacuous.
            webView.configuration.userContentController.removeAllContentRuleLists()
            let recorder = LinkPolicyRecorder(coordinator)
            webView.navigationDelegate = recorder
            webView.uiDelegate = recorder
            defer { webView.navigationDelegate = coordinator; webView.uiDelegate = coordinator }
            // Exercise the app boundary even when WebKit permits script popups;
            // its default popup blocker must not make this negative test pass.
            webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
            XCTAssertEqual(try evaluate("typeof window.webkit?.messageHandlers?.openLink", in: webView) as? String,
                           "undefined")
            _ = try evaluate("""
                window.__activationClicks = [];
                document.addEventListener('click', event => window.__activationClicks.push(event.isTrusted), true);
                document.querySelectorAll('main a')[1].target = '_blank';
                true;
                """, in: webView)
            let attempts: [(URL, String)] = [
                (plain, "document.querySelectorAll('main a')[0].click(); true"),
                (blank, "document.querySelectorAll('main a')[1].click(); true"),
                (popup, "window.open('\(popup)', '_blank'); true"),
                (location, "window.location.href = '\(location)'; true")
            ]
            for (target, script) in attempts {
                _ = try evaluate(script, in: webView)
                // JS completion alone is not a policy barrier. Observe the real
                // delegate finishing this exact request, then inspect callbacks.
                XCTAssertTrue(spin(5) { recorder.completed.contains(target) },
                              "no policy completion for \(target): \(recorder.diagnostics)")
                XCTAssertTrue(external.isEmpty, "script invoked a handler: \(external)")
                XCTAssertTrue(local.isEmpty)
                XCTAssertEqual(webView.url, page)
            }
            try click("document.querySelectorAll('main a')[2]", in: webView)
            XCTAssertTrue(spin(5) { external.last == control }, "trusted positive control missed")
            XCTAssertEqual(external, [control])
            XCTAssertEqual(try evaluate("window.__activationClicks", in: webView) as? [Bool], [false, false, true])
            XCTAssertFalse(recorder.createdWindow)
        }
        XCTAssertEqual(external, [control])
        XCTAssertTrue(local.isEmpty)
    }

    @MainActor func testTrustedExternalClicksKeepPlainBlankCommandAndMailHandoffs() throws {
        let targets = ["https://example.com/plain", "https://example.com/blank",
                       "https://example.com/command", "mailto:reader@example.com"]
        let expected = try targets.map { try XCTUnwrap(URL(string: $0)) }
        let markdown = targets.enumerated().map { "[Link \($0.offset + 1)](\($0.element))" }.joined(separator: "\n\n")
        var external: [URL] = []
        try withPage(markdown, on: .preview, onOpenWithSystem: { external.append($0) }) { webView in
            let page = webView.url
            _ = try evaluate("""
                window.__activationClicks = [];
                document.addEventListener('click', event => window.__activationClicks.push(event.isTrusted), true);
                document.querySelectorAll('main a')[1].target = '_blank';
                true;
                """, in: webView)
            for index in targets.indices {
                try click("document.querySelectorAll('main a')[\(index)]", in: webView,
                          modifiers: index == 2 ? .command : [])
                XCTAssertTrue(spin(5) { external.last == expected[index] }, "trusted click missed \(targets[index])")
                XCTAssertEqual(external, Array(expected.prefix(index + 1)))
            }
            XCTAssertEqual(try evaluate("window.__activationClicks", in: webView) as? [Bool], [true, true, true, true])
            XCTAssertEqual(webView.url, page)
        }
        XCTAssertEqual(external, expected)
    }

}

/// Observes actual WebKit requests while forwarding every decision to the real
/// coordinator. It supplies synchronization/diagnostics, never an allow/cancel rule.
@MainActor private final class LinkPolicyRecorder: NSObject, WKNavigationDelegate, WKUIDelegate {
    let coordinator: MarkdownPreviewView.Coordinator
    var completed: [URL] = []
    var diagnostics: [String] = []
    var createdWindow = false

    init(_ coordinator: MarkdownPreviewView.Coordinator) { self.coordinator = coordinator }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        coordinator.webView(webView, decidePolicyFor: action) { policy in
            if let url = action.request.url { self.completed.append(url) }
            self.diagnostics.append("\(action.request.url?.absoluteString ?? "nil") type=\(action.navigationType.rawValue) newWindow=\(action.targetFrame == nil) policy=\(policy.rawValue)")
            decisionHandler(policy)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let created = coordinator.webView(webView, createWebViewWith: configuration,
                                          for: action, windowFeatures: windowFeatures)
        if let url = action.request.url { completed.append(url) }
        diagnostics.append("new-window \(action.request.url?.absoluteString ?? "nil") type=\(action.navigationType.rawValue)")
        createdWindow = createdWindow || created != nil
        return created
    }
}
