import Foundation

/// Classifies a navigation target inside the rendered preview against the
/// app-owned document page, deciding whether the web view may navigate or how
/// the target is handed off instead. Pure (no WebKit dependency) so the link
/// policy is unit-testable.
enum PreviewLinkRouter {
    enum Route: Equatable {
        /// The app's own rendered page — the initial load, a reload, or a
        /// same-page fragment jump. The web view may navigate.
        case allowInPage
        /// Nothing can meaningfully handle the target (unresolvable relative
        /// link from an untitled document, app-internal schemes): cancel the
        /// navigation and do nothing.
        case ignore
        /// A non-file link (https, mailto, …): open with the system handler.
        case openExternal(URL)
        /// A local Markdown file: open in Markdown2.
        case openMarkdownDocument(URL)
        /// Any other local file: open with its default application.
        case openWithSystem(URL)
    }

    private static let markdownExtensions: Set<String> = ["md", "markdown"]

    /// Schemes backing the page shell itself rather than openable content.
    /// `about:` hosts `loadHTMLString` pages (untitled documents), where a
    /// fragment jump arrives as `about:blank#…`; `applewebdata:` is WebKit's
    /// synthetic base for string-loaded pages on some paths. Relative links on
    /// such pages cannot resolve to a file, so they collapse to these schemes
    /// (or to no navigation at all) and must never leave the page.
    private static let inPageSchemes: Set<String> = ["about", "applewebdata"]

    /// Routes `target` given the app-owned page URL: the preview temp file
    /// when the document was loaded via `loadFileRequest`, or `nil` for the
    /// `loadHTMLString` (untitled document) mode.
    static func route(for target: URL?, documentPageURL: URL?) -> Route {
        guard let target, let scheme = target.scheme?.lowercased() else {
            return .ignore
        }

        if inPageSchemes.contains(scheme) {
            guard documentPageURL == nil else {
                return .ignore
            }
            return .allowInPage
        }

        if target.isFileURL {
            // `URL.path` decodes percent-encoding, and `standardizedFileURL`
            // resolves `.`/`..`, so encoding and path-form variants of the
            // same file compare equal. Fragment and query never reach `path`,
            // which is exactly the same-page-anchor allowance.
            if let documentPageURL,
               target.standardizedFileURL.path == documentPageURL.standardizedFileURL.path {
                return .allowInPage
            }
            if markdownExtensions.contains(target.pathExtension.lowercased()) {
                return .openMarkdownDocument(target)
            }
            return .openWithSystem(target)
        }

        if scheme == LocalImageSchemeHandler.scheme {
            return .ignore
        }

        return .openExternal(target)
    }
}
