import Foundation
import MD2Core
import WebKit

/// Shared preview/PDF loading boundary. Pages stay in memory and have no file
/// read grant; only referenced images and explicitly bundled assets are served.
@MainActor
final class WebDocumentLoader {
    nonisolated static let documentScheme = "md2-doc"

    private let documents = MemoryDocumentSchemeHandler()
    private let assets = AppAssetSchemeHandler()
    private let images = LocalImageSchemeHandler()
    private(set) var documentPageURL: URL?
    /// The navigation of the latest `load`, `nil` while that load is still being
    /// prepared. Any other navigation's page is about to be replaced.
    private(set) var currentNavigation: WKNavigation?
    private var loadGeneration = 0
    private var rules: WebResourceRules.Lists?
    var onFailure: ((Error) -> Void)?

    func install(on configuration: WKWebViewConfiguration) {
        // A new loader/host has no shared login, cookie or cached-image state.
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(documents, forURLScheme: Self.documentScheme)
        configuration.setURLSchemeHandler(assets, forURLScheme: BundledWebAsset.scheme)
        configuration.setURLSchemeHandler(images, forURLScheme: LocalImageSchemeHandler.scheme)
    }

    /// Also used for live body replacements, so local links and image permissions
    /// have the same behavior after an edit as they do on a full page load.
    func prepareContent(_ html: String, baseURL: URL?) -> String {
        let prepared = Self.rewriteContent(html, baseURL: baseURL)
        installImages(prepared.allowedImages)
        return prepared.html
    }

    nonisolated static func rewriteContent(_ html: String, baseURL: URL?) -> (html: String, allowedImages: [String: URL]) {
        let images = LocalImageHTMLRewriter.rewrite(html, baseURL: baseURL)
        return (LocalLinkHTMLRewriter.rewrite(images.html, baseURL: baseURL), images.allowedImages)
    }

    func installImages(_ allowed: [String: URL]) { images.setAllowedImages(allowed) }

    func originalImageURL(for url: URL) -> URL? { images.originalImageURL(for: url) }

    /// Synchronously revoke the old page before yielding to rewriting or rule
    /// compilation. A retired context may neither finish loading nor reuse its
    /// local image mapping. Already transmitted network bytes cannot be recalled.
    func invalidate(in webView: WKWebView) {
        loadGeneration += 1
        currentNavigation = nil
        documentPageURL = nil
        documents.clear()
        images.setAllowedImages([:])
        if let rules {
            let controller = webView.configuration.userContentController
            controller.add(rules.blocked)
            controller.remove(rules.images)
        }
        webView.stopLoading()
    }

    func load(_ html: String, baseURL: URL?, fragment: String? = nil,
              remoteResourcePolicy: RemoteResourcePolicy = .blocked, in webView: WKWebView) {
        invalidate(in: webView)
        let generation = loadGeneration
        Task { [weak self, weak webView] in
            let rules: WebResourceRules.Lists
            do { rules = try await WebResourceRules.compiled() }
            catch {
                guard let self, generation == self.loadGeneration else { return }
                self.onFailure?(error)
                return // Never fall back to an unrestricted document load.
            }
            guard let self, let webView, generation == self.loadGeneration else { return }
            // Production identity changes replace the host too. Clearing this
            // ephemeral store keeps loader reuse fail-closed for other callers.
            await webView.configuration.websiteDataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            guard generation == self.loadGeneration else { return }
            let content = await Task.detached(priority: .userInitiated) {
                Self.rewriteContent(html, baseURL: baseURL)
            }.value
            guard generation == self.loadGeneration else { return }
            self.rules = rules
            let controller = webView.configuration.userContentController
            // The preview's document-start error listener reads native policy,
            // not an old CSP or a captured permission from its first render.
            let marker = "/* md2-native-resource-policy */"
            let retained = controller.userScripts.filter { !$0.source.hasPrefix(marker) }
            controller.removeAllUserScripts()
            for script in retained { controller.addUserScript(script) }
            controller.addUserScript(WKUserScript(
                source: "\(marker) window.__md2RemoteImagesAllowed = \(remoteResourcePolicy == .allowRemoteImages ? "true" : "false");",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
            // Install the new restriction before removing the preceding one.
            if remoteResourcePolicy == .allowRemoteImages {
                controller.add(rules.images)
                controller.remove(rules.blocked)
            } else {
                controller.add(rules.blocked)
                controller.remove(rules.images)
            }
            self.installImages(content.allowedImages)
            self.loadPrepared(content.html, fragment: fragment, in: webView)
        }
    }

    private func loadPrepared(_ content: String, fragment: String?, in webView: WKWebView) {
        // A fresh path forces a real navigation even when the fragment is the
        // same. Only the current page is retained; stale requests fail closed.
        let page = URL(string: "\(Self.documentScheme)://document/\(UUID().uuidString)/index.html")!
        documents.setDocument(url: page, html: content)
        documentPageURL = page
        var components = URLComponents(url: page, resolvingAgainstBaseURL: false)!
        components.fragment = fragment
        currentNavigation = webView.load(URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData))
    }
}

private final class MemoryDocumentSchemeHandler: NSObject, WKURLSchemeHandler {
    private let lock = NSLock()
    private var document: (url: URL, data: Data)?

    func setDocument(url: URL, html: String) {
        lock.withLock { document = (url, Data(html.utf8)) }
    }

    func clear() { lock.withLock { document = nil } }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        guard let data = lock.withLock({ document?.url == components?.url ? document?.data : nil }) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        serve(task, url: url, data: data, mimeType: "text/html", cacheControl: "no-store")
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

private final class AppAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let asset = BundledWebAsset(url: url), !asset.data.isEmpty else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        serve(task, url: url, data: asset.data, mimeType: asset.mimeType,
              cacheControl: "public, max-age=31536000, immutable")
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

private func serve(_ task: WKURLSchemeTask, url: URL, data: Data, mimeType: String, cacheControl: String) {
    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
        "Content-Type": "\(mimeType); charset=utf-8",
        "Content-Length": String(data.count),
        "Cache-Control": cacheControl,
        "Referrer-Policy": "no-referrer",
        "X-Content-Type-Options": "nosniff"
    ])!
    task.didReceive(response)
    task.didReceive(data)
    task.didFinish()
}

/// A custom-scheme document has no filesystem base. Resolve local hyperlinks
/// explicitly while leaving fragments on the memory page itself (no file base
/// tag, which would also send footnotes and TOC links away from that page).
enum LocalLinkHTMLRewriter {
    static func rewrite(_ html: String, baseURL: URL?) -> String {
        let regex = try! NSRegularExpression(pattern: #"<a\b[^>]*\bhref="([^"]*)"[^>]*>"#, options: [.caseInsensitive])
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        guard !matches.isEmpty else { return html }
        let sourceHTML = html as NSString
        var result = String()
        result.reserveCapacity(html.utf8.count)
        var cursor = 0
        let directory = baseURL.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
        for match in matches {
            let range = match.range(at: 1)
            guard range.location != NSNotFound else { continue }
            result.append(sourceHTML.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            // Match the browser's single HTML-attribute decoding pass before
            // interpreting URL separators; do not decode percent escapes here.
            let source = HTMLSafety.decodeHTMLAttributeEntities(sourceHTML.substring(with: range))
            if !source.isEmpty, !source.hasPrefix("#"), URL(string: source)?.scheme == nil,
               (source.hasPrefix("/") || directory != nil),
               let resolved = URL(string: source, relativeTo: directory ?? URL(fileURLWithPath: "/"))?.absoluteURL {
                result.append(resolved.absoluteString
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "\"", with: "&quot;"))
            } else {
                result.append(sourceHTML.substring(with: range))
            }
            cursor = NSMaxRange(range)
        }
        result.append(sourceHTML.substring(from: cursor))
        return result
    }
}
