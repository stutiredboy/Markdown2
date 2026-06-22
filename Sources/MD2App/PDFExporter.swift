import AppKit
import CoreGraphics
import Foundation
import WebKit

/// Renders a document's preview HTML into a paginated PDF using a dedicated
/// offscreen `WKWebView`, independent of whether the live preview is mounted (it
/// is absent in Edit-only mode) or where it is scrolled. The web view loads the
/// same HTML the preview uses — written to a temporary file in the document
/// directory so relative image paths resolve under granted read access — waits
/// for asynchronous engines (KaTeX/diagrams) to settle, probes safe page breaks,
/// captures each page-height band via `createPDF`, then composes the bands into
/// print-ready pages.
///
/// `createPDF` + `PDFPaginator` is used instead of `NSPrintOperation`: printing
/// an offscreen web view produced structurally invalid, multi-gigabyte output
/// (millions of empty pages, no page-tree root).
@MainActor
final class PDFExporter: NSObject, WKNavigationDelegate {
    enum ExportError: LocalizedError {
        case timedOut
        case preparationFailed
        case renderFailed
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .timedOut:
                return "The document took too long to render."
            case .preparationFailed:
                return "The document could not be prepared for export."
            case .renderFailed:
                return "The document could not be rendered to PDF."
            case .writeFailed:
                return "The PDF could not be written."
            }
        }
    }

    /// Filename pieces for the temporary render file written alongside the
    /// document. Shares the preview's prefix/suffix so the preview's existing
    /// stale-file sweep also reclaims any leftover after a crash mid-export.
    private static let renderFilePrefix = ".md2-preview-"
    private static let renderFileSuffix = ".html"

    /// How long to wait after `didFinish` for async KaTeX/diagram rendering to
    /// settle before capturing the PDF. Matches the preview's reflow window.
    private static let settleDelay: TimeInterval = 2.5
    /// Overall guard so a page that never finishes loading cannot hang export.
    private static let overallTimeout: TimeInterval = 30

    /// Output page geometry: A4 with compact, document-like margins. The system
    /// default print margins are large (~1.5"), which — together with the
    /// preview's reading-oriented styles — wastes most of the page, so the
    /// exporter fixes its own print geometry instead.
    private let pageSize: CGSize
    private let margins: PDFPaginator.Margins

    /// A4 at 72 dpi (210mm × 297mm).
    static let a4PageSize = CGSize(width: 595.28, height: 841.89)
    /// Compact print margin on every side (~0.67").
    static let printMargin: CGFloat = 48
    /// Clearance kept below the last line on a page (~one print line at 14px ×
    /// 1.55). Page bands are capped at the printable height *minus* this cushion
    /// so a band never fills the page to the pixel; otherwise `createPDF` rounding
    /// at a maximal page could shave the bottom line's descenders.
    static let boundaryCushion: CGFloat = 22

    private let webView: WKWebView
    /// Hosts `webView` off-screen. A WKWebView with no window is treated as
    /// non-visible, so WebKit throttles it: the first load can stall and
    /// `createPDF` can capture nothing — which is why the first export of a new
    /// window produced no file while a retry (with WebKit warm) worked. A real
    /// window, parked far off-screen, makes WebKit lay it out and render.
    private let hostWindow: NSWindow
    private let destinationURL: URL
    private var temporaryHTMLURL: URL?
    private var completion: ((Result<Void, Error>) -> Void)?
    private var timeoutWorkItem: DispatchWorkItem?
    private var hasFinished = false

    /// The drawable area of a page, inside the margins.
    private var printableWidth: CGFloat { pageSize.width - margins.left - margins.right }
    private var printableHeight: CGFloat { pageSize.height - margins.top - margins.bottom }
    /// The maximum height of page *content*: the printable height minus the
    /// boundary cushion. Used for both the break-probe's "atomic block fits a
    /// page" threshold and the band height cap, so the two stay consistent.
    private var pageContentHeight: CGFloat { max(72, printableHeight - Self.boundaryCushion) }

    init(destinationURL: URL) {
        self.destinationURL = destinationURL

        // Fixed A4 print geometry (the user-facing default), not the system
        // paper size, so output is consistent regardless of the print locale.
        pageSize = Self.a4PageSize
        margins = PDFPaginator.Margins(uniform: Self.printMargin)
        // Lay out at the printable width so text renders at its native size; the
        // height is nominal since each band is captured from the full content.
        let layoutWidth = max(72, pageSize.width - margins.left - margins.right)

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // The rendered HTML is styled for on-screen reading (wide content
        // padding, a large base font). Override those with print-density styles
        // so each page holds a normal amount of text and the page margins — not
        // the content padding — provide the whitespace.
        let printStyle = WKUserScript(
            source: Self.printStyleScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(printStyle)

        let frame = NSRect(x: 0, y: 0, width: layoutWidth, height: pageSize.height)
        webView = WKWebView(frame: frame, configuration: configuration)

        hostWindow = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        hostWindow.isReleasedWhenClosed = false
        hostWindow.contentView = webView
        // Park the window far off every screen so it is never visible and never
        // steals key focus, while still counting as on-screen to WebKit.
        hostWindow.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))

        super.init()
        webView.navigationDelegate = self
        hostWindow.orderFrontRegardless()
    }

    /// Loads `html` (resolving relative resources under `baseURL`) and, once it
    /// settles, writes a paginated PDF to the destination, reporting the outcome
    /// on the main actor exactly once.
    func export(html: String, baseURL: URL?, completion: @escaping (Result<Void, Error>) -> Void) {
        self.completion = completion

        // Arm the overall timeout first so a load that never finishes still fails.
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.finish(.failure(ExportError.timedOut))
            }
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.overallTimeout, execute: timeout)

        guard let baseURL, baseURL.isFileURL else {
            webView.loadHTMLString(html, baseURL: baseURL)
            return
        }

        // `loadHTMLString` grants no file-system read access, so relative images
        // never load. Mirror the preview: write the HTML into the document
        // directory and load it via a file request that grants read access there.
        let renderURL = baseURL.appendingPathComponent(
            "\(Self.renderFilePrefix)\(UUID().uuidString)\(Self.renderFileSuffix)"
        )
        do {
            try html.write(to: renderURL, atomically: true, encoding: .utf8)
            temporaryHTMLURL = renderURL
            webView.loadFileRequest(URLRequest(url: renderURL), allowingReadAccessTo: baseURL)
        } catch {
            // A file-backed document may reference relative images that only
            // resolve via the granted read access of `loadFileRequest`. Falling
            // back to `loadHTMLString` would silently drop those images while
            // still reporting success, so treat the failure as an export failure.
            finish(.failure(ExportError.preparationFailed))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !hasFinished else { return }
        // Give async engines (KaTeX, Mermaid/flow/sequence) time to render before
        // capturing the PDF; there is no single completion signal to await.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            Task { @MainActor in
                self?.producePDF()
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(error))
    }

    private func producePDF() {
        guard !hasFinished else { return }

        // Ask the rendered page where it is safe to split (gaps between line
        // boxes and blocks) so pagination never slices a line across two pages,
        // then capture and paginate. Probe with the cushioned content height so an
        // atomic block is "kept whole" only when a band can actually hold it.
        webView.evaluateJavaScript(Self.breakProbeScript(maxAtomicHeight: pageContentHeight)) { [weak self] result, _ in
            Task { @MainActor in
                guard let self else { return }
                let payload = result as? [String: Any]
                let contentHeight = CGFloat((payload?["height"] as? NSNumber)?.doubleValue ?? 0)
                let breaks = (payload?["breaks"] as? [NSNumber])?.map { CGFloat($0.doubleValue) } ?? []
                self.capturePDF(breaks: breaks, contentHeight: contentHeight)
            }
        }
    }

    private func capturePDF(breaks: [CGFloat], contentHeight: CGFloat) {
        guard !hasFinished else { return }

        guard contentHeight > 0,
              pageContentHeight > 0,
              let bands = PDFPaginator.bands(
                sourceHeight: contentHeight,
                maxBand: pageContentHeight,
                cuts: breaks
              ) else {
            finish(.failure(ExportError.renderFailed))
            return
        }

        logPaginationDiagnostics(contentHeight: contentHeight, breaks: breaks, bands: bands)
        captureBands(bands, index: 0, pages: [])
    }

    private func captureBands(
        _ bands: [(top: CGFloat, height: CGFloat)],
        index: Int,
        pages: [Data]
    ) {
        guard !hasFinished else { return }
        guard index < bands.count else {
            guard let paginated = composePDF(from: pages) else {
                finish(.failure(ExportError.renderFailed))
                return
            }
            do {
                try paginated.write(to: destinationURL, options: .atomic)
                finish(.success(()))
            } catch {
                finish(.failure(ExportError.writeFailed))
            }
            return
        }

        let band = bands[index]
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(
            x: 0,
            y: band.top,
            width: webView.bounds.width,
            height: band.height
        )

        webView.createPDF(configuration: configuration) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case let .success(data):
                    self.captureBands(bands, index: index + 1, pages: pages + [data])
                case let .failure(error):
                    self.finish(.failure(error))
                }
            }
        }
    }

    private func composePDF(from pages: [Data]) -> Data? {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        guard printableWidth > 0, printableHeight > 0 else { return nil }
        let box = CGSize(width: printableWidth, height: printableHeight)

        for data in pages {
            guard let provider = CGDataProvider(data: data as CFData),
                  let document = CGPDFDocument(provider),
                  let page = document.page(at: 1) else {
                return nil
            }

            let sourceRect = page.getBoxRect(.mediaBox)
            guard sourceRect.width > 0, sourceRect.height > 0 else { return nil }
            // Fit the captured band to the printable box: scale 1 for a normal band
            // (its width already equals the printable width and, with the cushion,
            // its height is below the printable height); only a single atomic block
            // taller than a page scales down to fit height. No clamp slices content.
            let scale = PDFPaginator.fitScale(source: sourceRect.size, into: box)
            let drawnWidth = sourceRect.width * scale
            let drawnHeight = sourceRect.height * scale
            // Top-align inside the printable area (CG origin is bottom-left).
            let originX = margins.left
            let originY = margins.bottom + printableHeight - drawnHeight

            context.beginPDFPage(nil)
            context.saveGState()
            context.clip(to: CGRect(x: originX, y: originY, width: drawnWidth, height: drawnHeight))
            context.translateBy(x: originX, y: originY)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -sourceRect.minX, y: -sourceRect.minY)
            context.drawPDFPage(page)
            context.restoreGState()
            context.endPDFPage()
        }

        context.closePDF()
        return output as Data
    }

    private func logPaginationDiagnostics(
        contentHeight: CGFloat,
        breaks: [CGFloat],
        bands: [(top: CGFloat, height: CGFloat)]
    ) {
        guard ProcessInfo.processInfo.environment["MD2_DEBUG_PDF_BREAKS"] == "1" else { return }
        print(
            "PDF-BREAKS contentHeight=\(contentHeight) breaks=\(breaks.count) " +
            "bands=\(bands.count) firstBands=\(bands.prefix(8))"
        )
    }

    /// Print-density overrides injected before capture. The preview styles target
    /// on-screen reading: a centered 860px column with ~58px side padding and a
    /// 16px/1.68 base font. For print that doubles the page margin and wastes the
    /// page, so neutralize the content padding/width (the PDF page margin supplies
    /// the whitespace) and tighten the base font. Headings use `rem`, so scaling
    /// the root font scales them too.
    ///
    /// Crucially, the preview lets wide blocks scroll horizontally
    /// (`table`/`pre` are `overflow-x: auto`), but a PDF page has no scrollbar —
    /// anything past the layout width would be clipped and lost. So the overrides
    /// also force every block that can exceed the printable width to *wrap* within
    /// it: tables become fixed-layout with wrapping cells, code wraps onto the next
    /// line, long inline tokens break, and media/diagrams/math scale to 100% width.
    /// With unbreakable tokens broken (`overflow-wrap: anywhere`), nothing exceeds
    /// the layout width, so the capture maps 1:1 with no horizontal clipping.
    private static let printStyleScript = """
    (function () {
      if (!document.head) { return; }
      var style = document.createElement('style');
      style.id = 'md2-print-overrides';
      style.textContent =
        'html { font-size: 14px; }' +
        'body { font-size: 14px; line-height: 1.55; }' +
        'main { max-width: none !important; width: 100% !important;' +
        ' margin: 0 !important; padding: 0 !important; }' +
        'table { display: table !important; table-layout: fixed;' +
        ' width: 100% !important; overflow-x: visible !important; }' +
        'th, td { word-break: break-word; overflow-wrap: anywhere;' +
        ' white-space: normal; }' +
        'pre { overflow-x: visible !important; }' +
        'pre code { white-space: pre-wrap !important; overflow-wrap: anywhere;' +
        ' word-break: break-word; }' +
        'code { overflow-wrap: anywhere; word-break: break-word; }' +
        'svg, canvas, img { max-width: 100% !important; height: auto; }' +
        '.math-display { overflow: visible !important; }';
      document.head.appendChild(style);
    })();
    """

    /// Collects safe page-break offsets (document Y, in CSS pixels from the top)
    /// from the rendered page. Breaking *between* text lines is safe, so adjacent
    /// line boxes contribute the midpoint of their gap as a split candidate — this
    /// keeps page edges clear of glyph antialiasing while staying dense regardless
    /// of line spacing.
    /// Atomic blocks (code, images, diagrams, math, rules, and tables that fit on
    /// a page) must not be split, so any candidate landing inside one is dropped.
    /// Tables taller than a page are split at row edges instead: each row that
    /// fits on a page is atomic, while the table as a whole is allowed to span
    /// pages. `PDFPaginator.bands` then ends each page at the largest offset that
    /// fits, so a line, row, or atomic block is never sliced across a page
    /// boundary unless it is itself taller than a page.
    private static func breakProbeScript(maxAtomicHeight: CGFloat) -> String {
        """
    (function () {
      try {
        var body = document.body;
        if (!body) { return { height: 0, breaks: [] }; }

        // Some blocks cannot wrap to fit the page width — display math is a single
        // unbreakable KaTeX box, and a diagram is one SVG. Scale any that still
        // overflow their available width down to fit (transform-origin top-left,
        // reserving the scaled height) so wide math/diagrams are never clipped.
        var fitTargets = body.querySelectorAll('.math-display, .diagram');
        for (var fi = 0; fi < fitTargets.length; fi++) {
          var fel = fitTargets[fi];
          var avail = fel.clientWidth;
          if (avail > 0 && fel.scrollWidth > avail + 1) {
            var inner = fel.firstElementChild;
            if (inner) {
              var fs = avail / fel.scrollWidth;
              inner.style.transformOrigin = 'left top';
              inner.style.transform = 'scale(' + fs + ')';
              fel.style.height = (inner.offsetHeight * fs) + 'px';
              fel.style.overflow = 'hidden';
            }
          }
        }

        var scrollY = window.scrollY || 0;
        var height = Math.max(document.documentElement.scrollHeight, body.scrollHeight);
        var cushion = 4;
        var maxAtomicHeight = \(Double(maxAtomicHeight));

        function valid(y) { return typeof y === 'number' && isFinite(y); }
        function rectFor(el) {
          var r = el.getBoundingClientRect();
          if (r.height <= 0 && r.width <= 0) { return null; }
          return { top: r.top + scrollY, bottom: r.bottom + scrollY, height: r.height };
        }
        function fitsOnPage(r) { return r.height <= maxAtomicHeight - cushion; }

        // Blocks that must stay whole — collect their vertical spans. Do not
        // merge adjacent table rows: their shared edge is a valid page break.
        var spans = [];
        var rawBreaks = [];
        function addSpan(r) { spans.push({ top: r.top, bottom: r.bottom }); }
        function addRawBreak(y) { if (valid(y) && y > 0 && y < height) { rawBreaks.push(y); } }

        var tables = body.querySelectorAll('table');
        for (var t = 0; t < tables.length; t++) {
          var tr = rectFor(tables[t]);
          if (!tr) { continue; }
          addRawBreak(tr.top);
          addRawBreak(tr.bottom);
          if (fitsOnPage(tr)) {
            addSpan(tr);
            continue;
          }

          var rows = tables[t].querySelectorAll('tr');
          for (var ri = 0; ri < rows.length; ri++) {
            var rr = rectFor(rows[ri]);
            if (!rr) { continue; }
            addRawBreak(rr.top);
            addRawBreak(rr.bottom);
            if (fitsOnPage(rr)) { addSpan(rr); }
          }
        }

        var atomicEls = body.querySelectorAll('pre,img,svg,canvas,figure,hr,.math-display,.diagram');
        for (var a = 0; a < atomicEls.length; a++) {
          var ar = rectFor(atomicEls[a]);
          if (!ar) { continue; }
          addRawBreak(ar.top);
          addRawBreak(ar.bottom);
          if (fitsOnPage(ar)) { addSpan(ar); }
        }
        spans.sort(function (p, q) { return p.top - q.top; });
        function insideAtomic(y) {
          for (var i = 0; i < spans.length; i++) {
            if (spans[i].top - y > cushion) { break; }
            if (y > spans[i].top + cushion && y < spans[i].bottom - cushion) { return true; }
          }
          return false;
        }

        var breakCandidates = [];
        function addBreak(y) {
          if (!valid(y) || y <= 0 || y >= height) { return; }
          if (insideAtomic(y)) { return; }
          breakCandidates.push(y);
        }

        for (var rb = 0; rb < rawBreaks.length; rb++) { addBreak(rawBreaks[rb]); }

        // Between text lines: collect line boxes first, then place breaks in the
        // middle of the gap between adjacent lines. Using the exact top/bottom edge
        // of a line is too tight for WebKit PDF capture and can leave a clipped
        // antialiased sliver of the next line on the previous page.
        var lineSpans = [];
        var walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT, null);
        var node;
        while ((node = walker.nextNode())) {
          if (!node.nodeValue || !node.nodeValue.trim()) { continue; }
          var parent = node.parentNode;
          if (parent && (parent.tagName === 'SCRIPT' || parent.tagName === 'STYLE')) { continue; }
          var range = document.createRange();
          range.selectNodeContents(node);
          var rects = range.getClientRects();
          for (var i = 0; i < rects.length; i++) {
            var top = rects[i].top + scrollY;
            var bottom = rects[i].bottom + scrollY;
            if (valid(top) && valid(bottom) && bottom > top) {
              lineSpans.push({ top: top, bottom: bottom });
            }
          }
        }

        lineSpans.sort(function (p, q) { return p.top - q.top || p.bottom - q.bottom; });
        var lines = [];
        for (var li = 0; li < lineSpans.length; li++) {
          var span = lineSpans[li];
          var current = lines[lines.length - 1];
          if (current && span.top <= current.bottom + 0.5) {
            current.top = Math.min(current.top, span.top);
            current.bottom = Math.max(current.bottom, span.bottom);
          } else {
            lines.push({ top: span.top, bottom: span.bottom });
          }
        }
        for (var lj = 0; lj < lines.length - 1; lj++) {
          var gap = lines[lj + 1].top - lines[lj].bottom;
          if (gap > 0.5) {
            addBreak(lines[lj].bottom + gap / 2);
          }
        }

        // Paragraph / list / heading boundaries are also safe.
        var blocks = body.querySelectorAll('p,li,h1,h2,h3,h4,h5,h6,blockquote,ul,ol,dl,section');
        for (var b = 0; b < blocks.length; b++) {
          var br = blocks[b].getBoundingClientRect();
          if (br.height <= 0 && br.width <= 0) { continue; }
          addBreak(br.top + scrollY);
          addBreak(br.bottom + scrollY);
        }

        breakCandidates.sort(function (x, y) { return x - y; });
        var breaks = [];
        for (var bi = 0; bi < breakCandidates.length; bi++) {
          var y = breakCandidates[bi];
          if (!breaks.length || y - breaks[breaks.length - 1] > 0.25) {
            breaks.push(y);
          }
        }
        return { height: height, breaks: breaks };
      } catch (e) {
        return { height: 0, breaks: [] };
      }
    })();
    """
    }

    /// Reports the outcome once and cleans up the temporary render file. Repeat
    /// calls (e.g. a timeout firing after success) are ignored.
    private func finish(_ result: Result<Void, Error>) {
        guard !hasFinished else { return }
        hasFinished = true

        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil

        if let temporaryHTMLURL {
            try? FileManager.default.removeItem(at: temporaryHTMLURL)
            self.temporaryHTMLURL = nil
        }

        hostWindow.orderOut(nil)

        let completion = self.completion
        self.completion = nil
        completion?(result)
    }
}

extension PDFExporter: PDFExporting {}
