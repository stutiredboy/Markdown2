## Context

`MarkdownPreviewView` updates the Side by Side preview in place. The coordinator rewrites the new body off the main thread (`WebDocumentLoader.rewriteContent`), then calls `window.__md2ApplyContent(body)`. That function clears find marks, sets `<main>`'s `innerHTML`, calls `__md2RenderMath(main)` and `__md2RenderDiagrams(main)`, and rebuilds the line-number gutter. Rendering replaces each formula's and each diagram's source text with its output, so the page keeps no copy of what a node looked like when it arrived.

The renderer joins top-level blocks with `\n`. Each block's opening tag carries `data-md2-source-line` (and `data-md2-source-end-line` when it spans lines); list items and footnotes carry them too, and task checkboxes carry `data-md2-task-line`. Inserting one line above a block changes those values and nothing else in it.

## Decisions

### Diff the top-level nodes of `<main>` by key

`__md2ApplyContent` parses the new body into a `<template>`. Each top-level node gets a key:

- an element: its `outerHTML` with the three line attributes removed. The values are taken out of the parsed DOM before serializing and put back after, so text that happens to spell one of those attributes is not affected;
- a text or comment node: its type and data.

An element's key is stored on the live node (`__md2Key`) when it is inserted. Text nodes are never touched by rendering, so their keys are read from the live node.

The update keeps the common prefix and suffix of the old and new key lists. In the range between them, an old node whose key appears in the new range is reused, in order of appearance; the rest are removed and the new nodes are inserted. A reused node is only moved when it is not already in place, so its rendered content and scroll state stay as they are.

A kept or reused node takes the new values of the line attributes. Its own element and its descendants that carry one of them are paired with the parsed node's, in document order. Rendering adds no such elements, so the counts match; when they do not, the node is replaced instead.

Only the inserted nodes are rendered. `__md2RenderMath` and `__md2RenderDiagrams` accept an array of roots and include a root that itself matches (a top-level display formula or diagram), which `querySelectorAll` alone would miss.

*Alternatives considered:*
- A generic DOM morph (morphdom-style) that patches attributes and children recursively. It would also keep nested diagrams, but it would compare rendered output with fresh source and need a way to skip KaTeX and SVG subtrees. Top-level keys cover the common case with much less code.
- Emitting a hash per block from the renderer. That changes the shared HTML used by exports, which this change avoids.

### Key a freshly loaded page from the body it was loaded with

A full load runs the math and diagram bootstraps while the page parses, before any preview script can record keys. So on the first update after a load, the coordinator also sends the body that page was loaded with, rewritten the same way. `__md2ApplyContent` parses it, drops the whitespace text nodes that `<main>`'s own markup adds at the start and end, and pairs its nodes with the live ones. If the count or any node's type, name or text differs, the update replaces everything, as before.

The coordinator keeps that body in `loadedBody`: each full load sets it, and it is cleared when an update is sent to the page. An update that still carries it after the page is keyed (two updates prepared before the first was sent) is ignored by the page, because keys from an older body would match stale nodes.

### Stable tokens for local images

`LocalImageHTMLRewriter` gave every image a `UUID` token on every rewrite, so every image block changed on every update. The token is now an HMAC-SHA256 of the file path, keyed by a per-process random secret, as 32 hex characters. The same file gets the same URL in every rewrite, and the URL still does not reveal the path. The handler still serves only the files of the current body, since `setAllowedImages` still replaces the whole map.

### Math: macros and definitions

`RenderedDocument` gains `mathMacros`, the `math-macros:` map the page was built with, and the preview passes it with each update. `__md2ApplyContent` compares it with `__md2InitialMacros` by keys and values (the JSON key order is not guaranteed). When it differs, the new map replaces `__md2InitialMacros` and every formula renders again.

KaTeX writes `\newcommand` and `\def` definitions into the shared `macros` object (`globalGroup: true`), so a formula can depend on an earlier one. `__md2RenderMath` now:

- stores each formula's TeX on its element (`__md2Tex`), so a later pass can render a kept formula again;
- records after a whole-document pass whether the document defines anything (`__md2MathDefines`), by comparing the macros object with a copy of the initial map.

An update renders only the new formulas when the document defined nothing and the new formulas define nothing either. Otherwise, it runs a whole-document pass, which is what every update did before. A formula that failed loses its error class before it renders again.

### Appearance changes

The diagram bootstrap records the appearance it rendered with (`__md2DiagramDark`). When an update finds a different appearance, it replaces everything, as before, so kept diagrams do not keep the old theme.

## Verification

- **New GUI suite, `IncrementalPreviewGUITests`:** it drives a real `MarkdownPreviewView` with `liveUpdate` and checks node identity across updates. Diagrams, formulas and images survive a paragraph edit, including the first edit after a load. Line attributes and gutter numbers follow inserted lines. Macro edits and definition changes re-render formulas that stayed. An appearance change and an unmatched page fall back to a full replacement.
- **Mutations:** forcing a whole-page replacement fails six of the seven tests; dropping the macros fails the F04 test; ignoring the loaded body fails the first-edit tests; cutting the line attributes from the serialized string fails `testTextSpellingALineAttributeStillUpdates`.
- **Unit tests** for `RenderedDocument.mathMacros`, the live-update options and the image token.
- **Suites:** the three non-GUI CI steps pass. The full GUI lane passes the skip check, with one failure, `PDFExportEndToEndVerification.testRealExportProducesValidMultiPagePDF` (no outline in the saved PDF). It fails the same way on `main` on the same machine (macOS 27.2), so it is not caused by this change.
- **Timing (local, not a committed benchmark):** a 23.6 KB body with 12 Mermaid diagrams, 12 formulas and 240 paragraphs, one paragraph edited, median of 5 in an off-screen window. A whole-page replacement takes 6.0 ms in `__md2ApplyContent` and 157 ms until the diagrams settle; the incremental update takes 1.0 ms and 3.2 ms.

## Risks / Trade-offs

- **Each update serializes every top-level node of the new body** to compute keys. That is linear in the body size, like the `innerHTML` parse it already pays, and it replaces the layout and rendering of the whole document.
- **The first update after a load parses the loaded body a second time.** It is one extra parse per load, off the typing path's common case.
- **Documents that define math macros still re-render every formula** on each update, as before. Diagrams and images in them are kept.
- **A broken image stays a placeholder while its block is unchanged.** The preview replaces an image that fails to load with a placeholder. Before, every update made a new `<img>` and tried again; now a remote image that failed offline is tried again only when its block changes or the page reloads. A local file that appears later still shows up: the rewrite only gives an existing file the image scheme, so the block's HTML changes once the file exists.
