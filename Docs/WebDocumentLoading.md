# Preview and PDF document loading

Preview, PDF export, and the PDF stage of printing use `WebDocumentLoader`.
They never create, rewrite, or sweep HTML files in the source directory and do
not grant WebKit directory-wide file access. Read-only source directories work;
the selected PDF destination must be writable.

## Resource boundaries

- `md2-doc://document/<load-id>/index.html` serves the current HTML from memory.
  Each full load has a fresh ID, including reloads to the same heading. Previous
  pages are discarded, and page responses use `Cache-Control: no-store`.
- `md2-app://assets/<sha256>/<bundled-path>` serves only the enumerated resources
  in `BundledWebAsset`: KaTeX CSS (including its embedded fonts), KaTeX/mhchem,
  Mermaid, Raphael, Underscore, flowchart, and sequence. Bytes and hashes are
  cached lazily in the app, and immutable response headers permit WebKit reuse.
  A changed bundle gets a changed URL. Scripts retain their dependency order;
  unused diagram engines are not requested.
- `md2-local-image://` retains the existing per-document image allowlist.
  Relative paths, parent paths, absolute paths, and file URLs resolve through
  the same rewriter for full loads and live content replacements.

Relative hyperlinks are resolved against the source directory, while TOC and
footnote fragments stay on the memory page. The preview navigation policy only
allows its current page and its fragments; local document links continue to be
handed back to the application. An untitled document has no relative file base.

`DocumentRenderWorker` defaults to `.appScheme`. Standalone HTML export explicitly
uses `.inline`, then embeds local images with `SelfContainedHTMLBuilder`, preserving
the portable single-file export. The public renderer's default remains `.inline`
for callers that do not install the application scheme handlers.

External resources remove engine/font bytes from every rendered page. They do
not eliminate first-execution JavaScript cost; timing and WebKit's cache-hit
behavior are not guaranteed by the loader.

## Regression checks

```sh
swift test
MD2_RUN_GUI_TESTS=1 swift test \
  --filter WebDocumentLoaderGUITests \
  --filter MermaidOffscreenRenderingTests \
  --filter PDFExportEndToEndVerification \
  --filter PreviewSecurityGUITests \
  --filter LineNumberGutterGUITests \
  --filter EditorLineNumberGutterGUITests
```

The real-preview check compares source-directory bytes and modification time
across opening, full reload, fragment navigation, and live replacement. This
detects transient create/delete operations as well as leftover files. Existing
legacy `.md2-preview-*.html` files are deliberately left untouched.

The read-only export check uses a `0555` source directory, exports elsewhere,
and checks actual PDF pixels for relative and parent-directory images. Engine
tests exercise the external resources in WebKit; PDF checks cover diagrams,
math, pagination, light appearance, and image embedding. Standalone HTML tests
reject application resource URLs in the exported file.
