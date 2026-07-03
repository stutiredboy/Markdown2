import Foundation
import Testing
@testable import MD2App

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
}
