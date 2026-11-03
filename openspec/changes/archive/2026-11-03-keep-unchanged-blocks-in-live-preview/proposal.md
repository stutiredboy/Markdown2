## Why

In Side by Side, every edit replaces the whole preview. `__md2ApplyContent` sets `<main>`'s `innerHTML` to the new body, then renders every formula and every diagram again. A document with diagrams shows it on each typing pause: every Mermaid, flow and sequence diagram falls back to its hidden placeholder and fades in again, wherever the edit was. Local images reload too, because each body rewrite gives every image a new random token, so each `src` changes.

The same path keeps stale math macros (F04 in `Docs/Review-2026-10-15.md`). The swap re-renders formulas with the `math-macros:` front matter that the page loaded with. After an edit to that field, the preview keeps showing the old definitions until the next full load.

## What Changes

- **Keep the blocks that did not change.** A live update compares the new body with the content on the page, one top-level node at a time. Nodes whose HTML is unchanged stay in the page, with their rendered formulas, diagrams and images. Only new or changed nodes are inserted and rendered. Source-line numbers alone do not count as a change: a kept node takes the new `data-md2-source-line`, `data-md2-source-end-line` and `data-md2-task-line` values, so the gutter, mode-switch anchoring and task toggles keep pointing at the right lines.
- **Give the first update after a page load the body the page was loaded with,** so the nodes of a freshly loaded page can be matched too. When they cannot be matched, the update replaces everything, as it does today.
- **Give each local image file the same token across rewrites**, derived from the file path and a per-process secret, so an unchanged image keeps its URL. The scheme handler still serves only the files of the current body.
- **Carry `math-macros:` through live updates.** The preview passes the current macros with each update. When they change, every formula renders again with them.
- **Keep math definitions working.** When the document defines macros in its math (`\newcommand`, `\def`), or a new node starts doing so, every formula renders again in document order, as today. Formulas keep their TeX source so a re-render does not need new nodes.
- **Re-render everything when the appearance changes** between updates, so kept diagrams do not keep a light or dark theme that no longer applies. This matches today's behavior.

**Non-goals:**

- No change to how the renderer splits blocks or to the HTML it produces. Exports, print and the first page load are unchanged.
- Diffing stays at the top level of `<main>`. A diagram inside a list item or blockquote is rendered again when anything in that list or blockquote changes.
- A diagram whose own source is being edited still renders again on each update, and falls back to its placeholder while it does.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `split-view-editing`: live re-renders keep the blocks that did not change, with their rendered content.
- `math-rendering`: `math-macros:` edits reach the Side by Side preview without a reload.

## Impact

- `Sources/MD2App/MarkdownPreviewView.swift`: `__md2ApplyContent` and the coordinator's live-update path.
- `Sources/MD2Core/MarkdownRenderer.swift`: the math and diagram bootstraps accept a list of roots and keep formula sources.
- `Sources/MD2Core/RenderedDocument.swift`: the rendered document carries its math macros.
- `Sources/MD2App/LocalImageAccess.swift`: stable image tokens.
- `Sources/MD2App/ContentView.swift`: passes the macros to the preview.
- Tests: a new GUI suite for live updates, and unit tests for the macros and image tokens.
