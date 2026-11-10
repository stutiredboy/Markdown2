import AppKit
import Foundation
import MD2Core
import Network
import SwiftUI
import WebKit
import XCTest
@testable import MD2App

/// Uses production preview/loader and actual TCP requests. No URLProtocol mock,
/// disconnected-network assumption, or image failure alone can satisfy a deny.
final class RemoteResourcePolicyGUITests: XCTestCase, RenderedPageTesting {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1", "Requires exclusive WebKit GUI session")
    }

    @MainActor func testNativeBoundaryBlocksImagesEvenWhenHTMLClaimsPermission() throws {
        let server = try ResourceRequestServer()
        defer { server.stop() }
        XCTAssertTrue(spin { server.port != nil })
        try positiveControl(server)
        let prefix = "/blocked-\(UUID())"
        let markdown = fixture(server.base + prefix)
        let host = ResourcePreviewHost(markdown: markdown, policy: .blocked, renderedPolicy: .allowRemoteImages)
        defer { host.close() }
        let web = try host.ready()
        XCTAssertTrue(try waitFor("window.__md2DiagramsSettled === true", in: web))
        XCTAssertEqual(try js("document.querySelectorAll('.diagram svg').length", in: web) as? Int, 1)
        XCTAssertTrue(try waitFor("document.querySelectorAll('.md2-broken-image').length >= 3", in: web))
        XCTAssertTrue((try js("document.querySelector('.md2-broken-image').textContent", in: web) as? String)?.contains("blocked") == true)
        try injectResourceMatrix(server.base + prefix, in: web)
        _ = spin(0.6) { false }
        XCTAssertEqual(server.requests.filter { $0.path.hasPrefix(prefix) }.map(\.path), [])
        XCTAssertFalse(web.configuration.websiteDataStore.isPersistent)
    }

    @MainActor func testGrantLoadsImageClassAndRedirectsButNoOtherResourceClass() throws {
        let server = try ResourceRequestServer()
        defer { server.stop() }
        XCTAssertTrue(spin { server.port != nil })
        try positiveControl(server)
        let prefix = "/allowed-\(UUID())"
        let host = ResourcePreviewHost(markdown: fixture(server.base + prefix), policy: .allowRemoteImages)
        defer { host.close() }
        let web = try host.ready()
        XCTAssertTrue(try waitFor("window.__md2DiagramsSettled === true && [...document.images].filter(i=>i.naturalWidth===1).length >= 4", in: web))
        try injectResourceMatrix(server.base + prefix, in: web)
        for suffix in ["/direct.png", "/reference.png", "/raw.png", "/diagram.png", "/srcset.png", "/css.png", "/svg.png", "/redirect", "/redirected.png"] {
            XCTAssertTrue(spin { server.requests.contains { $0.path == prefix + suffix } }, suffix)
        }
        _ = spin(0.5) { false }
        let denied = ["/sheet.css", "/font.woff2", "/script.js", "/frame.html", "/media.mp4", "/fetch", "/object.html", "/svg-use.svg"]
        XCTAssertEqual(server.requests.filter { record in denied.contains { record.path == prefix + $0 } }.map(\.path), [])
        XCTAssertTrue(server.requests.filter { $0.path.hasPrefix(prefix) }.allSatisfy { $0.headers["referer"] == nil })
    }

    @MainActor func testPolicyOnlyTransitionsAndPendingLiveUpdateCannotRestorePermission() throws {
        let server = try ResourceRequestServer()
        defer { server.stop() }
        XCTAssertTrue(spin { server.port != nil })
        try positiveControl(server)
        let prefix = "/transition-\(UUID())"
        let markdown = "# Same bytes\n\n![remote](\(server.base + prefix)/image.png)"
        let host = ResourcePreviewHost(markdown: markdown, policy: .blocked)
        defer { host.close() }
        let web = try host.ready()
        let initialPage = web.url
        XCTAssertEqual(server.requests.filter { $0.path.hasPrefix(prefix) }.count, 0)
        host.show(markdown, policy: .allowRemoteImages, token: UUID())
        XCTAssertTrue(spin { web.url != initialPage && host.coordinator?.isLoaded == true })
        XCTAssertTrue(spin { server.requests.contains { $0.path == prefix + "/image.png" } })
        let allowedPage = web.url
        // Queue detached rewriting/debounced body installation, then synchronously
        // revoke before the delayed work may reach WebKit.
        host.show(markdown + "\n\n![stale](\(server.base + prefix)/stale.png)", policy: .allowRemoteImages)
        _ = spin(0.02) { false }
        host.invalidator?()
        host.show(markdown, policy: .blocked, token: UUID())
        XCTAssertTrue(spin { web.url != allowedPage && host.coordinator?.isLoaded == true })
        let hitsAfterRevocation = server.requests.count
        _ = try js("var i=new Image(); i.src='\(server.base + prefix)/after-revoke.png'; document.body.appendChild(i); true", in: web)
        _ = spin(0.6) { false }
        XCTAssertEqual(server.requests.count, hitsAfterRevocation)
        XCTAssertFalse(server.requests.contains { $0.path == prefix + "/stale.png" })
        XCTAssertTrue((try js("document.querySelector('.md2-broken-image').textContent", in: web) as? String)?.contains("blocked") == true)
    }

    @MainActor func testDistinctHostsAndReloadHaveNoSharedCookieOrImageCache() throws {
        let server = try ResourceRequestServer()
        defer { server.stop() }
        XCTAssertTrue(spin { server.port != nil })
        let prefix = "/cache-\(UUID())"
        let markdown = "![cache](\(server.base + prefix)/cache.png)"
        let first = ResourcePreviewHost(markdown: markdown, policy: .allowRemoteImages)
        defer { first.close() }
        let firstWeb = try first.ready()
        XCTAssertTrue(spin { server.requests.filter { $0.path == prefix + "/cache.png" }.count == 1 })
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "md2-private", .value: "first-document"]))
        let set = expectation(description: "set private cookie")
        firstWeb.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { set.fulfill() }
        wait(for: [set], timeout: 5)
        XCTAssertTrue(cookies(firstWeb).contains { $0.name == "md2-private" })
        let second = ResourcePreviewHost(markdown: markdown, policy: .allowRemoteImages)
        defer { second.close() }
        let secondWeb = try second.ready()
        XCTAssertTrue(spin { server.requests.filter { $0.path == prefix + "/cache.png" }.count == 2 })
        XCTAssertFalse(secondWeb.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(firstWeb.configuration.websiteDataStore === secondWeb.configuration.websiteDataStore)
        XCTAssertFalse(cookies(secondWeb).contains { $0.name == "md2-private" })
        let page = firstWeb.url
        first.show(markdown, policy: .allowRemoteImages, token: UUID())
        XCTAssertTrue(spin { firstWeb.url != page && first.coordinator?.isLoaded == true })
        XCTAssertFalse(cookies(firstWeb).contains { $0.name == "md2-private" })
        XCTAssertTrue(spin { server.requests.filter { $0.path == prefix + "/cache.png" }.count == 3 })
        XCTAssertTrue(server.requests.allSatisfy { $0.headers["referer"] == nil && $0.headers["cookie"] == nil })
    }

    @MainActor func testInvalidatedFullLoadCannotPublishOrRequestResources() throws {
        let server = try ResourceRequestServer()
        defer { server.stop() }
        XCTAssertTrue(spin { server.port != nil })
        try positiveControl(server)
        let loader = WebDocumentLoader()
        let config = WKWebViewConfiguration()
        loader.install(on: config)
        let web = WKWebView(frame: .zero, configuration: config)
        let prefix = "/obsolete-\(UUID())"
        let html = MarkdownRenderer().render("![old](\(server.base + prefix)/old.png)", assetMode: .appScheme, remoteResourcePolicy: .allowRemoteImages).html
        loader.load(html, baseURL: nil, remoteResourcePolicy: .allowRemoteImages, in: web)
        loader.invalidate(in: web)
        _ = spin(0.7) { false }
        XCTAssertNil(loader.documentPageURL)
        XCTAssertNil(loader.currentNavigation)
        XCTAssertEqual(server.requests.filter { $0.path.hasPrefix(prefix) }.count, 0)
    }

    @MainActor func testRevocationRetiresAPageWithAnAlreadyTransmittedDelayedImage() throws {
        let server = try ResourceRequestServer()
        defer { server.stop() }
        XCTAssertTrue(spin { server.port != nil })
        try positiveControl(server)
        let prefix = "/delayed-\(UUID())"
        let source = "# Delayed\n\n![delayed](\(server.base + prefix)/gated.png)"
        let host = ResourcePreviewHost(markdown: source, policy: .allowRemoteImages)
        defer { host.close() }
        XCTAssertTrue(spin { server.requests.contains { $0.path == prefix + "/gated.png" } })
        let web = try XCTUnwrap(host.web)
        let oldPage = web.url
        // This request has already reached the listener; revocation cannot undo
        // that fact. The old page must not start its next scheduled request.
        _ = try js("setTimeout(function(){var i=new Image();i.src='\(server.base + prefix)/late.png';document.body.appendChild(i)}, 400); true", in: web)
        host.invalidator?()
        host.show(source, policy: .blocked, token: UUID())
        XCTAssertTrue(spin { web.url != oldPage && host.coordinator?.isLoaded == true })
        server.releaseGatedResponses()
        _ = spin(0.7) { false }
        XCTAssertEqual(server.requests.filter { $0.path == prefix + "/gated.png" }.count, 1)
        XCTAssertFalse(server.requests.contains { $0.path == prefix + "/late.png" })
    }

    @MainActor func testLocalAndDataSVGImagesDoNotFetchNestedRemoteResources() throws {
        let server = try ResourceRequestServer()
        defer { server.stop() }
        XCTAssertTrue(spin { server.port != nil })
        try positiveControl(server)
        let prefix = "/svg-nested-\(UUID())"
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20">
        <style>@import url('\(server.base + prefix)/nested.css');rect {fill: red}</style>
        <rect width="20" height="20"/>
        <image href="\(server.base + prefix)/nested.png" width="10" height="10"/>
        <foreignObject width="10" height="10"><img xmlns="http://www.w3.org/1999/xhtml" src="\(server.base + prefix)/foreign.png"/></foreignObject>
        </svg>
        """
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("md2-svg-resource-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try svg.write(to: directory.appendingPathComponent("vector.svg"), atomically: true, encoding: .utf8)
        let loader = WebDocumentLoader()
        let config = WKWebViewConfiguration(); loader.install(on: config)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: config)
        defer { loader.invalidate(in: web) }
        loader.load(MarkdownRenderer().render("![local](vector.svg)", assetMode: .appScheme).html, baseURL: directory, in: web)
        XCTAssertTrue(try waitFor("document.images.length === 1 && document.images[0].naturalWidth === 20", in: web))
        let dataURL = "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
        _ = try js("var i=new Image();i.id='data-vector';i.src='\(dataURL)';document.body.appendChild(i);true", in: web)
        XCTAssertTrue(try waitFor("document.getElementById('data-vector').naturalWidth === 20", in: web))
        _ = spin(0.5) { false }
        XCTAssertEqual(server.requests.filter { $0.path.hasPrefix(prefix) }.map(\.path), [])
    }

    @MainActor func testPortableDiagramOmitsDynamicImagesAndExternalCSSReferences() throws {
        let server = try ResourceRequestServer()
        defer { server.stop() }
        XCTAssertTrue(spin { server.port != nil })
        try positiveControl(server)
        let prefix = "/portable-diagram-\(UUID())"
        let source = "```mermaid\ngraph TD\n A[\"<img src='\(server.base + prefix)/label.png' alt='remote label'>\"] --> B[plain]\n```"
        try withPage(source, on: .exportedFile) { web in
            XCTAssertEqual(try js("document.querySelectorAll('.diagram-mermaid svg').length", in: web) as? Int, 1)
            XCTAssertEqual(try js("document.querySelectorAll('.diagram-mermaid img,.diagram-mermaid image').length", in: web) as? Int, 0)
            XCTAssertTrue((try js("document.querySelector('.diagram-mermaid').textContent", in: web) as? String)?.contains("Image omitted") == true)
            let base = String(decoding: try JSONEncoder().encode(server.base + prefix), as: UTF8.self)
            _ = try js("""
            var b=\(base), t=document.createElement('template');
            t.innerHTML='<svg><style>@import url('+b+'/import.css); .probe {fill:url('+b+'/fill.svg);stroke:url(#paint);font-size:12px} @font-face {font-family:Bad;src:url('+b+'/font.woff2)}</style>'
              +'<defs><linearGradient id="paint"><stop stop-color="red"/></linearGradient></defs>'
              +'<rect class="probe" width="10" height="10" style="fill:url('+b+'/inline.svg);stroke:url(#paint)"/>'
              +'<use href="'+b+'/use.svg#x"/><image href="data:image/svg+xml,invalid"/>'
              +'<a href="https://example.com"><text>ordinary link</text></a></svg>';
            md2OfflineDiagram(t.content);
            var box=document.createElement('div');box.id='offline-probe';box.appendChild(t.content);document.body.appendChild(box);true;
            """, in: web)
            XCTAssertFalse((try js("document.getElementById('offline-probe').innerHTML", in: web) as? String)?.contains(server.base) == true)
            XCTAssertEqual(try js("document.querySelector('#offline-probe a').getAttribute('href')", in: web) as? String, "https://example.com")
            XCTAssertTrue((try js("document.querySelector('#offline-probe rect').getAttribute('style')", in: web) as? String)?.contains("#paint") == true)
            _ = spin(0.6) { false }
            XCTAssertEqual(server.requests.filter { $0.path.hasPrefix(prefix) }.map(\.path), [])
        }
    }

    private func fixture(_ base: String) -> String {
        """
        # Resource fixture
        $x^2$

        ![direct](\(base)/direct.png)

        ![reference][r]

        [r]: \(base)/reference.png

        <img src="\(base)/raw.png" alt="raw">

        ```mermaid
        graph TD
        A["<img src='\(base)/diagram.png'>"] --> B[plain]
        ```
        """
    }

    @MainActor private func injectResourceMatrix(_ base: String, in web: WKWebView) throws {
        let encoded = String(decoding: try JSONEncoder().encode(base), as: UTF8.self)
        _ = try js("""
        var b=\(encoded);
        var box=document.createElement('div'); box.id='resource-matrix';
        box.innerHTML='<img srcset="'+b+'/srcset.png 1x"><div style="width:4px;height:4px;background-image:url('+b+'/css.png)"></div>'
          +'<svg width="8" height="8"><image href="'+b+'/svg.png" width="8" height="8"/><use href="'+b+'/svg-use.svg#x"/></svg>'
          +'<img src="'+b+'/redirect">'
          +'<link rel="stylesheet" href="'+b+'/sheet.css">'
          +'<iframe src="'+b+'/frame.html"></iframe><video src="'+b+'/media.mp4" preload="auto"></video>'
          +'<object data="'+b+'/object.html"></object>';
        document.body.appendChild(box);
        var s=document.createElement('script');s.src=b+'/script.js';document.head.appendChild(s);
        var css=document.createElement('style');css.textContent='@font-face {font-family:Probe;src:url('+b+'/font.woff2)} #font-probe {font-family:Probe}';document.head.appendChild(css);
        var t=document.createElement('span'); t.id='font-probe';t.textContent='probe';document.body.appendChild(t);
        fetch(b+'/fetch').catch(()=>{}); true;
        """, in: web)
    }

    @MainActor private func positiveControl(_ server: ResourceRequestServer) throws {
        let path = "/positive-\(UUID())/image.png"
        let done = expectation(description: "reachable independent listener control")
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: try XCTUnwrap(URL(string: server.base + path))) { data, response, error in
            XCTAssertNil(error); XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(data, ResourceRequestServer.png); done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        session.invalidateAndCancel()
        XCTAssertTrue(server.requests.contains { $0.path == path })
    }

    @MainActor private func cookies(_ web: WKWebView) -> [HTTPCookie] {
        let done = expectation(description: "cookies")
        var found: [HTTPCookie] = []
        web.configuration.websiteDataStore.httpCookieStore.getAllCookies { found = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        return found
    }

    @MainActor private func waitFor(_ script: String, in web: WKWebView) throws -> Bool {
        spin { (try? self.js(script, in: web)) as? Bool == true }
    }

    @MainActor private func js(_ script: String, in web: WKWebView) throws -> Any? {
        let done = expectation(description: "JavaScript")
        var value: Any?; var error: Error?
        web.evaluateJavaScript(script) { value = $0; error = $1; done.fulfill() }
        wait(for: [done], timeout: 5)
        if let error { throw error }; return value
    }

    @MainActor private func spin(_ seconds: TimeInterval = 12, _ predicate: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if predicate() { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return predicate()
    }
}

@MainActor private final class ResourcePreviewHost {
    let window: NSWindow
    let hosting: NSHostingView<MarkdownPreviewView>
    var token = UUID()
    var invalidator: (@MainActor () -> Void)?
    var web: WKWebView? { find(hosting) }
    var coordinator: MarkdownPreviewView.Coordinator? { web?.navigationDelegate as? MarkdownPreviewView.Coordinator }

    init(markdown: String, policy: RemoteResourcePolicy, renderedPolicy: RemoteResourcePolicy? = nil) {
        _ = NSApplication.shared
        hosting = NSHostingView(rootView: Self.preview(markdown, policy: policy, renderedPolicy: renderedPolicy, token: token))
        window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFrontRegardless()
        show(markdown, policy: policy, renderedPolicy: renderedPolicy)
    }

    func show(_ markdown: String, policy: RemoteResourcePolicy, renderedPolicy: RemoteResourcePolicy? = nil, token: UUID? = nil) {
        if let token { self.token = token }
        var view = Self.preview(markdown, policy: policy, renderedPolicy: renderedPolicy, token: self.token)
        view.onRegisterResourceInvalidator = { [weak self] in self?.invalidator = $0 }
        hosting.rootView = view
        // SwiftUI may have built its initial host before the registration closure
        // was replaced. This invokes the exact production coordinator primitive.
        if let web, let coordinator { invalidator = { [weak web, weak coordinator] in if let web { coordinator?.invalidateResourceContext(in: web) } } }
    }

    func ready() throws -> WKWebView {
        let end = Date().addingTimeInterval(15)
        while Date() < end {
            if let web, coordinator?.isLoaded == true { return web }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        throw NSError(domain: "ResourcePreviewHost", code: 1, userInfo: [NSLocalizedDescriptionKey: "Preview did not finish loading"])
    }

    func close() { if let web { coordinator?.invalidateResourceContext(in: web) }; window.orderOut(nil); window.contentView = nil }

    private static func preview(_ text: String, policy: RemoteResourcePolicy, renderedPolicy: RemoteResourcePolicy?, token: UUID) -> MarkdownPreviewView {
        let rendered = MarkdownRenderer().render(text, assetMode: .appScheme, remoteResourcePolicy: renderedPolicy ?? policy)
        return MarkdownPreviewView(html: rendered.html, bodyHTML: rendered.body, baseURL: nil,
            remoteResourcePolicy: policy, remoteResourceContextToken: token, liveUpdate: true,
            jumpHeadingID: .constant(nil), jumpFraction: .constant(nil), jumpAnchor: .constant(nil),
            findQuery: .constant(""), findNavigation: .constant(nil), focusToken: UUID())
    }

    private func find(_ view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap(find).first
    }
}

private final class ResourceRequestServer: @unchecked Sendable {
    struct Record { let path: String; let headers: [String: String] }
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
    private let listener: NWListener
    private let lock = NSLock()
    private var actualPort: UInt16?
    private var records: [Record] = []
    private var gated: [(NWConnection, Data)] = []
    var port: UInt16? { lock.withLock { actualPort } }
    var requests: [Record] { lock.withLock { records } }
    var base: String { "http://127.0.0.1:\(port ?? 0)" }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let self { self.lock.withLock { self.actualPort = self.listener.port?.rawValue } }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                guard let data else { connection.cancel(); return }
                let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
                let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let split = line.firstIndex(of: ":") else { continue }
                    headers[String(line[..<split]).lowercased()] = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
                }
                self.lock.withLock { self.records.append(Record(path: path, headers: headers)) }
                let redirect = path.hasSuffix("/redirect")
                let body = redirect ? Data() : Self.png
                let location = redirect ? "Location: \(path.dropLast("redirect".count))redirected.png\r\n" : ""
                let cache = path.hasSuffix("/cache.png") ? "public, max-age=3600" : "no-store"
                var response = Data("HTTP/1.1 \(redirect ? "302 Found" : "200 OK")\r\nContent-Type: image/png\r\nCache-Control: \(cache)\r\n\(location)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(body)
                if path.hasSuffix("/gated.png") {
                    self.lock.withLock { self.gated.append((connection, response)) }
                    return
                }
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global())
    }
    func releaseGatedResponses() {
        let responses = lock.withLock { let values = gated; gated = []; return values }
        for (connection, response) in responses {
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
    func stop() { listener.cancel(); releaseGatedResponses() }
}
