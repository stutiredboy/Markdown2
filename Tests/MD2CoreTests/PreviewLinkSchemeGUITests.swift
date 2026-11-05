import MD2Core
import WebKit
import XCTest
@testable import MD2App

/// A link in a diagram opens only what a Markdown link can. An engine draws its
/// own links, so they never pass `HTMLSafety`, and `PreviewLinkRouter` is the only
/// thing between a click and the system.
///
/// The failure is silent, and a test of it has to be built with care:
/// - "Nothing opened" also holds for a click that missed, so each click is checked
///   against the page, and the last one lands on a link that must open. Clicks
///   arrive in order, so once that one has opened, the refused ones have had their
///   chance and no wait is needed.
/// - Mermaid removes `ssh://` from its output, which makes it a poor fixture: the
///   link is gone before the router could fail. These use schemes it keeps.
///
/// Requires a GUI session (WebKit), so opt-in to stay CI-safe:
/// `MD2_RUN_GUI_TESTS=1 swift test --filter PreviewLinkSchemeGUITests`.
final class PreviewLinkSchemeGUITests: XCTestCase, RenderedPageTesting {
    private static let allowed = "https://example.com/after"

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed test."
        )
    }

    private func flow(_ link: String) -> String {
        """
        ```flow
        st=>start: Refused:>\(link)
        e=>end: Allowed:>\(Self.allowed)
        st->e
        ```
        """
    }

    @MainActor func testFlowLinkToARefusedSchemeOpensNothing() throws {
        for link in ["ssh://example.com", "x-man-page://ls", "tel:123"] {
            try assertOpensOnlyTheAllowedLink(flow(link), refused: link)
        }
    }

    @MainActor func testFlowLinkAskingForANewWindowOpensNothing() throws {
        try assertOpensOnlyTheAllowedLink(flow("ssh://example.com[blank]"), refused: "ssh://example.com")
    }

    /// WebKit tidies these before the router sees them, so the rule has to hold
    /// for what it parsed, not for what the document wrote.
    @MainActor func testFlowLinkSpelledDifferentlyOpensNothing() throws {
        for link in ["SSH://example.com", " ssh://example.com", "s\tsh://example.com"] {
            try assertOpensOnlyTheAllowedLink(flow(link), refused: link)
        }
    }

    @MainActor func testMermaidClickToARefusedSchemeOpensNothing() throws {
        try assertOpensOnlyTheAllowedLink("""
            ```mermaid
            flowchart LR
              A[Refused] --> B[Allowed]
              click A href "tel:123"
              click B href "\(Self.allowed)"
            ```
            """, refused: "tel:123")
    }

    @MainActor func testMermaidClassLinkToARefusedSchemeOpensNothing() throws {
        try assertOpensOnlyTheAllowedLink("""
            ```mermaid
            classDiagram
              class Refused
              class Allowed
              Refused --> Allowed
              link Refused "ftp://example.com/x"
              link Allowed "\(Self.allowed)"
            ```
            """, refused: "ftp://example.com/x")
    }

    @MainActor func testMermaidLabelLinkToARefusedSchemeOpensNothing() throws {
        try assertOpensOnlyTheAllowedLink("""
            ```mermaid
            flowchart LR
              A["<a href='xmpp:someone@example.com'>Refused</a>"] --> B["<a href='\(Self.allowed)'>Allowed</a>"]
            ```
            """, refused: "xmpp:someone@example.com")
    }

    /// The rule must not take away what a diagram link can already do.
    @MainActor func testDiagramLinksMarkdownAllowsStillOpen() throws {
        let links = ["http://example.com/plain", "mailto:someone@example.com"]
        for link in links {
            var opened: [URL] = []
            try withPage(flow(link), on: .preview, onOpenWithSystem: { opened.append($0) }) { webView in
                try click(link: link, in: webView)
                XCTAssertTrue(spin(5) { !opened.isEmpty }, "\(link) opened nothing")
            }
            XCTAssertEqual(opened.map(\.absoluteString), [link])
        }
    }

    // MARK: - Helpers

    /// Clicks the `refused` link in `source`, then the allowed one.
    @MainActor private func assertOpensOnlyTheAllowedLink(
        _ source: String, refused: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        var opened: [URL] = []
        try withPage(source, on: .preview, onOpenWithSystem: { opened.append($0) }) { webView in
            _ = try evaluate("""
                window.__md2Clicked = [];
                document.addEventListener('click', function (event) {
                    var link = event.target.closest('a');
                    window.__md2Clicked.push(link && event.isTrusted ? \(Self.href("link")) : null);
                }, true);
                true;
                """, in: webView)
            try click(link: refused, in: webView)
            try click(link: Self.allowed, in: webView)
            XCTAssertTrue(
                spin(5) { opened.last?.absoluteString == Self.allowed },
                "the allowed link opened nothing", file: file, line: line
            )
            XCTAssertEqual(
                try evaluate("window.__md2Clicked", in: webView) as? [String], [refused, Self.allowed],
                "a click missed its link, so this proves nothing", file: file, line: line
            )
        }
        XCTAssertEqual(opened.map(\.absoluteString), [Self.allowed], file: file, line: line)
    }

    /// The written target of `link`, which is an `xlink:href` on an SVG link.
    private static func href(_ link: String) -> String {
        "(\(link).getAttribute('href') || \(link).getAttributeNS('http://www.w3.org/1999/xlink', 'href'))"
    }

    @MainActor private func click(link target: String, in webView: WKWebView) throws {
        let literal = String(data: try JSONEncoder().encode(target), encoding: .utf8)!
        let link = "Array.from(document.querySelectorAll('.diagram a')).find(function (a) { return \(Self.href("a")) === \(literal); })"
        XCTAssertEqual(try evaluate("!!(\(link))", in: webView) as? Bool, true, "\(target) is not in the page")
        try click("(function (a) { return a.firstElementChild || a; })(\(link))", in: webView)
    }
}
