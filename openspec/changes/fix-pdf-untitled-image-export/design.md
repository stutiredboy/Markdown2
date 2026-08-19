## Context

`PDFExporter.export` renders the preview HTML in an offscreen, window-hosted `WKWebView` and captures page bands. Because a WKWebView loaded via `loadHTMLString` has no filesystem read access, local images are routed through two pieces of machinery:

1. `LocalImageHTMLRewriter.rewrite(html, baseURL:)` rewrites every resolvable `<img src>` to `md2-local-image://image/<token>` and returns the `token → file URL` whitelist.
2. `LocalImageSchemeHandler` serves `md2-local-image://` requests by reading the whitelisted file from disk, so images load without the web view ever holding broad file access.

The current `export` runs this machinery only when `baseURL` is a file URL:

```swift
guard let baseURL, baseURL.isFileURL else {
    webView.loadHTMLString(html, baseURL: baseURL)
    return
}
let rewritten = LocalImageHTMLRewriter.rewrite(html, baseURL: baseURL)
localImageSchemeHandler.setAllowedImages(rewritten.allowedImages)
// … write temp file, loadFileRequest with allowingReadAccessTo: baseURL
```

`DocumentStore.baseURL` is `fileURL?.deletingLastPathComponent()`, so an untitled document has `baseURL == nil` and takes the early-return path: no rewriting, no whitelist, and `loadHTMLString` (no file access). Every local image then fails to load and the PDF shows blank image regions. Measured via a rasterized export: an absolute-path red image yields ~72 dark pixels for a file-backed document but ~0 for an untitled one.

## Goals / Non-Goals

**Goals:**
- Embed resolvable local image references (absolute filesystem paths and `file://` URLs) in the exported PDF for untitled documents, matching the file-backed behavior.
- Keep the file-backed path byte-for-byte identical to today (no regression to relative/absolute images in saved documents).
- Fix applies to both PDF export and Print, since both reuse `PDFExporter`.

**Non-Goals:**
- Making *relative* image references work in an untitled document — there is no base directory to resolve them against, so they remain unresolvable by definition.
- Remote (`http(s)://`) images — the rewriter deliberately leaves them for the network and this change does not touch that.
- Changing image attachment storage or the preview's image handling.

## Decisions

**Decision 1 — Always rewrite and register local images, then choose the load path by `baseURL`.**

Restructure `export` so the rewriter and whitelist registration run unconditionally, and only the HTML-loading step branches:

```swift
let rewritten = LocalImageHTMLRewriter.rewrite(html, baseURL: baseURL)
localImageSchemeHandler.setAllowedImages(rewritten.allowedImages)
if let baseURL, baseURL.isFileURL {
    // … existing temp-file + loadFileRequest path …
} else {
    webView.loadHTMLString(rewritten.html, baseURL: nil)
}
```

Rationale: `LocalImageHTMLRewriter.rewrite` is already `nil`-safe — with a `nil` base it still rewrites absolute paths and `file://` URLs (the `hasPrefix("/")` and `file://` branches of `localImageURL`) and simply skips relative references. Passing the *rewritten* HTML to `loadHTMLString` means those absolute/file references resolve through the scheme handler, which needs no file read access. The scheme handler is registered once in `init`, independent of the load path. This mirrors `MarkdownPreviewView.load`, which already implements the same rewrite-then-branch pattern for the live preview and proves it works for untitled documents in production; the export path had drifted from it (short-circuiting before the rewrite when `baseURL` was `nil`), which is what caused this bug. The `export` `else` branch carries a comment naming that twin so future drift is cheap to catch.

Alternatives considered:
- *Write the temp render file and use `loadFileRequest` even when `baseURL` is nil* — the temp file needs a directory; `loadFileRequest`'s `allowingReadAccessTo` is meaningless with no base, and relative references would still be unresolvable. More machinery for no additional coverage. Rejected.
- *Grant `loadHTMLString` file read access by other means* — WebKit offers no per-document read grant on `loadHTMLString`; the scheme handler is already the sanctioned mechanism. Rejected.

**Decision 2 — Leave relative references in untitled documents unresolved, as a documented limitation.**

A relative `![x](img.png)` has no base directory to resolve against when the document is untitled, so it is inherently unembeddable. The rewriter already skips it. This is acceptable because the supported way to add images to an untitled document is *dropping* files (absolute paths), and *pasting* requires a file-backed document.

## Risks / Trade-offs

- **The rewriter's regex could still miss some `<img>` forms** → Mitigation: unchanged from today; the new tests assert the absolute-path and `file://` cases the rewriter handles, so a future regex change is caught by the existing image tests.
- **A relative image in an untitled document stays blank** → Mitigation: inherent (no base), documented in the spec as explicitly out of scope, matching the image-drop feature's contract.
- **`loadHTMLString` vs `loadFileRequest` image timing** → Not a real divergence: both paths serve images through the same scheme handler (the file-backed path also rewrites to `md2-local-image://` tokens; `allowingReadAccessTo:` there grants read access to the temp HTML file and relative non-image resources, not to images). Image load timing is therefore identical, and the diagram-settle wait bounds capture for both. The GUI tests exercise the exact untitled path end-to-end.
- **Image-only untitled docs capture before a slow image fully paints (inherited)** → The settle probe only awaits Mermaid; for an image-only doc it captures after a short grace, so a large/slow-to-decode image served by the scheme handler could be missed while the export still reports success. Inherited — the file-backed path has the same race, and "matching file-backed behavior" already holds. Mitigation: the GUI tests use a fast-decoding solid-color image; documented as an inherited limitation rather than expanding the settle wait in this change.
- **A local image deleted between rewrite-time and load-time silently blanks (inherited)** → The rewriter's `FileManager.fileExists` check runs at rewrite time; if the file is removed before the scheme handler serves it, the handler `fail()`s the image but `didFinish` still fires and the export reports success with a broken image. Inherited (the file-backed path has the same race); documented, not fixed here.

## Migration Plan

None — this is a behavior fix with no data model or file format change. File-backed exports are unchanged; untitled exports gain image embedding for absolute/file references.
