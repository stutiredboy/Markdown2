import Foundation
import Testing
@testable import MD2App
@testable import MD2Core

struct PreviewLinkRouterTests {
    private let pageURL = URL(fileURLWithPath: "/tmp/docs/.md2-preview-ABC.html")

    @Test func externalHTTPSOpensExternally() {
        let target = URL(string: "https://example.com/page")!
        #expect(PreviewLinkRouter.route(for: target, documentPageURL: pageURL) == .openExternal(target))
    }

    @Test func mailtoOpensExternally() {
        let target = URL(string: "mailto:someone@example.com")!
        #expect(PreviewLinkRouter.route(for: target, documentPageURL: pageURL) == .openExternal(target))
    }

    @Test func externalLinkFromUntitledDocumentOpensExternally() {
        let target = URL(string: "https://example.com")!
        #expect(PreviewLinkRouter.route(for: target, documentPageURL: nil) == .openExternal(target))
    }

    @Test(arguments: [
        "http://example.com", "https://example.com/page", "HTTPS://example.com",
        "mailto:someone@example.com", "MailTo:someone@example.com"
    ])
    func schemeMarkdownAllowsOpensExternally(source: String) {
        let target = URL(string: source)!
        #expect(HTMLSafety.isSafeURL(source))
        #expect(PreviewLinkRouter.route(for: target, documentPageURL: pageURL) == .openExternal(target))
        #expect(PreviewLinkRouter.route(for: target, documentPageURL: nil) == .openExternal(target))
    }

    /// A diagram engine draws its own links, so these reach the router without
    /// passing `HTMLSafety`: `flow` names anything, and the `ftp` to `matrix` rows
    /// are the ones Mermaid's sanitizing keeps at `strict`.
    @Test(arguments: [
        "ssh://example.com", "SSH://example.com", "x-man-page://ls", "shortcuts://run-shortcut?name=x",
        "vnc://example.com", "smb://example.com/share", "facetime:someone@example.com",
        "ftp://example.com/x", "ftps://example.com/x", "tel:123", "callto:123", "sms:123",
        "cid:123", "xmpp:someone@example.com", "matrix:u/someone",
        "data:text/html,x", "blob:https://example.com/id", "no-such-scheme://x"
    ])
    func schemeMarkdownRefusesIsIgnored(source: String) {
        let target = URL(string: source)!
        #expect(!HTMLSafety.isSafeURL(source))
        #expect(PreviewLinkRouter.route(for: target, documentPageURL: pageURL) == .ignore)
        #expect(PreviewLinkRouter.route(for: target, documentPageURL: nil) == .ignore)
    }

    /// A `flow` link that asks for a new window reaches the router before the
    /// page's policy can refuse it, so the router must not pass it on.
    @Test(arguments: ["javascript:window.pwned=1", "JavaScript:window.pwned=1"])
    func scriptURLIsIgnored(source: String) {
        let target = URL(string: source)!
        #expect(PreviewLinkRouter.route(for: target, documentPageURL: pageURL) == .ignore)
        #expect(PreviewLinkRouter.route(for: target, documentPageURL: nil) == .ignore)
    }

    @Test func samePageFragmentIsAllowedInPage() {
        let target = URL(string: "file:///tmp/docs/.md2-preview-ABC.html#heading-1")!
        #expect(PreviewLinkRouter.route(for: target, documentPageURL: pageURL) == .allowInPage)
    }

    @Test func samePageWithoutFragmentIsAllowedInPage() {
        let target = URL(fileURLWithPath: "/tmp/docs/.md2-preview-ABC.html")
        #expect(PreviewLinkRouter.route(for: target, documentPageURL: pageURL) == .allowInPage)
    }

    @Test func samePageWithQueryIsAllowedInPage() {
        let target = URL(string: "file:///tmp/docs/.md2-preview-ABC.html?x=1#frag")!
        #expect(PreviewLinkRouter.route(for: target, documentPageURL: pageURL) == .allowInPage)
    }

    @Test func percentEncodedVariantOfPageIsAllowedInPage() {
        let page = URL(fileURLWithPath: "/tmp/my docs/.md2-preview-ABC.html")
        let target = URL(string: "file:///tmp/my%20docs/.md2-preview-ABC.html#frag")!
        #expect(PreviewLinkRouter.route(for: target, documentPageURL: page) == .allowInPage)
    }

    @Test func dotSegmentVariantOfPageIsAllowedInPage() {
        let target = URL(string: "file:///tmp/docs/sub/../.md2-preview-ABC.html")!
        #expect(PreviewLinkRouter.route(for: target, documentPageURL: pageURL) == .allowInPage)
    }

    @Test func markdownFileOpensInApp() {
        let target = URL(fileURLWithPath: "/tmp/docs/chapter2.md")
        #expect(
            PreviewLinkRouter.route(for: target, documentPageURL: pageURL)
                == .openMarkdownDocument(target)
        )
    }

    @Test func markdownExtensionMatchingIsCaseInsensitive() {
        let upper = URL(fileURLWithPath: "/tmp/docs/NOTES.MD")
        let long = URL(fileURLWithPath: "/tmp/docs/readme.markdown")
        #expect(
            PreviewLinkRouter.route(for: upper, documentPageURL: pageURL)
                == .openMarkdownDocument(upper)
        )
        #expect(
            PreviewLinkRouter.route(for: long, documentPageURL: pageURL)
                == .openMarkdownDocument(long)
        )
    }

    @Test func absoluteMarkdownLinkFromUntitledDocumentOpensInApp() {
        let target = URL(fileURLWithPath: "/tmp/docs/other.md")
        #expect(
            PreviewLinkRouter.route(for: target, documentPageURL: nil)
                == .openMarkdownDocument(target)
        )
    }

    @Test func otherLocalFileOpensWithSystem() {
        let target = URL(fileURLWithPath: "/tmp/docs/spec.pdf")
        #expect(PreviewLinkRouter.route(for: target, documentPageURL: pageURL) == .openWithSystem(target))
    }

    @Test func nilTargetIsIgnored() {
        #expect(PreviewLinkRouter.route(for: nil, documentPageURL: pageURL) == .ignore)
    }

    @Test func aboutBlankFragmentOnStringLoadedPageIsAllowedInPage() {
        let target = URL(string: "about:blank%23heading")
            ?? URL(string: "about:blank")!
        #expect(PreviewLinkRouter.route(for: target, documentPageURL: nil) == .allowInPage)
    }

    @Test func aboutBlankIsAllowedInPage() {
        let target = URL(string: "about:blank")!
        #expect(PreviewLinkRouter.route(for: target, documentPageURL: nil) == .allowInPage)
    }

    @Test func aboutBlankFromSavedDocumentIsIgnored() {
        let target = URL(string: "about:blank")!
        #expect(PreviewLinkRouter.route(for: target, documentPageURL: pageURL) == .ignore)
    }

    @Test func appleWebDataFromSavedDocumentIsIgnored() {
        let target = URL(string: "applewebdata://ABCDEF")!
        #expect(PreviewLinkRouter.route(for: target, documentPageURL: pageURL) == .ignore)
    }

    @Test func localImageSchemeIsIgnored() {
        let target = URL(string: "md2-local-image://image/token")!
        #expect(PreviewLinkRouter.route(for: target, documentPageURL: pageURL) == .ignore)
    }

    @Test func bundledAssetSchemeIsIgnored() {
        let target = URL(string: "\(BundledWebAsset.scheme)://asset/katex.min.js")!
        #expect(PreviewLinkRouter.route(for: target, documentPageURL: pageURL) == .ignore)
    }
}
