## Why

On macOS 27.2 (build 26B123), an exported PDF has no bookmarks. The export succeeds and the pages are correct, but the saved file has no `/Outlines` in its catalog, so `PDFExportEndToEndVerification.testRealExportProducesValidMultiPagePDF` fails on its outline assertions. Unchanged `main` (1d52a8e) fails the same way, so the cause is the OS, not a recent change.

The exporter composed the pages with CoreGraphics, then loaded that data into a `PDFDocument`, set `outlineRoot`, and saved it with `dataRepresentation()`. On macOS 27, PDFKit ignores any change to the outline of a document it loaded from existing data when it saves that document. The outline is there in memory and gone from the saved bytes. Nothing reports an error, so the export's check that the outline was written never fired.

## What Changes

- **Write the outline with CoreGraphics.** `composePDF` passes the heading outline to `CGPDFContextSetOutline` before it closes the PDF context. Pages and bookmarks are written in one pass, and the exporter no longer reloads and re-saves the PDF through PDFKit.
- **Build the outline dictionary in `PDFPaginator`.** `PDFPaginator.outlineDictionary` turns the outline tree into the documented `kCGPDFOutline*` form: title, one-indexed page, and a destination rect at the heading's top-left, with the same page and position clamping as before.
- **Read the outline back.** `CGPDFContextSetOutline` returns nothing, so the exporter reads the composed data with `CGPDFDocument` and fails with `writeFailed` when a document with headings came out without an outline. Before, a PDFKit save that dropped the outline went unnoticed.
- **Tests:** `PDFPaginatorTests.testOutlineDictionaryWritesNestedBookmarksIntoAPDF` writes the dictionary into a CoreGraphics PDF and reads it back with PDFKit: nesting, CJK and parenthesized titles, pages, points, and clamping. It is headless, so plain `swift test` and CI's non-GUI lane run it.

**Non-goals:**

- No change to which headings become bookmarks, how they nest, or where they point.
- No change to page rendering, pagination, running text, or the two load-bearing lines in `PDFExporter.swift` (forced `.aqua` appearance, the `printStyleScript` media selector).
- Print (`DocumentPrinter`) still loads the exported PDF with PDFKit to print it. Printing ignores bookmarks, so the PDFKit behavior does not affect it.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `pdf-export`: the outline must be in the saved file as a PDF reader reads it back, and an outline that cannot be written fails the export.

## Impact

- `Sources/MD2App/PDFExporter.swift`: `captureBands`, `composePDF`, new `containsOutline`; `applyOutline`/`attach` and the PDFKit import removed.
- `Sources/MD2App/PDFPaginator.swift`: new `outlineDictionary`.
- `Tests/MD2CoreTests/PDFPaginatorTests.swift`.
- Exported PDF bytes: the outline objects are now written by CoreGraphics. Bookmark titles, nesting, pages and `/XYZ left top` destinations are unchanged. Parent bookmarks now start expanded in a reader's sidebar, where PDFKit wrote them collapsed (see design).
