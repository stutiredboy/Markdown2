import AppKit
import MD2Core
import WebKit
import XCTest
@testable import MD2App

final class PreviewSecurityGUITests: XCTestCase {
    @MainActor func testAuthorHTMLAndPageScriptsCannotMutateSource() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1", "Requires WebKit GUI session")
        _ = NSApplication.shared
        let controller = WKUserContentController()
        let coordinator = MarkdownPreviewView.Coordinator()
        var toggles = 0
        var modeChanges = 0
        coordinator.onToggleTask = { _, _ in toggles += 1 }
        coordinator.onEnterEdit = { modeChanges += 1 }
        MarkdownPreviewView.installInteractionBridge(on: controller, handler: coordinator)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        coordinator.documentLoader.install(on: configuration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
        let loaded = expectation(description: "loaded")
        let delegate = SecurityNavigationDelegate { loaded.fulfill() }
        webView.navigationDelegate = delegate
        let rendered = MarkdownRenderer().render(#"<img src="missing.png" onerror="window.pwned=1;window.webkit.messageHandlers.toggleTask.postMessage({line:1,checked:true})"><details open ontoggle="window.pwned=2"><summary>Details</summary></details>"# + "\n\n- [ ] task", assetMode: .appScheme)
        coordinator.documentLoader.load(rendered.html, baseURL: nil, in: webView)
        wait(for: [loaded], timeout: 15)

        XCTAssertEqual(try evaluate("typeof window.pwned", in: webView) as? String, "undefined")
        XCTAssertEqual(try evaluate("typeof window.webkit?.messageHandlers?.toggleTask", in: webView) as? String, "undefined")
        XCTAssertEqual(try evaluate("typeof window.webkit?.messageHandlers?.enterEdit", in: webView) as? String, "undefined")
        _ = try evaluate("document.querySelector('input').click(); document.dispatchEvent(new MouseEvent('dblclick', {bubbles:true, metaKey:true})); true", in: webView)
        XCTAssertEqual(toggles, 0)
        XCTAssertEqual(modeChanges, 0)

        // Live-content replacement uses the same sanitized renderer body.
        let data = try JSONSerialization.data(withJSONObject: [rendered.body])
        let literal = String(decoding: data, as: UTF8.self)
        _ = try evaluate("document.querySelector('main').innerHTML = \(literal)[0]; true", in: webView)
        XCTAssertEqual(try evaluate("document.querySelectorAll('[onerror],[ontoggle]').length", in: webView) as? Int, 0)

        // The native-owned isolated world still reaches the actual coordinator.
        let forwarded = expectation(description: "isolated native bridge")
        webView.evaluateJavaScript("window.webkit.messageHandlers.toggleTask.postMessage({line:1,checked:true}); true", in: nil, in: .defaultClient) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            forwarded.fulfill()
        }
        wait(for: [forwarded], timeout: 5)
        XCTAssertEqual(toggles, 1)
        controller.removeAllScriptMessageHandlers()
    }

    @MainActor private func evaluate(_ script: String, in webView: WKWebView) throws -> Any? {
        let done = expectation(description: "script")
        var value: Any?
        var failure: Error?
        webView.evaluateJavaScript(script) { result, error in
            value = result
            failure = error
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        if let failure { throw failure }
        return value
    }
}

@MainActor private final class SecurityNavigationDelegate: NSObject, WKNavigationDelegate {
    let finish: () -> Void
    init(_ finish: @escaping () -> Void) { self.finish = finish }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
}
