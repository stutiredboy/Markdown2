import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves only the local image files that the current rendered document already
/// references. This keeps absolute and document-relative image links working
/// without granting a WKWebView read access to the whole filesystem.
final class LocalImageSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "md2-local-image"

    private let lock = NSLock()
    private var imageURLsByToken: [String: URL] = [:]

    func setAllowedImages(_ images: [String: URL]) {
        lock.withLock {
            imageURLsByToken = images
        }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let token = url.pathComponents.dropFirst().first,
              let imageURL = imageURL(for: token) else {
            fail(urlSchemeTask)
            return
        }

        do {
            let data = try Data(contentsOf: imageURL)
            let response = URLResponse(
                url: url,
                mimeType: Self.mimeType(for: imageURL),
                expectedContentLength: data.count,
                textEncodingName: nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            fail(urlSchemeTask, error: error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func imageURL(for token: String) -> URL? {
        lock.withLock {
            imageURLsByToken[token]
        }
    }

    private func fail(_ task: WKURLSchemeTask, error: Error? = nil) {
        let failure = error ?? URLError(.fileDoesNotExist)
        task.didFailWithError(failure)
    }

    private static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }
        return "application/octet-stream"
    }
}

struct LocalImageHTMLRewriter {
    private static let imgTagPattern = #"<img\b[^>]*\bsrc="([^"]*)"[^>]*>"#

    /// Rewrites resolvable local image sources to the app-local scheme and returns
    /// the exact file whitelist the scheme handler may serve. Relative sources are
    /// resolved from `baseURL`, including paths that traverse to a parent folder.
    static func rewrite(_ html: String, baseURL: URL? = nil) -> (html: String, allowedImages: [String: URL]) {
        guard let regex = try? NSRegularExpression(pattern: imgTagPattern, options: [.caseInsensitive]) else {
            return (html, [:])
        }

        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: nsRange)
        guard !matches.isEmpty else { return (html, [:]) }

        var rewritten = html
        var allowedImages: [String: URL] = [:]

        for match in matches.reversed() {
            guard let sourceRange = Range(match.range(at: 1), in: rewritten),
                  let imageURL = localImageURL(
                    fromHTMLSource: String(rewritten[sourceRange]),
                    baseURL: baseURL
                  ) else {
                continue
            }

            let token = UUID().uuidString
            allowedImages[token] = imageURL
            rewritten.replaceSubrange(
                sourceRange,
                with: "\(LocalImageSchemeHandler.scheme)://image/\(token)"
            )
        }

        return (rewritten, allowedImages)
    }

    private static func localImageURL(fromHTMLSource source: String, baseURL: URL?) -> URL? {
        let unescaped = htmlUnescaped(source)
        let lower = unescaped.lowercased()
        let url: URL?

        if lower.hasPrefix("file://"), let parsed = URL(string: unescaped), parsed.isFileURL {
            url = parsed
        } else if unescaped.hasPrefix("/") {
            url = URL(fileURLWithPath: unescaped.removingPercentEncoding ?? unescaped)
        } else if unescaped.contains("://") {
            url = nil
        } else if let baseURL {
            let relativePath = unescaped.removingPercentEncoding ?? unescaped
            url = baseURL.appendingPathComponent(relativePath).standardizedFileURL
        } else {
            url = nil
        }

        guard let url,
              isSupportedImageFile(url),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    private static func isSupportedImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return type.conforms(to: .image)
    }

    private static func htmlUnescaped(_ source: String) -> String {
        source
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
