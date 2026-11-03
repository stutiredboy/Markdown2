## Context

PDF export renders the document in an offscreen `WKWebView`, captures page-height bands with `createPDF`, and `composePDF` draws each band onto a fixed-size page in a CoreGraphics PDF context. The heading outline (bookmarks) was added afterwards: `applyOutline` loaded the composed bytes into a `PDFDocument`, built a `PDFOutline` tree with a `PDFDestination` per heading, set `document.outlineRoot`, and returned `document.dataRepresentation()`.

On macOS 27.2 (build 26B123), `PDFExportEndToEndVerification.testRealExportProducesValidMultiPagePDF` fails: the export succeeds and the file has several pages, but `PDFDocument(url:)?.outlineRoot` is nil when the file is read back. Unchanged `main` (1d52a8e) fails the same way. CI's `gui-tests` job runs on macOS 15, where the test passes.

## Root cause

PDFKit on macOS 27 does not save outline changes to a document it loaded from existing data. A standalone program shows this without WebKit or the app. It composes three pages with `CGContext`, loads them with `PDFDocument(data:)`, and attaches three bookmarks:

| Step | Result on macOS 27.2 |
|---|---|
| `document.outlineRoot` after attaching | present, 3 children |
| reload `dataRepresentation()` | `outlineRoot` nil |
| `write(to:)`, then `write(to:withOptions:)`, reload the file | `outlineRoot` nil |
| saved catalog | `<< /Pages 4 0 R /Type /Catalog >>`: no `/Outlines` |

The loss affects only the outline, not every edit:

- An annotation added to a page and a title set in `documentAttributes` are both saved.
- A source PDF that already has an outline keeps it through `dataRepresentation()`. If one of its labels is edited, or `outlineRoot` is replaced with a new tree, the saved file still holds the original outline. PDFKit writes the outline it parsed and ignores the `PDFOutline` objects.
- These variants also lose the outline: loading from a URL instead of data, assigning `outlineRoot` before adding children, and using `PDFActionGoTo` actions in place of destinations.
- A document PDFKit created itself (`PDFDocument()` with copied pages) does save its new outline.

Nothing reports an error: `dataRepresentation()` returns data and `write(to:)` returns `true`. The exporter treated a non-nil `dataRepresentation()` as proof the outline was written, so the export succeeded without bookmarks.

## Decisions

### Write the outline with `CGPDFContextSetOutline`

`composePDF` already writes the PDF with a CoreGraphics PDF context. `CGPDFContextSetOutline` (macOS 10.13+) adds an outline to that context, and CoreGraphics writes it when the context closes. Its dictionary keys are public, documented in `CGPDFDocument.h`: `kCGPDFOutlineTitle`, `kCGPDFOutlineDestination` (a one-indexed page number), `kCGPDFOutlineDestinationRect`, and `kCGPDFOutlineChildren`, under a root that holds only children.

The exporter now resolves the outline tree before composing (`PDFPaginator.outlineEntries` and `outlineTree`, unchanged) and passes it to `composePDF`. `composePDF` sets it after the last page and before `closePDF()`. PDFKit is no longer part of the export, and the composed PDF is no longer loaded and serialized a second time.

CoreGraphics writes the destination rect's origin as `[page /XYZ left top null]`. That is the same destination PDFKit wrote for `PDFDestination(page:at:)`; both were dumped on macOS 27.2 and gave `/XYZ 36 706 null` for the same heading. Bookmark targets therefore do not change. Each destination is a zero-size rect at `(margins.left, contentTop - offsetInPage)`. The page is clamped into the document and Y onto the page, as `attach` did. Without a rect, CoreGraphics writes `/XYZ null null null` and PDFKit reads the point back as `FLT_MAX`, so the rect is always set.

`PDFPaginator.outlineDictionary` builds the dictionary. `PDFPaginator` already owns the outline tree, needs only CoreGraphics, and has headless tests.

*Alternatives considered:*
- **Attach the outline to a fresh `PDFDocument`.** Copying the composed pages into `PDFDocument()` before attaching the outline saves the outline on macOS 27.2. It still depends on PDFKit's outline saving, the path that just changed without notice, and it keeps the extra parse and re-serialization of the whole document.
- **`write(to:)` instead of `dataRepresentation()`, `PDFActionGoTo` in place of destinations, assigning the root first, document attributes.** None of these saves the outline on macOS 27.2 (see the table above).

### Read the outline back before writing the file

`CGPDFContextSetOutline` returns nothing. With bookmarks, `captureBands` reads the composed bytes with `CGPDFDocument` and fails with `writeFailed` if `outline` is nil, before writing the destination file. This keeps the export's existing contract: a document with headings fails loudly rather than shipping without bookmarks. The silent PDFKit loss broke that contract once without notice. The read is cheap, because `CGPDFDocument` parses lazily and `outline` touches only the catalog and outline objects. CoreGraphics reads the outline here, not PDFKit, so the check does not depend on the reader that just changed behavior.

## Verification

- **Standalone repro (macOS 27.2):** the PDFKit path loses the outline as described. `CGPDFContextSetOutline` with the documented keys writes `/Outlines` with nested items, one-indexed pages and `/XYZ` destinations. PDFKit and `CGPDFDocument.outline` both read it back, including CJK, emoji, parenthesized, backslash and empty titles.
- **New headless test:** `PDFPaginatorTests.testOutlineDictionaryWritesNestedBookmarksIntoAPDF` writes the dictionary into a three-page CoreGraphics PDF and reads it back with PDFKit. It covers nesting, titles, pages, points, a Y offset clamped to the page bottom, and a page index clamped to the last page. Writing a zero-based page number fails 5 of its assertions. It runs in plain `swift test`, so CI's non-GUI lane exercises CoreGraphics' outline writer and PDFKit's reader on macOS 15.
- **GUI suites (local, macOS 27.2):** `PDFExportEndToEndVerification`, `MermaidOffscreenRenderingTests` and `PDFRunningTextTests` pass. `testRealExportProducesValidMultiPagePDF` failed on its outline assertions before this change.
- **macOS 15:** CI's `gui-tests` job runs the same end-to-end test. `CGPDFContextSetOutline` has existed since macOS 10.13, and the reader side is the same PDFKit that read the old outline there.

## Risks / Trade-offs

- **Parent bookmarks now start expanded.** CoreGraphics writes a parent item's `/Count` as positive (open). PDFKit wrote it as negative (closed), because a new `PDFOutline` has `isOpen == false`. A reader's bookmark sidebar now shows the whole heading tree at first, where it used to show only the top level. `CGPDFContextSetOutline` has no key for the open state, so keeping it collapsed would mean going back to PDFKit for the outline. Titles, nesting and targets are unchanged.
- **The outline root's `/Count` is negative.** CoreGraphics writes `/Count -1` on the outline root (PDFKit left it out), though the PDF spec does not allow a negative root count. PDFKit and `CGPDFDocument` read the outline correctly. Other readers have not been checked.
- **A future OS could change `CGPDFContextSetOutline` the same way.** The read-back check turns that into a failed export rather than a silent loss, and both the headless test and the GUI test would fail.
