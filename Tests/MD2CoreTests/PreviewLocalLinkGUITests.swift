import AppKit
import MD2Core
import WebKit
import XCTest
@testable import MD2App

/// WebKit can refuse file navigation before asking its navigation delegate.
/// Exercise real clicks on the actual custom-scheme preview, not just the router.
final class PreviewLocalLinkGUITests: XCTestCase, RenderedPageTesting {
    private var directory: URL!
    private var markdownFile: URL!
    private var pdfFile: URL!
    private static let controlURL = URL(string: "https://example.com/control")!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
                          "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed test.")
        try MainActor.assumeIsolated {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("md2-local-links-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            markdownFile = directory.appendingPathComponent("next chapter.MD")
            pdfFile = directory.appendingPathComponent("manual.pdf")
            try Data("# Next chapter".utf8).write(to: markdownFile)
            // Tests observe the handoff, without launching any real file handler.
            try Data("PDF handoff fixture".utf8).write(to: pdfFile)
        }
    }

    override func tearDownWithError() throws {
        try MainActor.assumeIsolated {
            if let directory { try FileManager.default.removeItem(at: directory) }
        }
    }

    @MainActor func testRelativeMarkdownAndPDFLinksReachTheirHandlers() throws {
        var documents: [URL] = []
        var external: [URL] = []
        try withPage("""
            [**Next chapter**](next%20chapter.MD)

            [Manual](manual.pdf)

            [Control](\(Self.controlURL))
            """, on: .preview, baseURL: directory,
            onOpenMarkdownLink: { documents.append($0) }, onOpenWithSystem: { external.append($0) }) { webView in
            let pageURL = webView.url
            try recordClicks(in: webView)
            try click("document.querySelector('main a strong')", in: webView)
            try click("document.querySelectorAll('main a')[1]", in: webView)
            try click("document.querySelectorAll('main a')[2]", in: webView)
            XCTAssertTrue(spin(5) { external.last == Self.controlURL }, "the positive-control click missed")
            XCTAssertEqual(try evaluate("window.__localLinkClicks", in: webView) as? [Bool], [true, true, true])
            XCTAssertEqual(webView.url, pageURL, "a link must not replace the preview")
        }
        XCTAssertEqual(documents, [markdownFile!])
        XCTAssertEqual(external, [pdfFile!, Self.controlURL])
    }

    @MainActor func testAbsoluteLocalLinksFromUntitledSupportNewWindowAndCommandClick() throws {
        var documents: [URL] = []
        try withPage("[Next](\(markdownFile.absoluteString))", on: .preview,
                     onOpenMarkdownLink: { documents.append($0) }) { webView in
            _ = try evaluate("document.querySelector('main a').target = '_blank'; true", in: webView)
            try click("document.querySelector('main a')", in: webView)
            XCTAssertTrue(spin(3) { documents.count == 1 }, "target=_blank dropped the local link")
            _ = try evaluate("document.querySelector('main a').removeAttribute('target'); true", in: webView)
            try click("document.querySelector('main a')", in: webView, modifiers: .command)
            XCTAssertTrue(spin(3) { documents.count == 2 }, "Command-click dropped the local link")
        }
        XCTAssertEqual(documents, [markdownFile!, markdownFile!])
    }

    @MainActor func testInsertedClipboardLinksOpenTheirOriginalURLs() throws {
        let clipboardURLs = [
            "https://example.com/?literal=&copy;",
            "https://example.com/?literal=&#35;target",
            "https://example.com/?literal=&amp;",
            "https://example.com/a<b>"
        ]
        let expected = try clipboardURLs.map { try XCTUnwrap(URL(string: $0)) }
        let markdown = try clipboardURLs.enumerated().map { index, clipboard in
            let label = "Link \(index + 1)"
            let edit = try XCTUnwrap(MarkdownEditing.edit(label,
                selection: NSRange(location: 0, length: label.utf16.count), action: .link, clipboard: clipboard))
            return (label as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        }.joined(separator: "\n\n")
        var external: [URL] = []
        try withPage(markdown, on: .preview, onOpenWithSystem: { external.append($0) }) { webView in
            let pageURL = webView.url
            try recordClicks(in: webView)
            _ = try evaluate("document.querySelector('main a').click(); true", in: webView)
            XCTAssertTrue(external.isEmpty)
            for index in clipboardURLs.indices {
                try click("document.querySelectorAll('main a')[\(index)]", in: webView)
                XCTAssertTrue(spin(3) { external.count == index + 1 }, "inserted URL click missed")
            }
            XCTAssertEqual(try evaluate("window.__localLinkClicks", in: webView) as? [Bool],
                           [false] + Array(repeating: true, count: clipboardURLs.count))
            XCTAssertEqual(webView.url, pageURL)
        }
        XCTAssertEqual(external, expected)
    }

    @MainActor func testEntityEncodedLocalLinksReachTheExactFilesAndFragments() throws {
        let cases: [(destination: String, filename: String, fragment: String)] = [
            ("next&#32;chapter.MD&#35;target", "next chapter.MD", "target"),
            ("next&#x20;chapter.MD&#x23;t&#97;rget", "next chapter.MD", "target"),
            ("next&#X20;chapter.MD&#X23;target", "next chapter.MD", "target"),
            ("caf&eacute;.md&num;x&amp;y", "café.md", "x&y"),
            ("literal%2523.md&num;target", "literal%23.md", "target"),
            ("literal&amp;num;.md#target", "literal&num;.md", "target")
        ]
        let expected: [URL] = try cases.map { testCase in
            let file = directory.appendingPathComponent(testCase.filename)
            try Data("# Target\n\nFixture: \(testCase.filename)".utf8).write(to: file)
            var components = try XCTUnwrap(URLComponents(url: file, resolvingAgainstBaseURL: false))
            components.fragment = testCase.fragment
            return try XCTUnwrap(components.url)
        }
        let markdown = cases.enumerated().map { "[Link \($0.offset + 1)](\($0.element.destination))" }.joined(separator: "\n\n")
        var documents: [URL] = []
        var external: [URL] = []
        var missing: [URL] = []
        try withPage(markdown, on: .preview, baseURL: directory,
                     onOpenMarkdownLink: { documents.append($0) },
                     onMissingLocalLink: { missing.append($0) },
                     onOpenWithSystem: { external.append($0) }) { webView in
            let pageURL = webView.url
            try recordClicks(in: webView)
            _ = try evaluate("document.querySelector('main a').click(); true", in: webView)
            XCTAssertTrue(documents.isEmpty, "entity decoding must not grant synthetic clicks native access")
            for index in cases.indices {
                let element = "document.querySelectorAll('main a')[\(index)]"
                let href = try XCTUnwrap(try evaluate("\(element).getAttribute('href')", in: webView) as? String)
                let destination = try XCTUnwrap(URL(string: href))
                XCTAssertTrue(LocalFileLinkDestination.matches(destination, expected[index]),
                              "DOM destination \(destination) differs from \(expected[index])")
                try click(element, in: webView)
                XCTAssertTrue(spin(3) { documents.count == index + 1 }, "local handoff missed \(cases[index].destination)")
            }
            XCTAssertEqual(try evaluate("window.__localLinkClicks", in: webView) as? [Bool],
                           [false] + Array(repeating: true, count: cases.count))
            XCTAssertEqual(webView.url, pageURL)
        }
        XCTAssertEqual(documents.count, expected.count)
        for (index, pair) in zip(documents, expected).enumerated() {
            XCTAssertTrue(LocalFileLinkDestination.matches(pair.0, pair.1),
                          "handoff \(pair.0) differs from \(pair.1)")
            // Prove the handler received the real fixture, including literal
            // percent/entity filenames, rather than only a plausible URL spelling.
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: pair.0.path)),
                           Data("# Target\n\nFixture: \(cases[index].filename)".utf8))
        }
        XCTAssertTrue(external.isEmpty)
        XCTAssertTrue(missing.isEmpty)
    }

    @MainActor func testDoubleEncodedNumericEntityDoesNotRetargetTheMarkdownFile() throws {
        // One HTML decode leaves a literal '&#35;': the ampersand belongs to
        // the filename and '#35;target' is the fragment. A second decode would
        // incorrectly open the existing Markdown file without that ampersand.
        let literalFile = directory.appendingPathComponent("next chapter.MD&")
        try Data("Literal ampersand fixture".utf8).write(to: literalFile)
        var components = try XCTUnwrap(URLComponents(url: literalFile, resolvingAgainstBaseURL: false))
        components.fragment = "35;target"
        let expected = try XCTUnwrap(components.url)
        var documents: [URL] = []
        var external: [URL] = []
        try withPage("""
            [Literal entity](next%20chapter.MD&amp;#35;target)

            [Control](next%20chapter.MD)
            """, on: .preview, baseURL: directory,
            onOpenMarkdownLink: { documents.append($0) }, onOpenWithSystem: { external.append($0) }) { webView in
            try recordClicks(in: webView)
            try click("document.querySelector('main a')", in: webView)
            XCTAssertTrue(spin(3) { external.count == 1 }, "the literal ampersand target did not reach its handler")
            XCTAssertTrue(documents.isEmpty, "double decoding retargeted the Markdown file")
            try click("document.querySelectorAll('main a')[1]", in: webView)
            XCTAssertTrue(spin(3) { documents.count == 1 }, "the ordinary Markdown positive control missed")
            XCTAssertEqual(try evaluate("window.__localLinkClicks", in: webView) as? [Bool], [true, true])
        }
        XCTAssertEqual(external, [expected])
        XCTAssertEqual(documents, [markdownFile!])
    }

    @MainActor func testFlowSVGLocalLinkReachesTheMarkdownHandler() throws {
        var documents: [URL] = []
        try withPage("""
            ```flow
            st=>start: Next:>\(markdownFile.absoluteString)
            e=>end: End
            st->e
            ```
            """, on: .preview, onOpenMarkdownLink: { documents.append($0) }) { webView in
            try recordClicks(in: webView)
            try click("document.querySelector('.diagram a').firstElementChild", in: webView)
            XCTAssertTrue(spin(3) { documents.count == 1 })
            XCTAssertEqual(try evaluate("window.__localLinkClicks", in: webView) as? [Bool], [true])
        }
        XCTAssertEqual(documents, [markdownFile!])
    }

    @MainActor func testPageScriptsAndMissingTargetsCannotOpenLocalFiles() throws {
        var documents: [URL] = []
        var external: [URL] = []
        try withPage("""
            [Next](next%20chapter.MD)

            [Missing](missing.md)

            [Control](\(Self.controlURL))
            """, on: .preview, edit: RenderedPageEdit.removingPolicy, baseURL: directory,
            onOpenMarkdownLink: { documents.append($0) }, onOpenWithSystem: { external.append($0) }) { webView in
            XCTAssertEqual(try evaluate("typeof window.webkit?.messageHandlers?.openLocalLink", in: webView) as? String,
                           "undefined", "document scripts must not see the native open handler")
            _ = try evaluate("""
                var link = document.querySelector('main a');
                link.click();
                link.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
                true;
                """, in: webView)
            try click("document.querySelectorAll('main a')[1]", in: webView)
            try click("document.querySelectorAll('main a')[2]", in: webView)
            XCTAssertTrue(spin(5) { external.last == Self.controlURL })
            XCTAssertTrue(documents.isEmpty)
            XCTAssertEqual(external, [Self.controlURL])
            // Positive control: the same existing link opens on a real click.
            try click("document.querySelector('main a')", in: webView)
            XCTAssertTrue(spin(3) { documents.count == 1 })
        }
        XCTAssertEqual(documents, [markdownFile!])
    }

    @MainActor func testMissingLocalTargetReportsARealClickWithoutOpeningAnything() throws {
        var missing: [URL] = []
        var opened: [URL] = []
        try withPage("[Missing](missing.md)", on: .preview, baseURL: directory,
                     onOpenMarkdownLink: { opened.append($0) },
                     onMissingLocalLink: { missing.append($0) }) { webView in
            try recordClicks(in: webView)
            _ = try evaluate("document.querySelector('main a').click(); true", in: webView)
            XCTAssertTrue(missing.isEmpty, "synthetic clicks must not trigger native alerts")
            try click("document.querySelector('main a')", in: webView)
            XCTAssertTrue(spin(3) { missing.count == 1 }, "a missing target was silently ignored")
            XCTAssertEqual(try evaluate("window.__localLinkClicks", in: webView) as? [Bool], [false, true])
        }
        XCTAssertEqual(missing, [directory.appendingPathComponent("missing.md")])
        XCTAssertTrue(opened.isEmpty)
    }

    @MainActor func testLinksInsertedByALiveUpdateStillOpen() throws {
        var documents: [URL] = []
        try withPage("Original paragraph.", on: .preview, baseURL: directory,
                     onOpenMarkdownLink: { documents.append($0) }) { webView in
            let coordinator = try XCTUnwrap(webView.navigationDelegate as? MarkdownPreviewView.Coordinator)
            XCTAssertTrue(spin(5) { coordinator.isLoaded })
            _ = try evaluate("window.__localLinkOriginalPage = true; true", in: webView)
            let body = MarkdownRenderer().render("[Added link](next&#32;chapter.MD)", assetMode: .appScheme).body
            coordinator.applyLiveContent(body, mathMacros: [:], in: webView)
            XCTAssertTrue(spin(5) {
                (try? self.evaluate("document.querySelector('main a')?.textContent", in: webView)) as? String == "Added link"
            })
            XCTAssertEqual(try evaluate("window.__localLinkOriginalPage", in: webView) as? Bool, true)
            try click("document.querySelector('main a')", in: webView)
            XCTAssertTrue(spin(3) { documents.count == 1 })
        }
        XCTAssertEqual(documents, [markdownFile!])
    }

    @MainActor func testFragmentsAndUnresolvedRelativeLinksStayInThePreview() throws {
        var documents: [URL] = []
        var external: [URL] = []
        try withPage("""
            [Missing base](next%20chapter.MD)

            [Heading](#target)

            [Control](\(Self.controlURL))

            # Target
            """, on: .preview, onOpenMarkdownLink: { documents.append($0) },
            onOpenWithSystem: { external.append($0) }) { webView in
            // Use the renderer's actual heading ID rather than assuming its slug format.
            _ = try evaluate("document.querySelectorAll('main a')[1].href = '#' + document.querySelector('h1').id; true", in: webView)
            let pageURL = try XCTUnwrap(webView.url)
            try click("document.querySelectorAll('main a')[0]", in: webView)
            try click("document.querySelectorAll('main a')[1]", in: webView)
            XCTAssertTrue(spin(3) { webView.url?.fragment != nil }, "the in-page anchor stopped navigating")
            try click("document.querySelectorAll('main a')[2]", in: webView)
            XCTAssertTrue(spin(5) { external.last == Self.controlURL })
            XCTAssertEqual(webView.url?.host, pageURL.host)
            XCTAssertEqual(webView.url?.path, pageURL.path)
        }
        XCTAssertTrue(documents.isEmpty)
        XCTAssertEqual(external, [Self.controlURL])
    }

    @MainActor private func recordClicks(in webView: WKWebView) throws {
        _ = try evaluate("""
            window.__localLinkClicks = [];
            document.addEventListener('click', function (event) {
                window.__localLinkClicks.push(event.isTrusted && !!event.target.closest('a'));
            }, true);
            true;
            """, in: webView)
    }
}
