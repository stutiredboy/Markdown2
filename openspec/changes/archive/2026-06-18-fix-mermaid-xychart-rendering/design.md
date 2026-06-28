## Context

The Read-mode preview is a single self-contained HTML page emitted by
`MarkdownRenderer`. Diagram blocks become `<div class="diagram diagram-<engine>">`
placeholders that a JS bootstrap renders to SVG in-place (Mermaid 10.9.1, plus
`flow`/`sequence` engines). Because the preview must stay legible in both light
and dark themes, the page's `<style>` block forces diagram geometry to the
foreground color:

```css
.diagram text { fill: var(--text); }
.diagram path, .diagram line, .diagram rect,
.diagram ellipse, .diagram polygon { stroke: var(--text); }
/* Mermaid ships its own theme; let it manage its own colors. */
.diagram-mermaid text { fill: revert; }
.diagram-mermaid path, .diagram-mermaid line, .diagram-mermaid rect,
.diagram-mermaid ellipse, .diagram-mermaid polygon { stroke: revert; }
```

The two `.diagram-mermaid … { … revert; }` rules exist to undo the generic
override for Mermaid, since Mermaid themes its own output. This works for
diagram types (flowchart, sequence, class, …) whose colors come from Mermaid's
**internal `<style>` block**, which is `#<svg-id>`-scoped and therefore wins on
specificity regardless of the outer rule.

It does **not** work for `xychart-beta`. Mermaid draws xychart plot geometry as
drawable elements with per-element `strokeFill`/`strokeWidth`, emitted as SVG
**presentation attributes** (`stroke="…"`) on the `<path>`/`<rect>`, not via the
id-scoped stylesheet. Author CSS outranks presentation attributes, so:

1. `.diagram path { stroke: var(--text) }` would recolor the line — but then
2. `.diagram-mermaid path { stroke: revert }` rolls the value back to the
   user-agent origin. `stroke` has no UA rule and its initial value is `none`, so
   the plot `<path>` ends up `stroke: none` — an invisible line over visible axes.

That is the reported symptom: axes/labels/title present, data series gone.

## Goals / Non-Goals

**Goals:**
- Make `xychart-beta` line and bar series render visibly in the preview.
- Preserve Mermaid's engine-assigned colors generally, whether they arrive via
  the internal stylesheet or via SVG presentation attributes.
- Keep flowchart/sequence/etc. Mermaid output and the `flow`/`sequence` engines
  visually unchanged, including their light/dark legibility.

**Non-Goals:**
- Upgrading or re-vendoring the Mermaid engine.
- Re-theming xychart colors to the preview palette, or adding xychart-specific
  color tuning. Mermaid's default series colors are acceptable.
- Touching the JS bootstrap, placeholder markup, or any non-Mermaid styling.

## Decisions

**Decision: Scope the generic override away from Mermaid instead of reverting it.**
Replace the `.diagram …` selectors with `.diagram:not(.diagram-mermaid) …` for the
`text` fill and the `path/line/rect/ellipse/polygon` stroke rules, and delete the
two `.diagram-mermaid … { revert }` counter-rules entirely.

Rationale: the generic override only ever needed to reach the non-Mermaid engines
(`flow`, `sequence`), which lack their own theming. Never applying it to Mermaid
means there is nothing to revert, so the presentation-attribute stroke that
`xychart-beta` relies on is left intact. This removes the failure mode at its
source rather than patching over it.

Alternatives considered:
- *`stroke: revert-layer` / explicit `currentColor`*: still an override that has to
  guess Mermaid's intended value; brittle across diagram types. Rejected.
- *Drop only the `stroke`/`fill` revert but keep the generic rule*: would leave the
  generic `var(--text)` recoloring Mermaid geometry, changing flowchart edge/label
  colors. Rejected — it alters today's Mermaid appearance.
- *Per-type CSS targeting xychart classes*: couples the preview to Mermaid's
  internal class names and would need revisiting on every engine bump. Rejected.

## Risks / Trade-offs

- **Mermaid geometry no longer forced to `--text`** → In principle a Mermaid
  diagram could now use a color with poor contrast against an unusual background.
  Mitigation: Mermaid's bootstrap already selects its `dark`/`default` theme from
  the preview's color scheme, so its palette is chosen to suit the background;
  this restores Mermaid's intended, theme-aware colors rather than overriding them.
- **Subtle appearance shift for existing Mermaid diagrams** → Because we stop
  forcing `var(--text)`, any element that was previously recolored falls back to
  Mermaid's own value. In practice those values came from Mermaid's id-scoped
  stylesheet (which already won), so the rendered result should be unchanged.
  Mitigation: visually sanity-check a flowchart and a sequence diagram alongside
  the xychart after the change.
