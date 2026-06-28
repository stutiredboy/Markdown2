## Why

In preview mode the rendered content is locked to a narrow 860px column centered in the window, so on the wide displays most people now use, large empty margins flank the text and waste horizontal space. The column should make better use of the available window width while still keeping line length comfortable to read.

## What Changes

- Widen the rendered preview's content column so it uses more of the window's horizontal space on wide displays, replacing the fixed 860px cap with a wider, responsive column.
- Keep the content centered with a maximum width that preserves readable line length on very wide windows (avoid unbounded line length).
- Make the side padding responsive so the gutters scale sensibly between narrow and wide windows instead of staying a fixed 58px.
- Preserve existing behavior on narrow windows: the column still shrinks to fit (no horizontal scrolling of the page) and PDF export is unaffected (it already overrides the column width during capture).

## Capabilities

### New Capabilities
- `preview-layout`: The horizontal sizing of the rendered preview's content column — how wide the readable column is, how it responds to window width, and the centering/gutter behavior.

### Modified Capabilities
<!-- None: the preview content-column width is not currently governed by an existing spec. -->

## Impact

- `Sources/MD2Core/MarkdownRenderer.swift` — the `main` rule in `htmlDocument(body:)` (the column `width`/`max-width`/`padding`).
- No impact on PDF export: `PDFExporter.printStyleScript` already neutralizes the preview column width (`max-width: none; width: 100%`) before capture, so the printed layout is unchanged.
- No API or data changes; this is a presentation/CSS-only change applied to every rendered document (single-pane preview and the preview pane of Side by Side).
