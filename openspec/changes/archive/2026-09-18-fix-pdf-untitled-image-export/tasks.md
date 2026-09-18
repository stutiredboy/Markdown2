## 1. Regression coverage (GUI-gated, fail-first)

- [x] 1.1 Add a GUI-gated test in `PDFExportEndToEndVerification` that exports an untitled document (`baseURL: nil`) with an absolute-path image and asserts the image rendered. Use a sized solid-color image (e.g. 200×200) and a color-specific assertion (`countColorPixels`) — NOT the generic dark-pixel count, which body text satisfies and would false-pass on a blank image
- [x] 1.2 Add a GUI-gated test that the same document exported with a `baseURL` (file-backed) still renders the image (guards the temp-file + `loadFileRequest` path against regression), with the same color-specific assertion
- [x] 1.3 Add a GUI-gated test that an untitled document (`baseURL: nil`) with a `file://` image embeds it — the rewriter's `file://` branch is a distinct code path from the absolute-path branch, and the spec requires this scenario

## 2. Implementation

- [x] 2.1 In `PDFExporter.export`, run `LocalImageHTMLRewriter.rewrite(html, baseURL: baseURL)` and `localImageSchemeHandler.setAllowedImages(...)` unconditionally, before the baseURL branch
- [x] 2.2 Keep the temp-file + `loadFileRequest` path when `baseURL` is a file URL, and otherwise load the rewritten HTML via `loadHTMLString(rewritten.html, baseURL: nil)` so absolute/`file://` images resolve through the scheme handler

## 3. Verification

- [x] 3.1 Build and run the non-GUI suite (`swift test`) — 430 tests, 55 suites, all pass (GUI-gated tests skip)
- [x] 3.2 Run the GUI-gated suite (`MD2_RUN_GUI_TESTS=1 swift test --filter PDFExportEndToEndVerification`) and confirm the new assertions pass — 8 tests pass (1 skipped), incl. the three new image-embedding tests (1849 image pixels each, threshold 500)
- [x] 3.3 Manually export an untitled document containing a dropped image to PDF and confirm the image appears (no longer blank), and that a saved document's images are unchanged — superseded by 3.2: the GUI tests render a dropped-style absolute/`file://` image through the real `createPDF` + rasterize output and pixel-assert it appears, which is stronger and deterministic than a manual export
