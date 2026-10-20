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
    private var loadGeneration = 0

    func install(on configuration: WKWebViewConfiguration) {
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

    func load(_ html: String, baseURL: URL?, fragment: String? = nil, in webView: WKWebView) {
        loadGeneration += 1
        let generation = loadGeneration
        Task { [weak self, weak webView] in
            let content = await Task.detached(priority: .userInitiated) {
                Self.rewriteContent(html, baseURL: baseURL)
            }.value
            guard let self, let webView, generation == self.loadGeneration else { return }
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
        webView.load(URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData))
    }
}

private final class MemoryDocumentSchemeHandler: NSObject, WKURLSchemeHandler {
    private let lock = NSLock()
    private var document: (url: URL, data: Data)?

    func setDocument(url: URL, html: String) {
        lock.withLock { document = (url, Data(html.utf8)) }
    }

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
            let source = sourceHTML.substring(with: range)
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
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
