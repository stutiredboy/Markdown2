## 1. Attachment Settings and Core Model

- [x] 1.1 Add an attachment-folder preference to `AppSettings` (new `Keys` entry + `@Published` property), a new `L10nKey` label/help localized in **both** the `english` and `zhHans` dictionaries, and a Settings UI field defaulting to `assets`
- [x] 1.2 Implement document-relative attachment folder normalization that rejects absolute paths, `..`, home expansion, and paths escaping the document directory
- [x] 1.3 Add an attachment destination helper that creates the configured folder beside the Markdown document
- [x] 1.4 Implement collision-safe filename generation: keep+sanitize the source basename (extension preserved, whitespace→`-`, unsafe characters dropped/percent-encoded, CJK preserved on disk and percent-encoded in the Markdown path), fall back to `image-YYYYMMDD-HHMMSS.png`, and append a numeric suffix on collision
- [x] 1.5 Encode raw clipboard image data as PNG into the attachment folder; link existing files (dropped or pasted) in place rather than copying them
- [x] 1.6 Generate Markdown snippets — relative link-safe path for stored clipboard images, absolute link-safe path for linked files — with alt text from the source filename or `image`
- [x] 1.7 Route only clipboard-data insertion through the save flow (untitled documents saved first; cancelled save inserts nothing); dropped/pasted files link in place and need no save
- [x] 1.8 Surface attachment folder-creation/write failures through `DocumentStore.alert` and insert no Markdown when a write fails

## 2. Editor Paste and Drop Integration

- [x] 2.1 Add image attachment insertion callbacks/types to `MarkdownEditorView` so the editor can request snippets from `DocumentStore`
- [x] 2.2 Override paste handling in `MarkdownSourceTextView` to detect image file URLs or raw image data before falling back to normal text paste, and override `validateMenuItem` so the Paste command is enabled for an image-only clipboard (otherwise `Cmd+V` is a no-op)
- [x] 2.3 Add drag/drop handling for supported image file URLs, including multi-file drop ordering; dropped files are linked in place (no copy, no save prompt)
- [x] 2.4 Insert generated Markdown through `NSTextView.insertText(_:replacementRange:)` so dirty state, styling, autosave, selection, and undo stay on the native edit path
- [x] 2.5 Preserve existing paste/drop behavior for unsupported clipboard and drag payloads

## 3. Rendering and Preview Diagnostics

- [x] 3.1 Extend the `renderImages` regex to optionally consume a trailing `{...}` block for `{width=...}` and `{width=... height=...}` without breaking the existing alt/src/titled (`"title"`) matches
- [x] 3.2 Emit only safe numeric `width`/`height` attributes; let an explicit `{...}` block override URL-inferred dimensions from `imageDimensions(from:)`; ignore invalid values while preserving the base image
- [x] 3.3 Reuse `.image-frame` (width + `aspect-ratio`) only when both dimensions are known; for width-only, set `width` with `height: auto` and skip the fixed-aspect frame so the image is not distorted
- [x] 3.4 Inject a preview-only broken-image diagnostic from `MarkdownPreviewView` (e.g. a `WKUserScript`) using a single capture-phase `error` listener that survives the `main.innerHTML` live swap, writes the failed path via `textContent`, and styles the placeholder for light/dark — without touching the shared `RenderedDocument.html` shell used by PDF/print
- [x] 3.5 Ensure existing valid relative, titled, and URL-dimension-inferred image links render unchanged when no new size attributes are present
- [x] 3.6 Rewrite absolute local image paths to a preview/PDF-local whitelist scheme so linked-in-place files display without granting WebView read access to the filesystem root

## 4. Tests, Docs, and Verification

- [x] 4.1 Add unit tests for attachment folder normalization, destination creation, filename collision handling, and relative path generation
- [x] 4.2 Add tests for direct in-place file references and raw clipboard PNG attachment writing using injected test seams
- [x] 4.3 Add tests for file drops linking without a save prompt, plus untitled-document save cancellation and successful save-before-store for clipboard images
- [x] 4.4 Add renderer tests for width+height, width-only (aspect ratio preserved, no fixed frame), explicit-attribute-overrides-URL precedence, invalid size attributes, existing titled images, and existing URL-inferred dimensions
- [x] 4.5 Add preview/HTML tests confirming the broken-image diagnostic is absent from the shared shell used by PDF/print (the capture-phase listener and `textContent` path injection run in the preview web view, exercised by the functional GUI test)
- [x] 4.6 Update README and `Docs/MarkdownSupport.md` (including moving image drag/drop insertion, resize, and configurable root out of "Not Yet Supported") with image paste/drop, default `assets/`, configurable attachment folder, size syntax, and missing-image behavior
- [x] 4.7 Run `swift test` (195 tests pass)
- [x] 4.8 Run `Scripts/functional_test.sh` in a desktop session with GUI automation available
