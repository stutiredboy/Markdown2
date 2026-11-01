## Why

The preview gutter numbers top-level blocks only, so a long list gets one number for all its items. `TODOS.md` ("Number nested preview blocks (list items) in the gutter") recorded this as the biggest coverage gap left in the preview gutter. The item that tells a reader where a line lives is the one they cannot locate.

The same gap affects mode switches. A tight list's items had no source span, so a switch from Read to Write interpolated across the whole list, and an uneven list (one long item among short ones) put the editor many lines away from the item the reader was on.

The product decision (2026-11-01) is to number multi-line items only: a number on every one-line item would turn a long list into a column of digits.

## What Changes

- **Every list item carries its source span.** The renderer stamps `data-md2-source-line` on each `<li>` of a regular list, nested ones included, and `data-md2-source-end-line` when the item spans several source lines. The span runs from the item's own line through the last line of its deepest, latest descendant and that descendant's continuation. Footnote items already carried a start line and are unchanged.
- **The gutter numbers multi-line items.** `__md2RenderLineNumbers` also numbers each item of a top-level list that carries an end line, nested items included, at the top of the item. A line is shown once: a list's first item shares the list's number. Lists inside blockquotes, alerts and footnotes stay unnumbered, like the other blocks those wrappers hold. Numbers are collected and then sorted by position.
- **Mode switches land on the item.** The anchor scripts already pick the deepest element carrying a span, so a list item near the top of the preview becomes the anchor with no script change.
- **Tests:**
  - `MetadataInvariantTests`: every list item in the conformance corpus carries a start line, and exact spans for nested and continued items.
  - `LineNumberGutterGUITests`: multi-line items are numbered at their tops (nested ones too, quoted ones not, no duplicate), and clicking an item's number sends its line.
  - `ReadingImprovementsGUITests`: a Read → Write switch with a list item at the top of the preview opens the editor on that item.
  - Existing nesting assertions read through `withoutSourceLineMetadata`. A negative assertion that the new attribute would have made vacuous now checks that no `<li` exists.
- **Docs:** both READMEs; remove the TODO.

**Non-goals:**

- One-line items stay unnumbered.
- No change to the click-to-jump bridge: an item's number is a span in the same layer, and clicks reach the bridge as for any block.
- No change to footnote or bibliography items.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `line-number-display`: the preview also numbers multi-line items of top-level lists.
- `mode-switch-scroll-anchoring`: every list item exposes its source span, so a list item can be the anchor.

## Impact

- `Sources/MD2Core/MarkdownRenderer.swift`: `buildList` stamps each item.
- `Sources/MD2App/MarkdownPreviewView.swift`: `__md2RenderLineNumbers`.
- Tests: `MetadataInvariantTests`, `LineNumberGutterGUITests`, `ReadingImprovementsGUITests`, `MarkdownRendererTests`, `BlockMarkerScalarTests`.
- `README.md`, `README.zh-CN.md`, `TODOS.md`.
- Rendered HTML changes only by attributes on `<li>`. Exported HTML carries them as it already carries block metadata; line numbers themselves still never reach exports.
