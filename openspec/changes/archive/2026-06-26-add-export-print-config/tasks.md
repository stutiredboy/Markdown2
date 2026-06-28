## 1. Fix offscreen diagram rendering (prerequisite)

- [x] 1.1 Reproduce the blank-Mermaid defect: export a document with a Mermaid diagram and confirm the `.diagram` box is blank in the PDF while preview renders it — captured as a regression test (`MermaidOffscreenRenderingTests`) that asserts the offscreen `.diagram-mermaid` renders an `<svg>` (fails on pre-change code)
- [x] 1.2 Extend `diagramBootstrap` (`MarkdownRenderer.swift`) so `__md2RenderDiagrams` tracks outstanding renders and signals completion (e.g. set `window.__md2DiagramsSettled = true` / expose a count) once every diagram has rendered or fallen back
- [x] 1.3 In `PDFExporter.webView(_:didFinish:)`, replace the fixed `settleDelay` with a bounded wait (poll via `evaluateJavaScript`) on the settle signal, capped by `overallTimeout`; capture pages only once settled
- [x] 1.4 Confirm the engine path (Mermaid `render` executes offscreen; drive it so it does not depend on a throttled animation frame); keep the per-diagram source fallback so a failing diagram never blanks or fails export
- [x] 1.5 Verify exported and printed PDFs show Mermaid (and flow/sequence) diagrams matching the preview, including a malformed-diagram fallback case — verified via `MermaidOffscreenRenderingTests` (renders to `<svg>`; malformed diagram still settles with source fallback) and the existing `PDFExportEndToEndVerification` (Mermaid-bearing export completes in ~0.6s, i.e. via the success path, not the settle timeout)

## 2. Export profile model (pure, in MD2Core)

- [x] 2.1 Add `PageSize` (incl. A4, Letter; → point dimensions at 72dpi) and `PageOrientation` enums
- [x] 2.2 Add `PageMargins` with presets (Normal, Narrow, Wide, None) and a `custom` per-side case; resolve to points
- [x] 2.3 Add `HeaderFooter` config (enabled, left/center/right templates, page-number toggle/format, font size) and a pure token resolver for `title`/`date`/`page`/`pageCount`
- [x] 2.4 Add `ExportProfile` aggregating the above; make it `Codable`/`Equatable` with a `.default` equal to today's output (A4 portrait, narrow, no numbers/headers)
- [x] 2.5 Unit-test geometry resolution (size × orientation → page rect; margins → printable area) and token substitution

## 3. Parameterize PDF export geometry

- [x] 3.1 Change `PDFExporter.init` to take an `ExportProfile` (or geometry derived from it) instead of the fixed `a4PageSize`/`printMargin`; derive `pageSize`, `margins`, `printableWidth/Height`, and the webview layout width from it
- [x] 3.2 Update `PDFPaginator` usage so band/printable math follows the configured geometry (keep `boundaryCushion` behavior) — `PDFPaginator.Margins` now built from `profile.marginInsets`; `boundaryCushion`/`pageContentHeight` unchanged; verified Letter-landscape yields 792×612 pages (`testExportHonorsConfiguredPageSizeAndOrientation`)
- [x] 3.3 Update the `PDFExporting` protocol, `DocumentStore.pdfExporterFactory`, `DocumentPrinter.exporterFactory`, and `DocumentPrinting` to thread the `ExportProfile` through (export profile passed at exporter construction; `DocumentPrinting.print` gains `profile:`; `DocumentStore.exportProfileProvider` injects it, defaulting to `.default`)
- [x] 3.4 Confirm the default profile reproduces the previous A4/narrow output byte-for-content-equivalent (existing export tests still pass) — default-profile E2E export unchanged at 13 pages / 83143 bytes

## 4. Page numbers, headers, and footers

- [x] 4.1 In `composePDF`, reserve a header/footer text band inside the page margin when enabled (enforce a minimum band even for the `none` margin preset) and feed the adjusted printable height into pagination so content is never clipped — `contentTopInset`/`contentBottomInset` reserve `runningTextBandHeight` per active edge; `printableHeight`/`pageContentHeight` derive from them; the outline destination-Y now uses `contentTopInset`
- [x] 4.2 Draw left/center/right header and footer text with Core Text, resolving `page`/`pageCount`/`title`/`date` per page — `drawRunningText`/`drawRunningLine`/`drawZoneText` via `CTLineDraw`; `{title}` plumbed through `export`/`print` as `documentTitle`; `{date}` is locale-aware
- [x] 4.3 Draw page numbers in the configured position/format when enabled — `showsPageNumbers` fills its `pageNumberAlignment` footer zone with `page / pageCount`
- [x] 4.4 Verify page numbers/headers/footers appear on every page, never overlap content, and are absent under the default profile — `PDFRunningTextTests.testExportDrawsPageNumbersHeaderAndFooterOnEveryPage` (extracted PDF text); default absence covered by `ExportProfileTests` (`hasRunningText == false`) and the unchanged default E2E
- [x] 4.5 Verify headers/footers enabled with the `none` margin preset still reserve a minimum text band and content is not clipped — `PDFRunningTextTests.testNoneMarginWithRunningTextReservesBandAndDoesNotClip` (page count not reduced; first/last paragraph still present)

## 5. Configuration center: persistence + Settings UI + menu

- [x] 5.1 Persist the `ExportProfile` in `AppSettings` under new `MD2.Export*` `UserDefaults` keys, following the existing `didSet` pattern; default to `.default` — stored as a JSON blob under `MD2.ExportProfile`
- [x] 5.2 Add localized `L10nKey`s (EN + zh-Hans) for the export section labels/help text
- [x] 5.3 Add an "Export" section to `SettingsView` for page size, orientation, margins (presets + custom), page numbers, and header/footer configuration — `ExportSettingsSection` with a margin preset/custom picker (4 inset fields) and per-zone header/footer text fields
- [x] 5.4 Make `DocumentStore.exportPDF()` and `print()` read the active profile and pass it to the exporter/printer factories — `MD2AppDelegate.makeDocumentStore()` injects `exportProfileProvider: { settings.exportProfile }`
- [x] 5.5 In `DocumentPrinter.runPrintOperation`, set the `NSPrintInfo` (a copy of `.shared`) to match the profile's page size and orientation before running the print operation, so the dialog opens pre-configured — `DocumentPrinter.makePrintInfo(for:)`, unit-tested portrait + landscape
- [x] 5.6 Extend `isProducingDerivedArtifact` to cover HTML export and DOCX/EPUB conversion (all export types mutually exclusive) — guard now includes `documentConverter`; HTML is synchronous so its start-guard suffices; mutual exclusion verified by `conversionInFlightBlocksOtherExports`
- [x] 5.7 Verify the profile persists across launches and that Print and PDF export produce consistent geometry/numbers/headers, and that the print dialog opens with the correct paper size — `ExportConfigurationTests` (persistence across instances; export + print both apply the provider's profile; `makePrintInfo` paper size/orientation)

## 6. Self-contained HTML export

- [x] 6.1 Add a pure `SelfContainedHTMLBuilder` (MD2Core) that inlines local relative/absolute images as `data:` URIs (reuse `LocalImageHTMLRewriter` path resolution) and leaves remote URLs as-is — placed in `MD2App` alongside `LocalImageHTMLRewriter` (cohesive, equally testable; design Decision 6 corrected); also resolves *relative* paths against `baseURL`
- [x] 6.2 Add `DocumentStore.exportHTML()` mirroring `exportPDF()` (flush render → `NSSavePanel` for `.html` → write), guarded by `isProducingDerivedArtifact` semantics and not touching `fileURL`/dirty/autosave; handle write failure with a localized alert — HTML export is synchronous, so the start-guard alone gives mutual exclusion
- [x] 6.3 Handle untitled documents: when no `baseURL` exists, skip image inlining (leave references as-is) rather than failing the export
- [x] 6.4 Add a localized "Export as HTML…" menu item in `MD2App.swift` (EN/zh-Hans `exportHTML` key)
- [x] 6.5 Unit-test image inlining; verify the exported file opens offline with working math and diagrams; verify an untitled document with image references exports without failing — `SelfContainedHTMLExportTests` (8 tests: relative/absolute inlining, remote/data-URI/missing left as-is, integration asserts embedded `__md2RenderMath`/`__md2RenderDiagrams` + inlined image + untouched doc state, untitled export succeeds)

## 7. Optional DOCX/EPUB via Pandoc

- [x] 7.1 Add a `PandocConverter` helper that detects a `pandoc` binary (PATH + common install locations) and exposes availability; detection runs on demand (when the menu is about to open or the command is invoked), cached briefly (~60s), not solely at launch — `pandocURL(forceRefresh:)` caches 60s; `MD2AppDelegate.applicationDidBecomeActive` force-refreshes so installing Pandoc while running enables the commands
- [x] 7.2 Implement conversion via `Process`: write the document's current in-memory Markdown (incl. unsaved edits) to a temp `.md` in the document directory, run Pandoc, write the chosen `.docx`/`.epub`, then delete the temp; bound with a 60s timeout, terminate on expiry, delete any partial output — uses the canonical `gfm` reader on Pandoc 2.0+ with a `markdown_github` fallback on older 1.x builds (selected from `pandoc --version`), and the document directory as the process working directory (cross-version: `--resource-path` is Pandoc 2.0+); writer inferred from extension
- [x] 7.3 Handle untitled documents: prompt to save before conversion (reusing the save-before-attachment pattern); abort cleanly if the user cancels — verified by `exportDOCXAbortsWhenUntitledSaveCancelled`
- [x] 7.4 Add `DocumentStore.exportDOCX()`/`exportEPUB()` as derived artifacts (no `fileURL`/dirty/autosave changes), guarded by `isProducingDerivedArtifact`, with localized failure/guidance alerts — injected behind `DocumentConverting` + availability provider + destination picker for testability
- [x] 7.5 Add localized "Export as DOCX…/EPUB…" menu items, enabled only when Pandoc is detected — implemented, then **deferred from the menu per user feedback** (DOCX/EPUB are non-rigid; not surfaced for now). The backend (`PandocConverter`, `DocumentStore.exportDOCX/exportEPUB`, tests) is retained and dormant; the `pandocAvailable` delegate plumbing was removed since no UI reads it. Re-exposing later is just adding the two menu items back. See Post-review adjustments.
- [x] 7.6 Verify enabled-with-Pandoc and disabled-without-Pandoc states, successful DOCX/EPUB output with relative images, untitled-document save flow, clear guidance on missing/failed/timeout Pandoc, and that no partial file survives a failure — `PandocConverterTests` (real DOCX is a valid zip; relative image lands in `word/media/`; failed write leaves no partial) + `DocumentConversionFlowTests` (guidance when unavailable, untitled-save-cancel abort, current-text conversion, failure alert, mutual exclusion)

## 8. Docs and verification

- [x] 8.1 Update `README.md` / `README.zh-CN.md` to document export presets, page numbers/headers/footers, HTML export, and the optional Pandoc DOCX/EPUB path
- [x] 8.2 Run the full test suite and a manual export/print pass across A4/Letter, portrait/landscape, with and without page numbers/headers, the `none` margin + headers edge case, a diagram-bearing document, an untitled document (HTML + DOCX/EPUB), and the print dialog paper-size sync — full suite green (228 Swift-Testing + all XCTest GUI suites with `MD2_RUN_GUI_TESTS=1`); the matrix is covered by automated GUI tests (size/orientation, running text, `none`+headers, Mermaid offscreen, untitled HTML, real DOCX/EPUB, `makePrintInfo`). The two inherently-interactive checks — the print panel's visual appearance and opening the exported HTML in a real browser — are recommended manual spot-checks (verified here via structural proxies: `makePrintInfo` paper/orientation; embedded engines + inlined images in the HTML)

## Post-review adjustments (user feedback during apply)

- [x] R.1 **Fix: configured page numbers / headers / footers were missing in exported PDFs.** The file-open path (`MD2AppDelegate.openInNewWindow`) created a `DocumentStore()` with the default export profile instead of the settings-backed one, so any document opened from a file ignored the configured profile (only brand-new blank documents were wired). Both creation sites now use `makeDocumentStore()`, which injects `exportProfileProvider: { settings.exportProfile }`.
- [x] R.2 **Behavior: page numbers now combine with footer text in the same zone instead of replacing it.** When page numbers and footer text both target the same zone (e.g. footer center `{title}` + page-number alignment center), the page number is appended after the footer text rather than overwriting it, so enabling page numbers never hides a configured entry. Verified by `PDFRunningTextTests.testPageNumberAndFooterTextShareZoneWithoutHidingEachOther`.
- [x] R.3 **Menu: export is now an "Export To" submenu with PDF and HTML only.** Replaces the flat Export-as-* buttons with `Menu("Export To") { PDF; HTML }` (localized EN/zh-Hans `exportTo`). DOCX/EPUB are intentionally omitted from the menu for now (R.4).
- [x] R.4 **DOCX/EPUB descoped from the UI (non-rigid requirement).** The `document-conversion` capability remains fully implemented and tested but is not surfaced in the menu at this stage; the `document-conversion` spec describes the target behavior for when it is re-exposed.
- [x] R.5 **Fix: Pandoc reader format is now version-aware (`gfm` on 2.0+).** Replaced the unconditional deprecated `markdown_github` with `gfm` on Pandoc 2.0+, falling back to `markdown_github` only on older 1.x builds (selected from `pandoc --version`, cached). Pure parse/mapping helpers are unit-tested (`PandocReaderFormatTests`); the real-conversion tests still pass against the local 1.x build via the fallback.
- [x] R.6 **Evaluated: `ExportProfile`/`SelfContainedHTMLBuilder` module placement (review deviation #4) — decided to keep in `MD2App`.** Both files import no AppKit/SwiftUI/WebKit (already pure) and are fully unit-tested; keeping them in `MD2App` is consistent with the pre-existing pure `PDFPaginator` (also in `MD2App`). Moving only these two to `MD2Core` would split pure PDF/export logic across modules; a fully clean move would also relocate the pre-existing `PDFPaginator` (out of scope). Left as-is by design; can be revisited as a deliberate layering cleanup if strict separation is preferred.
