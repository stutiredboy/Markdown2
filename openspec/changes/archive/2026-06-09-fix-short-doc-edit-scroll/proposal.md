## Why

When a document is short enough to fit within the window (it does not fill a
page), switching from preview (Read) mode to editor (Write) mode scrolls the
content upward and out of the visible area, leaving the top of the document —
including its first heading — hidden above the viewport. The user must manually
scroll back up to see content that was fully visible a moment earlier. A
document that fits on screen should never need scrolling, so this is a clear
regression in the mode-switch experience.

## What Changes

- When switching modes, if the destination content fits entirely within the
  viewport (content height ≤ visible height), the destination view must stay
  anchored at the top and must **not** issue any scroll that pushes content
  out of view.
- Make the post-mode-switch scroll offset computation robust against a
  not-yet-settled layout in the freshly created editor view, so a short
  document cannot land at a non-top offset.
- Extract the clamped scroll-offset calculation into a pure, unit-testable
  helper in `MD2Core`, mirroring the existing `ModeSwitchAnchor` helpers.

## Capabilities

### New Capabilities
- `mode-switch-scroll-anchoring`: Preserving the reader's scroll position when
  toggling between Write (editor) and Read (preview) modes, including the rule
  that a document shorter than the viewport stays pinned to the top and is
  never scrolled out of view.

### Modified Capabilities
<!-- None: no existing spec covers cross-mode scroll anchoring. -->

## Impact

- `Sources/MD2App/MarkdownEditorView.swift`: `scroll(to:)`,
  `scrollLineToTop(charRange:in:)`, and `scroll(toFraction:in:)` — guard
  against scrolling when content fits; route offset computation through the
  new helper; ensure layout is settled before measuring geometry.
- `Sources/MD2Core/`: new pure helper for the clamped scroll offset (returns 0
  when content fits the viewport).
- `Tests/MD2CoreTests/`: unit tests for the new helper.
- No change to rendering, file formats, or public document model. Behavior is
  limited to the Read↔Write mode-switch scroll path.
