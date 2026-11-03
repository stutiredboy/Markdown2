## 1. Root cause

- [x] 1.1 Reproduce the lost outline outside the app: compose a PDF with CoreGraphics, attach a `PDFOutline`, save with `dataRepresentation()` and `write(to:)`, reload.
- [x] 1.2 Narrow it down: annotations and attributes are saved, outline edits to a loaded document are not, and a `PDFDocument()` built by PDFKit saves its outline.

## 2. Exporter

- [x] 2.1 Add `PDFPaginator.outlineDictionary`: the outline tree in `kCGPDFOutline*` form, with page and position clamping.
- [x] 2.2 Resolve the outline before composing and write it with `CGPDFContextSetOutline` in `composePDF`.
- [x] 2.3 Read the outline back with `CGPDFDocument` and fail with `writeFailed` when it is missing.
- [x] 2.4 Remove `applyOutline`, `attach` and the PDFKit import.

## 3. Tests

- [x] 3.1 `testOutlineDictionaryWritesNestedBookmarksIntoAPDF`: nesting, titles, pages, points and clamping survive a CoreGraphics write and a PDFKit read.
- [x] 3.2 Confirm the new test fails when the destination page is zero-based.

## 4. Verification

- [x] 4.1 Run `openspec validate write-pdf-outline-with-coregraphics --strict`.
- [x] 4.2 Run the non-GUI suite.
- [x] 4.3 Run `MermaidOffscreenRenderingTests`, `PDFExportEndToEndVerification` and `PDFRunningTextTests` locally with `MD2_RUN_GUI_TESTS=1`.
