## 1. Builder

- [x] 1.1 Add `SelfContainedHTMLBuilder.Output` and return it from `build`: remote images and unembedded local images, in document order, each listed once.
- [x] 1.2 Limit the scan to `<main>`, so string literals in the inlined engines are not read as images.
- [x] 1.3 Update the test call sites to read `.html`.

## 2. Notice

- [x] 2.1 Add the alert strings in English and Simplified Chinese.
- [x] 2.2 Add `DocumentStore.htmlExportNotice` and show it from `exportHTML` after the file is written.

## 3. Tests

- [x] 3.1 Report: remote, missing, unresolved with no base URL, inlined, `data:`, non-image, duplicates, document order, escaped names, empty source.
- [x] 3.2 Scan scope: a script's `<img src=` literal is not read or rewritten, and an authored `</main>` does not hide a later image.
- [x] 3.3 `DocumentStore`: notice, no notice, untitled document, cap, failed write, Chinese copy.
- [x] 3.4 Confirm the no-notice test fails when the scan covers the whole page.
- [x] 3.5 Pin the limit: an image in diagram source is neither inlined nor reported.

## 4. Claims

- [x] 4.1 Update `README.md` and `README.zh-CN.md`.
- [x] 4.2 Update `Docs/MarkdownSupport.md`.
- [x] 4.3 Update `compatibility-matrix.json` and regenerate `Docs/CompatibilityMatrix.md`.
- [x] 4.4 Correct the Purpose line of the `html-export` spec after archiving.

## 5. Verification

- [x] 5.1 Run `openspec validate report-unembedded-html-images --strict`.
- [x] 5.2 Run the non-GUI suite in CI's three steps.
- [x] 5.3 Check the notice through the real renderer and file write, with the `DocumentStore` tests. The on-screen alert is covered under Verification in the design.
