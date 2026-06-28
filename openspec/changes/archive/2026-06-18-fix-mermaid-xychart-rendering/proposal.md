## Why

Mermaid `xychart-beta` charts render their axes, title, and labels but show **no
plotted lines or bars** in the Read-mode preview — the data series are invisible,
so the chart looks empty (see the retailer order/inventory `xychart-beta` block in
`啤酒游戏-案例解答_Codex.md`). The preview's own CSS is the culprit: a rule meant
to "let Mermaid manage its own colors" actually strips the stroke/fill off any
Mermaid element that is colored via SVG presentation attributes rather than
Mermaid's internal id-scoped stylesheet — which is exactly how `xychart-beta` (and
some other newer diagram types) draw their plot geometry.

## What Changes

- Stop the generic `.diagram` legibility overrides (`stroke: var(--text)` on
  `path/line/rect/ellipse/polygon`, `fill: var(--text)` on `text`) from applying
  to Mermaid diagrams at all, so Mermaid's own colors — whether set via its
  internal stylesheet *or* via SVG presentation attributes — survive untouched.
- Remove the `.diagram-mermaid { stroke: revert; fill: revert; }` counter-rules.
  These were an attempt to undo the generic override, but `revert` resolves a
  presentation-attribute stroke back to the SVG initial value (`none`), which is
  what blanks the `xychart-beta` plot lines.
- Net effect: `xychart-beta` line and bar series become visible, while existing
  Mermaid diagrams (flowchart, sequence, etc.) and the non-Mermaid engines
  (`flow`, `sequence`) keep their current appearance and legibility.

## Capabilities

### New Capabilities

<!-- None: this is a rendering fix to an existing capability. -->

### Modified Capabilities

- `diagram-rendering`: Mermaid diagrams SHALL preserve the colors their engine
  assigns, including data-series geometry colored via SVG presentation attributes
  (e.g. `xychart-beta` plot lines and bars), so those series render visibly. The
  preview's legibility overrides apply only to the non-Mermaid engines.

## Impact

- Code: `Sources/MD2Core/MarkdownRenderer.swift` — the preview `<style>` block
  (the `.diagram` / `.diagram-mermaid` stroke & fill rules around lines
  1299–1316). CSS-only change; no Swift logic, JS bootstrap, or bundled engine
  asset is touched.
- Engine assets unchanged (Mermaid stays at the vendored 10.9.1).
- No new dependencies, no data/settings migration, no public API change.
- Tests: `Tests/MD2CoreTests/DiagramRenderingTests.swift` — add coverage asserting
  the generic stroke/fill override is scoped away from `.diagram-mermaid` and that
  the `revert` counter-rules are gone.
