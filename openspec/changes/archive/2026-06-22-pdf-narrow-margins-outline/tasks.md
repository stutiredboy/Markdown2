## 1. Narrow the default page margins

- [x] 1.1 In `Sources/MD2App/PDFExporter.swift`, change `printMargin` from `48` to `36` (0.5"); confirm `margins`, `printableWidth`, `printableHeight`, `pageContentHeight`, and the offscreen layout width all derive from it without further edits.
- [x] 1.2 Confirm `PDFPaginator` needs no change (it takes margins/`maxBand` as inputs) and the boundary cushion still applies.

## 2. Thread the document outline through to the exporter

- [x] 2.1 In `Sources/MD2App/DocumentStore.swift`, change the `PDFExporting` protocol to `export(html:outline:baseURL:completion:)` (outline is `[Heading]`).
- [x] 2.2 Update `exportPDF()` to pass `rendered.outline` to the exporter.
- [x] 2.3 Update `PDFExporter.export(...)` signature to accept and retain the outline for use during composition.

## 3. Probe each heading's DOM position during the break-probe

- [x] 3.1 Extend `breakProbeScript` to also return a `headings` array: for each heading `id` present in the document, record `{ id, top }` where `top = getBoundingClientRect().top + scrollY` (document pixels), skipping ids with no element.
- [x] 3.2 In `producePDF()`/`capturePDF(...)`, parse the `headings` payload into `[(id, top)]` and carry it through to composition alongside `bands`.

## 4. Map headings to pages (pure, testable)

- [x] 4.1 Add a pure helper (e.g. on `PDFPaginator`) that, given the page bands and a heading's document-Y offset, returns the page index whose half-open `[top, top+height)` range contains the offset (clamped to the last page).
- [x] 4.2 Add a pure helper that builds the nested outline structure from `[Heading]` ordered by document position, nesting each heading under the nearest preceding heading of a shallower `level` (else the root), preserving title and computed page index.

## 5. Write the PDF outline with PDFKit

- [x] 5.1 `import PDFKit` in `PDFExporter`; after `composePDF` produces the page `Data`, when the outline is non-empty load it into a `PDFDocument`.
- [x] 5.2 Build a `PDFOutlineRoot` and a `PDFOutline` node per heading using the nesting helper, each with a `PDFDestination(page:at:)` for its mapped page and a best-effort top-of-heading point; attach the root to the document.
- [x] 5.3 Write the document's `dataRepresentation()` to the destination URL; when the outline is empty, write the plain composed `Data` unchanged so a heading-less document still exports.
- [x] 5.4 Ensure failure to attach/serialize the outline surfaces through the existing `ExportError`/completion path (never writes a malformed PDF silently).

## 6. Tests

- [x] 6.1 In `Tests/MD2CoreTests/PDFPaginatorTests.swift` (or a sibling), test the heading→page mapping helper: offset at a band start, mid-band, exactly on a boundary, before the first/after the last band.
- [x] 6.2 Test the outline-nesting helper: flat same-level headings, deepening levels (1→2→3), a level jump back up (3→1), and an empty input → empty tree.
- [x] 6.3 Keep existing `PDFPaginatorTests` green (bands, fit-scale, boundary, runaway guard).

## 7. Verify against a real document

- [x] 7.1 Run `swift build` and `swift test`; confirm the suite passes.
- [x] 7.2 Export a multi-heading, multi-page document and confirm in a PDF reader: margins are visibly narrower (~0.5"), the outline shows all headings nested by level, and selecting entries jumps to the right pages.
- [x] 7.3 Export a document with no headings and confirm it produces a valid PDF with no outline and no error.
