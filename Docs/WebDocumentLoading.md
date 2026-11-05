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

## Page policy

Every page `MarkdownRenderer` produces carries a Content-Security-Policy `<meta>`,
ahead of everything it governs. It is the layer under `HTMLSafety` and each diagram
engine's own sanitizing: document content cannot run script on any engine, even
when its markup reaches the page. It is a `<meta>` rather than a response header
because an exported file has no response.

| Directive | App pages | Exported file |
| --- | --- | --- |
| `default-src`, `base-uri`, `form-action` | `'none'` | `'none'` |
| `script-src` | each served engine's exact URL, and a hash of each inline bootstrap | a hash of each inline script |
| `style-src` | `'unsafe-inline'` and KaTeX's stylesheet URL | `'unsafe-inline'` |
| `img-src` | `http:`, `https:`, `data:`, `md2-local-image:` | `http:`, `https:`, `data:`, `file:` |
| `font-src` | `data:` | `data:` |

- Scripts use hashes rather than a nonce because the renderer is pure, and the
  preview compares HTML to decide whether a page changed.
- No engine needs `'unsafe-eval'`. On a page with `eval` off, every engine and every
  Mermaid diagram type renders with no policy violation.
- `WKUserScript`s and `evaluateJavaScript` calls run under no page policy themselves,
  but what they do in the page does: a `<style>` they add answers to `style-src`.
- A live update keeps the page's policy. A body that needs a new engine is already a
  full load, and that page's policy names the engine.
- `img-src` is open on purpose. Remote Markdown images load, and so does an image a
  diagram label or CSS names. Only script is shut out.
- A plain click on a `javascript:` URL never reaches the navigation policy, and the
  page policy stops it. A new-window request reaches the navigation policy first, so
  `PreviewLinkRouter` ignores the scheme itself.
- `PreviewLinkRouter` hands the system only `HTMLSafety.safeURLSchemes`, the list
  Markdown links are held to. A diagram engine draws its own links, which never pass
  `HTMLSafety`, so the router is what holds them to that list. A link in an exported
  file is left to whatever opens that file.

## Regression checks

```sh
swift test
MD2_RUN_GUI_TESTS=1 swift test \
  --filter WebDocumentLoaderGUITests \
  --filter MermaidOffscreenRenderingTests \
  --filter ContentSecurityPolicyGUITests \
  --filter PreviewLinkSchemeGUITests \
  --filter MermaidLabelSecurityGUITests \
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
