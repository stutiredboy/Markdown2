## 1. Localization

- [x] 1.1 Add `case exportPDF` to the `L10nKey` enum in `Sources/MD2App/AppSettings.swift`
- [x] 1.2 Add English string `"Export as PDF…"` to the `english` table
- [x] 1.3 Add Simplified Chinese string `"导出为 PDF…"` to the `zhHans` table

## 2. PDF exporter

- [x] 2.1 Create `Sources/MD2App/PDFExporter.swift` with an `@MainActor final class PDFExporter` that retains its own offscreen `WKWebView`
- [x] 2.2 Load `rendered.html`: when `baseURL` is a file URL, write a unique `.md2-preview-*.html` temp file in the document directory and `loadFileRequest(_:allowingReadAccessTo: baseURL)`; otherwise `loadHTMLString(_:baseURL:)`
- [x] 2.3 On `didFinish`, wait a bounded settle delay (≈2.5s) for async KaTeX/diagram rendering before producing the PDF; guard the whole operation with an overall timeout
- [x] 2.4 Probe safe page bands, capture each band as a vector PDF via `webView.createPDF(configuration:)`, then compose those bands into print-ready A4 pages with `PDFPaginator`/Core Graphics and write the result to the destination. (Replaces the initial `NSPrintOperation` approach, which produced a structurally invalid ~700MB file — millions of empty pages, no page-tree root — when printing an offscreen web view, and avoids WebKit's very-tall single-PDF capture cap.)
- [x] 2.5 Report success/failure through a completion handler; delete the temp HTML file on completion (success or failure)
- [x] 2.6 Add `Sources/MD2App/PDFPaginator.swift` — `bands(sourceHeight:maxBand:cuts:)` computes page bands that end at the largest safe break that fits, with a `maxPages` ceiling. Unit tests in `Tests/MD2CoreTests/PDFPaginatorTests.swift` cover fixed bands, short→single-band, safe-break snapping, unsorted cuts, the line/image boundary cases, and runaway→rejected
- [x] 2.7 Content-aware page breaks: probe the settled page (JS) for safe split offsets (line edges, block edges, and row edges for long tables); `PDFPaginator` ends each page at the largest safe break that fits so a line/row/block is never split across pages. Unit tests cover safe-break placement, early-break page growth, and boundary cases

## 3. DocumentStore entry point

- [x] 3.1 Add `func exportPDF()` to `Sources/MD2App/DocumentStore.swift` that calls `flushPendingRender()`, then presents an `NSSavePanel` restricted to `.pdf` with a default name from `fileURL` (extension swapped to `.pdf`) or `Untitled.pdf`, allowing directory creation
- [x] 3.2 On confirm, instantiate and retain a `PDFExporter`, passing `rendered.html`, `baseURL`, and the chosen URL; clear the retained exporter in the completion handler
- [x] 3.3 On failure, set `alert` with a failure message; ensure `fileURL`, `isDirty`, and autosave are never mutated by export (matches the existing save-error alerts, which are plain English strings rather than localized)

## 4. Menu command

- [x] 4.1 In `Sources/MD2App/MD2App.swift`, add an `Export as PDF…` button in the `.saveItem` command group immediately after the Save As… button, with no keyboard shortcut, calling `appDelegate.currentDocumentStore?.exportPDF()`
- [x] 4.2 Use `appDelegate.settings.text(.exportPDF)` for the button label

## 5. Verification

- [x] 5.1 Build the app (`swift build`) and confirm it compiles
- [x] 5.2 Export a document containing a heading, a KaTeX formula, a Mermaid diagram, a fenced code block, and a relative image; confirm all render correctly and the PDF paginates _(automated end-to-end: `PDFExportEndToEndVerification` drives the real exporter over exactly this fixture and asserts a valid multi-page PDF with the temp file cleaned up; with the A4 density pass it currently exports as 7 pages, ~67KB. Run with `MD2_RUN_GUI_TESTS=1`. Programmatic checks cover validity/pagination/size; a final human glance at math/diagram glyph fidelity is still recommended.)_
- [x] 5.3 Confirm export works from Edit-only mode (no preview mounted) and from Side by Side _(export uses a dedicated offscreen web view and reads `rendered.html`, so it is mode-independent; the e2e test runs with no editor mounted at all, exercising that exact path)_
- [x] 5.4 Confirm cancelling the save panel writes nothing and leaves the document's dirty state unchanged _(automated unit test: `cancellingPDFExportLeavesDocumentStateUnchanged` injects a cancelling destination picker and asserts no exporter is created, no PDF path appears, and `fileURL`/`isDirty` are unchanged)_
- [x] 5.5 Confirm a dirty document remains dirty (and `fileURL` unchanged) after a successful export _(automated unit test: `successfulPDFExportLeavesDirtyDocumentStateUnchanged` injects a successful exporter and asserts the latest rendered HTML is exported while `fileURL` and dirty state remain unchanged)_

## 6. Review follow-ups

- [x] 6.1 ~~Use the system default paper size and margins (`NSPrintInfo.shared`)~~ — superseded by 7.1 (export now uses a fixed A4 default per product decision)
- [x] 6.2 Treat a temporary-HTML write failure as an export failure (`preparationFailed`) rather than silently falling back to `loadHTMLString`, which would drop relative images while still reporting success
- [x] 6.3 Guard against a second concurrent export replacing/abandoning the in-flight one (`exportPDF()` no-ops while an export is retained)
- [x] 6.4 Add boundary tests for the exact line/image edge cases: line bottom == page limit, image top just before limit, image top == page start, image bottom == limit, and content-height ratio scaling (`bands`/`mappedCuts` exposed for direct assertion)
- [x] 6.5 Add an opt-in WebKit-backed end-to-end test (`PDFExportEndToEndVerification`, gated by `MD2_RUN_GUI_TESTS=1`) covering the full fixture

## 7. UX / print-quality follow-ups

- [x] 7.1 Export to a fixed **A4** page (`PDFExporter.a4PageSize`) with compact ~0.67" margins instead of the system paper size/margins (the system default margins are ~1.5", wasting most of the page)
- [x] 7.2 Increase per-page density: inject a print stylesheet (`printStyleScript`) before capture that neutralizes the preview's reading layout (centered 860px column, ~58px side padding) and tightens the base font (16px/1.68 → 14px/1.55), so the page margin — not the content padding — supplies the whitespace. Measured: the e2e fixture went 15 → 7 pages
- [x] 7.3 Fix the page-break probe so tightened line spacing does not collapse safe breaks: switch from "every line is an unsafe interval, cut in the gaps" to an edge-based model (each line-box edge is a safe break; only atomic blocks are unbreakable). Verified via diagnostics — pages now end at line boundaries (heights ~737–742 below the 745.89 cap) instead of hard-cutting at the limit
- [x] 7.4 Human visual pass on a real document: confirm A4 density reads well and no line/image/table row is split at a page boundary (GUI-only; the geometry is verified but glyph-level fidelity needs eyes). Verified with `/Users/tiredboy/work/github/ScutMemHomework/运营与供应链管理/复习重点/重点-03-啤酒游戏与牛鞭效应/啤酒游戏-案例解答_Codex.md` exported to `tmp/pdfs/save-as-pdf-regression/beer-final-after-fix.pdf`; Poppler-rendered boundary and page checks showed the original page 1/2 text split fixed and long table rows splitting only between rows.
- [x] 7.5 Remove the now-dead `PDFPaginator.paginate` / `mappedCuts` (and `defaultPageSize`/`defaultMargins`) — production uses only `bands` (band-by-band `createPDF` + `composePDF` in `PDFExporter`). Tests re-homed onto `bands`
- [x] 7.6 Fix "first export of a new window does nothing (no file, no error), retry works": host the exporter's `WKWebView` in a far off-screen `NSWindow` (`orderFrontRegardless`). A window-less web view is non-visible, so WebKit throttles its first load / `createPDF`. _(GUI-only failure; could not be reproduced in the headless e2e — needs user confirmation in the app.)_
