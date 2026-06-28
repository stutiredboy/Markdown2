## Context

Markdown2 already renders inline Markdown images in `MarkdownRenderer.renderImages` and resolves relative images in the preview by writing the rendered HTML into the document's directory and loading it with `loadFileRequest(_:allowingReadAccessTo:)`, which grants the web view read access to that directory tree (so `assets/foo.png` beside the document already resolves). The current gap is authoring: users must manually save screenshots or dragged files, pick a relative path, type `![alt](path)`, and then diagnose broken paths themselves.

Two existing behaviors this change must build on rather than reinvent:
- The renderer already infers pixel dimensions from sized URL segments (`imageDimensions(from:)`, e.g. `photo-1200x800.png` or `.../200x100`) and, when found, wraps the image in a `.image-frame` span carrying `width` and `aspect-ratio` so the browser reserves layout space. Explicit size attributes must layer onto this same path and frame, not duplicate it.
- The full rendered document (`RenderedDocument.html`) is shared verbatim by the live preview **and** by PDF export and printing (`DocumentStore.exportPDF`/`print` pass `rendered.html`). Anything added to the renderer's `<head>` shell — scripts, CSS — therefore also ships into exported PDFs, so the broken-image diagnostic must deliberately choose between the shared shell and preview-side injection.

This change crosses the editor surface, document model, settings, renderer, and preview CSS/JavaScript. It should preserve Markdown2's core constraints: plain Markdown files, native AppKit editing, offline behavior, no new runtime service, and no hidden document database.

## Goals / Non-Goals

**Goals:**
- Let users paste clipboard images or drop image files into the editor and get valid Markdown inserted at the caret/drop point.
- Store new images in a document-relative attachment folder, defaulting to `assets/`.
- Keep generated Markdown portable by using relative paths and sanitized collision-safe filenames.
- Let users configure the attachment folder as a document-relative path.
- Support image size attributes in preview and export-ready HTML without changing existing valid image links.
- Show an explicit preview placeholder when an image cannot be loaded.

**Non-Goals:**
- Full media library management, deduplication, orphan cleanup, or asset garbage collection.
- Uploading images to a remote host or syncing attachments across devices.
- Absolute external attachment roots in v1; the app should keep assets document-relative for portability.
- Drag-handle WYSIWYG resizing in the preview. The first version supports explicit Markdown size attributes.
- Changing the document format away from plain Markdown.

## Decisions

### Editor-owned paste/drop detection, DocumentStore-owned asset writes

`MarkdownSourceTextView` should intercept paste and drag/drop operations that contain image data or image file URLs, then ask the surrounding SwiftUI/App layer to create an attachment and return the Markdown snippet to insert. The text view remains responsible for inserting the returned snippet with `insertText(_:replacementRange:)` so the edit flows through the existing `NSTextViewDelegate` path, styling, dirty marking, autosave, and undo behavior.

Alternative considered: have `DocumentStore` directly mutate `text` at a character range. That would bypass `NSTextView`'s normal edit path and make selection/undo behavior harder to keep native.

### Two insertion paths: link existing files, store only clipboard data

An image the user brings in is one of two things, and they are handled differently:

- **An existing file** — dropped from Finder, or a file URL on the clipboard. It already lives on disk, so the editor links it in place: insert `![alt](/absolute/path)` pointing at the file's real location, **without copying it**. This needs no save, so it works in an untitled document too.
- **Raw clipboard bitmap data** — a screenshot or "Copy Image", which has no file location. The editor must materialize it, so it encodes the data as PNG into the document-relative attachment folder. That requires a real location, so an untitled document is saved first via `DocumentStore.save()` (a synchronous `NSSavePanel`); a cancelled save or a write failure inserts nothing.

`DocumentStore.insertImageAttachments` branches on the source type and prompts for a save only when at least one source is raw data. The drop handler still resolves the drop point and defers insertion to the next run-loop turn, which is harmless now that the file path no longer opens a modal.

Alternative considered: always copy dropped files into `assets/` for portability (the original v1 plan). Rejected after testing — copying duplicates a file the user already has, and linking the original location is the expected behavior. Portability stays the author's choice: keep images under the document folder and the paths are relative.

### Attachment path is document-relative and sanitized

The setting should store a relative folder path such as `assets` or `images/screenshots`. Empty values fall back to `assets`. Absolute paths, path traversal (`..`), home expansion, and path separators that escape the document directory should be rejected or normalized back to the default. The app creates the folder when the first attachment is inserted; if creating the folder or writing the file fails, surface the error through the existing `DocumentStore.alert` path and insert no Markdown.

Generated filenames must be URL/Markdown-friendly. This is a hard requirement, not only a portability nicety: the renderer's image regex captures the source with `(\S+?)`, so a path containing a space fails to match and the whole `![…](…)` renders as literal text instead of an image. The sanitizer therefore keeps the source extension; replaces whitespace runs with `-`; drops or percent-encodes characters outside an unreserved set; preserves CJK and other safe Unicode in the on-disk name while percent-encoding it in the emitted Markdown path; and falls back to a timestamped `image-20260625-153012.png` when nothing usable remains. If the destination already exists, append a numeric suffix (`diagram-2.png`).

### Encode raw clipboard data as PNG; never transcode existing files

Raw image data from the pasteboard (a screenshot) is encoded as PNG before being written into the attachment folder: PNG is widely supported, lossless for screenshots, and avoids embedding pasteboard-specific TIFF in a Markdown project. Existing files are linked in place and keep their original format untouched — no copy, no transcode.

### Enable Paste for image-only clipboards, and whitelist external local image reads

Two AppKit/WebKit details make the feature actually work:

- A plain-text `NSTextView` (`isRichText == false`) reports the **Paste** command as invalid when the clipboard holds only image data (no string type), so `Cmd+V` is a no-op and the `paste(_:)` override never runs. `MarkdownSourceTextView` overrides `validateMenuItem(_:)` to enable Paste whenever the clipboard yields image sources.
- The preview previously granted the web view read access only to the document directory, so a linked image at an absolute path elsewhere on disk would fail to load. Do not grant the WebView read access to `/`: the preview enables JavaScript for math/diagram rendering and the renderer allows a small raw-HTML surface, so broad file read access is not an acceptable trade-off. Instead, rewrite absolute local image `src` values to an app-local `md2-local-image://` scheme and register only the exact image files referenced by the current render with a `WKURLSchemeHandler`. Relative document images still load through the document-directory read grant; PDF/print uses the same whitelist rewrite so export matches preview.

### Use Pandoc-style image attributes for size control

The renderer should accept an attribute block immediately following an image, for example:

```markdown
![diagram](assets/diagram.png){width=480}
![photo](assets/photo.jpg){width=320 height=180}
```

Only numeric pixel values are supported in v1. The image regex in `renderImages` must be extended to optionally consume a trailing `{...}` block so the literal attributes are never emitted as visible text, while the existing alt/src/title capture and the titled form `![alt](src "title")` keep matching unchanged.

Rendering rules:
- **Width and height both present** → emit both on the `<img>` and reuse the existing `.image-frame` span (`width` + `aspect-ratio = width / height`), exactly as URL-inferred dimensions already render.
- **Width only** → set `width` on the `<img>` with `height: auto` so the intrinsic aspect ratio is preserved; do **not** wrap in a fixed-aspect `.image-frame`. The current `.image-frame img { width: 100%; height: 100% }` rule assumes a known ratio and would distort a width-only image.
- **Precedence** → an explicit `{...}` block overrides dimensions inferred from the URL pattern, so `![](photo-1200x800.png){width=480}` renders at 480.
- **Invalid** → non-numeric or malformed attributes (`{width=large}`) are ignored, the base image renders, and no unsafe attribute reaches the HTML.

Alternative considered: Typora-specific inline HTML or app-owned comments. Pandoc-style attributes are readable, common in Markdown publishing workflows, and degrade acceptably in other editors as visible text after the image.

### Preview diagnostics use a delegated load-error listener

Image load failures should surface as a visible placeholder that names the failed source, legible in light and dark mode, without blocking valid local or remote images. Because the renderer cannot know at render time whether a file exists (`MD2Core` has no base URL), this is a runtime concern driven by the WebView, which already learns when a resource fails to load.

**Mechanism.** Install a single capture-phase listener once per page —
`window.addEventListener('error', handler, /* useCapture */ true)` — that matches `event.target instanceof HTMLImageElement`. `error` events do not bubble, so capture is required, and one delegated listener (rather than per-`<img>` `onerror`) survives the live preview's in-place swap, where `main.innerHTML = bodyHTML` rebuilds the rendered body on every keystroke in Side-by-Side mode. The handler replaces the broken image with a placeholder element and writes the failed path via `textContent` (never `innerHTML`) so an odd or hostile path cannot inject markup.

**Placement (and why it is not in the shared shell).** The listener and its CSS live in the **preview path only** — inject them from `MarkdownPreviewView`, e.g. a `WKUserScript` on the web view's `userContentController`, which runs on every full load and installs the capture listener that then persists across `innerHTML` swaps. They must **not** go into `RenderedDocument.html`, because that shell is reused verbatim by PDF export and printing; a deliverable PDF should fail quietly, not stamp a broken-image box onto the page. (A future change can move the diagnostic into the shell deliberately if PDFs should show it.)

**Untitled-document scope.** An unsaved document loads via `loadHTMLString(_:baseURL: nil)`, which grants no file read access, so *every* relative image in it fails to load and shows the placeholder. That is existing behavior, not a regression: the attachment flow saves the document before writing assets, after which relative paths resolve.

Renderer-level file existence checks were rejected for v1 for the reason above; the WebView is the natural place to detect failure.

## Risks / Trade-offs

- **Undo can orphan a just-inserted image file** → Accept for v1. The Markdown edit should remain undoable; automatic file deletion would risk removing an asset the user already referenced elsewhere.
- **Clipboard data may contain multiple image representations** → Prefer file URL when available, then PNG-compatible image data, and ignore unsupported representations.
- **Dropped filenames may contain spaces or unsafe characters** → Sanitize generated destination names and percent-encode the Markdown path if needed, with tests for CJK and punctuation.
- **Saving before paste/drop interrupts flow for untitled documents** → The prompt happens only for untitled documents and preserves the portability guarantee. Users who work with saved files get one-step insertion.
- **Image error diagnostics could affect remote images during temporary network failures** → The placeholder should indicate the source path and remain non-destructive; it does not rewrite Markdown.
- **Attribute syntax may not match every Markdown tool** → It is plain text fallback and is a common enough convention for technical writing. Raw image links without attributes remain unchanged.

## Migration Plan

No existing documents need migration. Existing image Markdown continues to render as before. New settings should default to `assets`, and existing users who never open Settings should get the default automatically.

Rollback is straightforward: remove paste/drop handling, attachment writing, settings UI, and size/diagnostic rendering changes. Markdown files created during the feature remain valid because they contain ordinary relative image links; only `{width=...}` attributes may appear as visible fallback text in tools that do not support them.

## Open Questions

- Should the inserted alt text default to the sanitized filename stem, an empty string, or the original filename stem? Recommendation: original filename stem for dropped files, `image` for raw clipboard images.
- Should CJK filenames be preserved or transliterated? Recommendation: preserve when safe, but generate percent-encoded Markdown paths.
- Should Settings expose only a text field for the attachment folder or include a folder picker constrained to document-relative paths? Recommendation: text field in v1, picker later if needed.
