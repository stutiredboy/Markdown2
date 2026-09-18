import AppKit
import WebKit
import XCTest
import MD2Core
@testable import MD2App

/// GUI-gated verification of the preview's line-number gutter, driven through the
/// real injected script (`MarkdownPreviewView.lineNumberGutterScript`) in an
/// offscreen `WKWebView`.
///
/// The guarded failures are silent — a gutter that stops matching its blocks, a
/// re-render that drops the numbers, or digits that leak into find — so these run
/// on demand rather than in the default suite:
/// `MD2_RUN_GUI_TESTS=1 swift test --filter LineNumberGutterGUITests`.
final class LineNumberGutterGUITests: XCTestCase {
    /// Front matter (line 1-2) is hidden in the front-matter assertions below, so
    /// the first *visible* block is the heading on line 4. Every expectation is a
    /// literal line number from this document, not a value read back from the
    /// renderer — the point is that the gutter agrees with the source.
    private let document = """
    ---
    title: Gutter
    ---
    # Heading

    Intro paragraph
    wrapped onto a second line.

    ```swift
    let x = 1
    ```

    Cited work [@smith2023] and a note[^n].

    [^n]: The footnote body.

    Closing paragraph.
    """

    private let bib = """
    @article{smith2023,
      title = {A Study},
      author = {Smith, Ada},
      year = {2023},
      journal = {Journal}
    }
    """

    private func renderGutterPage() -> String {
        MarkdownRenderer().render(
            document,
            config: RenderConfig(bibliography: BibTeXParser.parse(bib))
        ).html
    }

    // MARK: - The gutter agrees with the source

    @MainActor
    func testGutterMatchesSourceLinesAndSkipsWrapperSections() throws {
        try skipUnlessGUITestsEnabled()

        let probe = """
        (function () {
          var main = document.querySelector('main');
          function lineOf(selector) {
            var el = main.querySelector(selector);
            return el ? el.getAttribute('data-md2-source-line') : null;
          }          function numbersByTop() {
            var spans = document.querySelectorAll('.md2-line-gutter span');
            var out = [];
            for (var i = 0; i < spans.length; i++) {
              out.push({ n: spans[i].getAttribute('data-md2-gutter'), top: spans[i].style.top });
            }
            return out;
          }
          // Blocks the gutter is expected to number: direct children of <main>
          // carrying source-line metadata that actually lay out. The hidden
          // front-matter block reports a zero rect and is skipped by the same
          // rule production uses.
          var eligible = [];
          for (var i = 0; i < main.children.length; i++) {
            var child = main.children[i];
            if (child.classList.contains('md2-line-gutter')) { continue; }
            if (!child.hasAttribute('data-md2-source-line')) { continue; }
            var box = child.getBoundingClientRect();
            if (box.width === 0 && box.height === 0) { continue; }
            eligible.push(child);
          }
          var numbers = [];
          for (var j = 0; j < eligible.length; j++) {
            numbers.push(eligible[j].getAttribute('data-md2-source-line'));
          }
          // The rendered attribute values, for comparison against the source.
          var rendered = {
            heading: lineOf('h1'),
            paragraph: lineOf('p'),
            code: lineOf('pre:not(.front-matter)'),
            footnotesPresent: !!main.querySelector('section.footnotes'),
            bibliographyPresent: !!main.querySelector('section.bibliography')
          };
          return {
            rendered: rendered,
            eligibleCount: eligible.length,
            eligibleNumbers: numbers,
            gutterNumbers: numbersByTop().map(function (s) { return s.n; }),
            gutterCount: numbersByTop().length,
            footnoteSectionNumbered: (function () {
              var section = main.querySelector('section.footnotes');
              return section ? section.hasAttribute('data-md2-source-line') : false;
            })(),
            bibliographySectionNumbered: (function () {
              var section = main.querySelector('section.bibliography');
              return section ? section.hasAttribute('data-md2-source-line') : false;
            })(),
            liNumbers: document.querySelectorAll('.md2-line-gutter li').length,
            layerIsDirectChildOfMain: (function () {
              var layer = main.querySelector('.md2-line-gutter');
              return !!layer && layer.parentNode === main;
            })(),
            layerIsLastChild: (function () {
              var layer = main.querySelector('.md2-line-gutter');
              return !!layer && main.lastElementChild === layer;
            })()
          };
        })()
        """

        let result = try loadAndProbe(html: renderGutterPage(), probe: probe)
        let rendered = result["rendered"] as? [String: Any] ?? [:]

        // The source lines the document puts these blocks on. The front matter
        // occupies lines 1-3, so the heading is line 4.
        XCTAssertEqual(rendered["heading"] as? String, "4", "heading should be attributed to source line 4")
        XCTAssertEqual(rendered["paragraph"] as? String, "6", "first paragraph should be on line 6")
        XCTAssertEqual(rendered["code"] as? String, "9", "code fence should be on line 9")

        // One number per eligible top-level block, in document order — and the
        // literal expected numbers, so this does not merely agree with itself.
        let eligibleNumbers = result["eligibleNumbers"] as? [String] ?? []
        let gutterNumbers = result["gutterNumbers"] as? [String] ?? []
        XCTAssertEqual(gutterNumbers, eligibleNumbers, "gutter numbers must match the eligible blocks in order")
        XCTAssertEqual(
            gutterNumbers,
            ["4", "6", "9", "13", "17"],
            "the heading, paragraph, code fence, citing paragraph and closing paragraph"
        )
        XCTAssertEqual(result["gutterCount"] as? Int, result["eligibleCount"] as? Int)

        // The hidden front-matter block is on line 1 and must not be numbered.
        XCTAssertFalse(gutterNumbers.contains("1"), "a hidden block must not be numbered")

        // Headings, paragraphs and code blocks all get their own number.
        XCTAssertTrue(gutterNumbers.contains("4"), "heading number missing")
        XCTAssertTrue(gutterNumbers.contains("6"), "paragraph number missing")
        XCTAssertTrue(gutterNumbers.contains("9"), "code block number missing")

        // The footnote and bibliography wrappers are structural, not document
        // lines: they carry no metadata and therefore get no number.
        XCTAssertEqual(boolValue(rendered["footnotesPresent"]), true, "fixture should render footnotes")
        XCTAssertFalse(boolValue(result["footnoteSectionNumbered"]), "footnotes wrapper must not be numbered")
        XCTAssertFalse(boolValue(result["bibliographySectionNumbered"]), "bibliography wrapper must not be numbered")

        // Footnote <li>s carry the attribute too, so a subtree query would number
        // them a second time. Selection must stay on <main>'s direct children.
        XCTAssertEqual(result["liNumbers"] as? Int, 0, "list items must not be numbered")

        XCTAssertTrue(boolValue(result["layerIsDirectChildOfMain"]))
        XCTAssertTrue(boolValue(result["layerIsLastChild"]), "the layer must sit after the content")
    }

    // MARK: - Live re-render and toggling

    @MainActor
    func testGutterSurvivesContentSwapAndToggling() throws {
        try skipUnlessGUITestsEnabled()

        let probe = """
        (function () {
          var main = document.querySelector('main');
          function numbers() {
            var spans = document.querySelectorAll('.md2-line-gutter span');
            var out = [];
            for (var i = 0; i < spans.length; i++) {
              out.push(spans[i].getAttribute('data-md2-gutter'));
            }
            return out;
          }
          // The rendered content, excluding the gutter layer: showing numbers must
          // never re-render or replace the document's blocks.
          function contentSignature() {
            var parts = [];
            for (var i = 0; i < main.children.length; i++) {
              var child = main.children[i];
              if (child.classList.contains('md2-line-gutter')) { continue; }
              parts.push(child.outerHTML);
            }
            return parts.join('');
          }

          var before = numbers();
          var signatureBefore = contentSignature();

          // Live swap (what __md2ApplyContent does to the gutter): new content
          // arrives, the layer is rebuilt against it.
          main.innerHTML = '<h2 data-md2-source-line="1">Replaced</h2>' +
                           '<p data-md2-source-line="3">Body</p>';
          window.__md2RenderLineNumbers();
          var afterSwap = numbers();

          // Toggling visibility must not touch the content at all.
          var signatureBeforeToggle = contentSignature();
          window.__md2SetLineNumbersVisible(false);
          var hiddenClass = document.documentElement.classList.contains('md2-line-numbers');
          var displayWhenOff = getComputedStyle(main.querySelector('.md2-line-gutter')).display;
          var signatureAfterHide = contentSignature();
          window.__md2SetLineNumbersVisible(true);
          var shownClass = document.documentElement.classList.contains('md2-line-numbers');
          var displayWhenOn = getComputedStyle(main.querySelector('.md2-line-gutter')).display;
          var signatureAfterShow = contentSignature();

          return {
            before: before,
            signatureUnchangedBySwap: signatureBefore === contentSignature(),
            afterSwap: afterSwap,
            hiddenClass: hiddenClass,
            shownClass: shownClass,
            displayWhenOff: displayWhenOff,
            displayWhenOn: displayWhenOn,
            signatureStableAcrossToggle: signatureBeforeToggle === signatureAfterHide &&
                                         signatureBeforeToggle === signatureAfterShow
          };
        })()
        """

        let result = try loadAndProbe(html: renderGutterPage(), probe: probe)

        let before = result["before"] as? [String] ?? []
        XCTAssertEqual(before.first, "4", "initial render should number the heading on line 4")

        // The swap replaced the document with two blocks on lines 1 and 3. The
        // old layer was destroyed with the old content; the rebuild must reflect
        // the new blocks only.
        XCTAssertEqual(result["afterSwap"] as? [String], ["1", "3"], "gutter must be rebuilt against swapped content")

        XCTAssertFalse(boolValue(result["hiddenClass"]), "toggling off must drop the switch class")
        XCTAssertTrue(boolValue(result["shownClass"]), "toggling on must restore the switch class")
        XCTAssertEqual(result["displayWhenOff"] as? String, "none", "the layer must not paint when numbers are off")
        XCTAssertEqual(result["displayWhenOn"] as? String, "block", "the layer must paint when numbers are on")
        XCTAssertTrue(boolValue(result["signatureStableAcrossToggle"]), "toggling must not change the rendered content")
    }

    // MARK: - Find and selection must not see the digits

    @MainActor
    func testGutterDigitsAreNotTextNodesOrFindable() throws {
        try skipUnlessGUITestsEnabled()

        // The preview's find walks `document.body` text nodes with these filter
        // rules (SCRIPT/STYLE/MARK rejected). The gutter must be invisible to it,
        // which it is by construction: the digits are CSS generated content, so
        // the layer holds no text nodes at all.
        let probe = """
        (function () {
          var layer = document.querySelector('.md2-line-gutter');
          var spans = layer ? layer.querySelectorAll('span') : [];
          var textNodes = 0;
          for (var i = 0; i < spans.length; i++) {
            for (var j = 0; j < spans[i].childNodes.length; j++) {
              if (spans[i].childNodes[j].nodeType === Node.TEXT_NODE) { textNodes += 1; }
            }
          }

          // A gutter-only number: the code block's line, which appears nowhere in
          // the document text.
          var query = '9';
          var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
            acceptNode: function (node) {
              if (!node.nodeValue) { return NodeFilter.FILTER_REJECT; }
              var p = node.parentNode;
              if (p && (p.tagName === 'SCRIPT' || p.tagName === 'STYLE' || p.tagName === 'MARK')) {
                return NodeFilter.FILTER_REJECT;
              }
              return node.nodeValue.toLowerCase().indexOf(query) >= 0
                ? NodeFilter.FILTER_ACCEPT
                : NodeFilter.FILTER_REJECT;
            }
          });
          var matches = [];
          var n;
          while ((n = walker.nextNode())) { matches.push(n.nodeValue); }

          return {
            spanCount: spans.length,
            textNodesInGutter: textNodes,
            layerTextContent: layer ? layer.textContent : null,
            gutterNumbers: (function () {
              var out = [];
              for (var k = 0; k < spans.length; k++) {
                out.push(spans[k].getAttribute('data-md2-gutter'));
              }
              return out;
            })(),
            findMatches: matches,
            selectedText: (function () {
              var range = document.createRange();
              range.selectNodeContents(layer);
              return range.toString();
            })()
          };
        })()
        """

        let result = try loadAndProbe(html: renderGutterPage(), probe: probe)

        XCTAssertGreaterThan(result["spanCount"] as? Int ?? 0, 0, "fixture should produce gutter entries")
        XCTAssertEqual(result["textNodesInGutter"] as? Int, 0, "gutter digits must not be text nodes")
        XCTAssertEqual(result["layerTextContent"] as? String, "", "the gutter layer must hold no text")
        XCTAssertEqual(result["findMatches"] as? [String], [], "find must not match a gutter-only number")
        XCTAssertEqual(result["selectedText"] as? String, "", "selecting the gutter must yield no text")
        XCTAssertTrue(
            (result["gutterNumbers"] as? [String] ?? []).contains("9"),
            "the queried number must actually exist in the gutter, or this proves nothing (got \(result["gutterNumbers"] ?? "nil"))"
        )
    }

    // MARK: - Width invariants

    @MainActor
    func testGutterWidthInvariants() throws {
        try skipUnlessGUITestsEnabled()

        let probe = """
        (function () {
          var main = document.querySelector('main');
          var html = document.documentElement;
          function padding() { return getComputedStyle(main).paddingLeft; }
          function basePaddingForWidth(w) {
            // The renderer's own rule: padded by clamp(28px, 4vw, 64px) above the
            // 720px breakpoint, 24px below it.
            return w <= 720 ? 24 : Math.min(64, Math.max(28, 0.04 * w));
          }

          window.__md2SetLineNumbersVisible(false);
          var paddingOff = padding();
          var maxWidthOff = getComputedStyle(main).maxWidth;
          var scrollWidthOff = html.scrollWidth;
          var clientWidth = html.clientWidth;

          window.__md2SetLineNumbersVisible(true);
          var paddingOn = padding();
          var maxWidthOn = getComputedStyle(main).maxWidth;
          var scrollWidthOn = html.scrollWidth;

          window.__md2SetLineNumbersVisible(false);
          var paddingRestored = padding();

          return {
            width: window.innerWidth,
            paddingOff: paddingOff,
            paddingOn: paddingOn,
            paddingRestored: paddingRestored,
            maxWidthOff: maxWidthOff,
            maxWidthOn: maxWidthOn,
            scrollWidthOff: scrollWidthOff,
            scrollWidthOn: scrollWidthOn,
            clientWidth: clientWidth,
            basePadding: basePaddingForWidth(window.innerWidth)
          };
        })()
        """

        // Narrow: below the 720px breakpoint, where the gutter has to reserve
        // space inside the column and must not introduce horizontal scrolling.
        let narrow = try loadAndProbe(html: renderGutterPage(), frameWidth: 480, probe: probe)
        let narrowPaddingOn = pixelValue(narrow["paddingOn"])
        XCTAssertGreaterThanOrEqual(narrowPaddingOn, 46, "narrow window must reserve the gutter")
        XCTAssertLessThanOrEqual(
            doubleValue(narrow["scrollWidthOn"]),
            doubleValue(narrow["clientWidth"]) + 1,
            "the gutter must not introduce horizontal page scrolling"
        )
        XCTAssertEqual(
            doubleValue(narrow["scrollWidthOn"]),
            doubleValue(narrow["scrollWidthOff"]),
            "horizontal extent must not change when numbers are turned on"
        )
        XCTAssertEqual(
            pixelValue(narrow["paddingRestored"]),
            pixelValue(narrow["paddingOff"]),
            "disabling must restore the base padding"
        )

        // Wide: past the point where the column's own padding already exceeds the
        // gutter, so nothing reflows at all.
        let wide = try loadAndProbe(html: renderGutterPage(), frameWidth: 1200, probe: probe)
        XCTAssertEqual(
            pixelValue(wide["paddingOff"]),
            pixelValue(wide["paddingOn"]),
            "a window wide enough for the gutter must not reflow the column"
        )
        XCTAssertEqual(
            wide["maxWidthOn"] as? String,
            wide["maxWidthOff"] as? String,
            "the column's max-width must be unchanged"
        )
        XCTAssertEqual(wide["maxWidthOn"] as? String, "1280px")
        XCTAssertLessThanOrEqual(
            doubleValue(wide["scrollWidthOn"]),
            doubleValue(wide["clientWidth"]) + 1,
            "no horizontal scrolling past the column cap"
        )
    }

    // MARK: - Fresh load

    @MainActor
    func testGutterShowsOnFreshLoadWhenPreferenceIsOn() throws {
        try skipUnlessGUITestsEnabled()

        let probe = """
        (function () {
          var spans = document.querySelectorAll('.md2-line-gutter span');
          return {
            count: spans.length,
            switchOn: document.documentElement.classList.contains('md2-line-numbers'),
            display: (function () {
              var layer = document.querySelector('.md2-line-gutter');
              return layer ? getComputedStyle(layer).display : 'absent';
            })(),
            firstNumber: spans.length > 0 ? spans[0].getAttribute('data-md2-gutter') : null
          };
        })()
        """

        // The script applies the preference as it loads: no explicit call here.
        let on = try loadAndProbe(html: renderGutterPage(), gutterEnabled: true, probe: probe)
        XCTAssertTrue(boolValue(on["switchOn"]), "loading with the preference on must switch the gutter on")
        XCTAssertEqual(on["display"] as? String, "block")
        XCTAssertGreaterThan(on["count"] as? Int ?? 0, 0, "numbers should be present at first paint")
        XCTAssertEqual(on["firstNumber"] as? String, "4")

        let off = try loadAndProbe(html: renderGutterPage(), gutterEnabled: false, probe: probe)
        XCTAssertFalse(boolValue(off["switchOn"]), "loading with the preference off must leave the gutter off")
        XCTAssertEqual(off["count"] as? Int, 0, "no numbers should be rendered when the preference is off")
        XCTAssertEqual(off["display"] as? String, "absent", "the gutter layer should not exist when numbers are off")
    }

    // MARK: - Export isolation

    /// Drives the real `PDFExporter` and checks the delivered pixels, not the DOM:
    /// the preview gutter must leave no trace in an exported PDF.
    ///
    /// Region-specific on purpose (never a global pixel count, which passes when
    /// the whole page is blank): the left page-margin band is sampled, since that
    /// is where a gutter painted outside the content column would land, while the
    /// content band is sampled separately to prove the page is not simply empty.
    @MainActor
    func testExportedPDFIsFreeOfGutterArtifacts() throws {
        try skipUnlessGUITestsEnabled()
        _ = NSApplication.shared

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("md2-line-numbers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var markdown = "# Heading\n\n"
        for i in 0..<40 { markdown += "Paragraph \(i): the quick brown fox jumps over the lazy dog.\n\n" }
        let rendered = MarkdownRenderer().render(markdown)

        // The HTML the app hands the exporter must be gutter-free — this is the
        // boundary that keeps numbers out of every export.
        XCTAssertFalse(rendered.html.contains("md2-line-gutter"))
        XCTAssertFalse(rendered.html.contains("md2-line-numbers"))
        XCTAssertFalse(rendered.html.contains("data-md2-gutter"))

        let destination = dir.appendingPathComponent("out.pdf")
        let exporter = PDFExporter(destinationURL: destination)
        let done = expectation(description: "export completes")
        var outcome: Result<Void, Error>?
        exporter.export(html: rendered.html, outline: rendered.outline, baseURL: dir) { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 35)

        guard case .success = outcome else {
            XCTFail("export failed: \(String(describing: outcome))")
            return
        }
        guard let bitmap = rasterizeFirstPage(of: destination, scale: 1.5) else {
            XCTFail("could not rasterize exported page 1")
            return
        }

        // The exported content begins at the profile's narrow margin — 36pt, which
        // is 54px at scale 1.5. Nothing may be painted to the left of it, which is
        // where a gutter drawn outside the content column would land.
        var leftmostDark = bitmap.pixelsWide
        var contentDark = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard isDark(bitmap.colorAt(x: x, y: y)) else { continue }
                contentDark += 1
                if x < leftmostDark { leftmostDark = x }
            }
        }

        // A blank page would satisfy the margin assertion vacuously.
        XCTAssertGreaterThan(contentDark, 50, "exported page 1 is blank; the margin check would be vacuous")
        XCTAssertGreaterThanOrEqual(
            leftmostDark,
            50,
            "exported PDF painted content left of the content margin (leftmost dark pixel at x=\(leftmostDark)); the preview gutter leaked into the export"
        )

        // The export must not have left the preview temp file behind either.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".md2-preview-") })
    }

    // MARK: - Harness

    private func skipUnlessGUITestsEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MD2_RUN_GUI_TESTS"] == "1",
            "Set MD2_RUN_GUI_TESTS=1 to run this WebKit-backed test."
        )
    }

    /// Loads `html` into an off-screen, window-hosted `WKWebView` with the real
    /// preview gutter script injected, then evaluates `probe` and returns its
    /// result. Mirrors the Mermaid offscreen harness, minus the diagram-settle
    /// poll (these fixtures contain no diagrams).
    @MainActor
    private func loadAndProbe(
        html: String,
        frameWidth: CGFloat = 900,
        gutterEnabled: Bool = true,
        probe: String
    ) throws -> [String: Any] {
        _ = NSApplication.shared

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // The preview script owns the front-matter hide rule too, and applies it
        // *before* the gutter renders (same order as the production script), so
        // the hidden front-matter block is skipped as a zero-rect block. The
        // fixture has front matter, so this ordering is what exercises that path.
        configuration.userContentController.addUserScript(WKUserScript(
            source: """
            (function () {
              var style = document.createElement('style');
              style.textContent = 'html.md2-hide-front-matter .front-matter{display:none!important;}';
              document.head.appendChild(style);
              document.documentElement.classList.add('md2-hide-front-matter');
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: MarkdownPreviewView.lineNumberGutterScript(showsLineNumbers: gutterEnabled),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        let frame = NSRect(x: 0, y: 0, width: frameWidth, height: 800)
        let webView = WKWebView(frame: frame, configuration: configuration)

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        let delegate = GutterNavigationDelegate()
        webView.navigationDelegate = delegate
        let loaded = expectation(description: "page load finished")
        delegate.onFinish = { loaded.fulfill() }
        webView.loadHTMLString(html, baseURL: nil)
        wait(for: [loaded], timeout: 15)

        // Let the injected script's first render (and any rAF-scheduled pass) run.
        let rendered = expectation(description: "gutter rendered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { rendered.fulfill() }
        wait(for: [rendered], timeout: 5)

        let probed = expectation(description: "probe evaluated")
        var output: [String: Any] = [:]
        webView.evaluateJavaScript(probe) { value, _ in
            output = (value as? [String: Any]) ?? [:]
            probed.fulfill()
        }
        wait(for: [probed], timeout: 5)
        return output
    }

    private func boolValue(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        return (value as? Bool) ?? false
    }

    private func isDark(_ color: NSColor?) -> Bool {
        guard let c = color?.usingColorSpace(.deviceRGB) else { return false }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: nil)
        return (r + g + b) / 3 < 0.5
    }

    /// Rasterize page 1 of the PDF at `url` (createPDF output, not the DOM).
    private func rasterizeFirstPage(of url: URL, scale: CGFloat) -> NSBitmapImageRep? {
        guard let pdfDoc = CGDataProvider(url: url as CFURL).flatMap(CGPDFDocument.init),
              let page = pdfDoc.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        let width = Int(box.width * scale), height = Int(box.height * scale)
        guard width > 0, height > 0,
              let ctx = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.drawPDFPage(page)
        guard let cgImage = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
    }

    private func doubleValue(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        return 0
    }

    /// `getComputedStyle` returns px strings; compare them as numbers.
    private func pixelValue(_ value: Any?) -> Double {
        guard let text = value as? String else { return -1 }
        return Double(text.replacingOccurrences(of: "px", with: "")) ?? -1
    }
}

private final class GutterNavigationDelegate: NSObject, WKNavigationDelegate {
    var onFinish: (() -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish?()
    }
}
