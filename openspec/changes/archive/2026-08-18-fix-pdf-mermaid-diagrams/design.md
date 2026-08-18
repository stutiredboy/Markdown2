## Context

`PDFExporter` renders the preview HTML in an offscreen, window-hosted `WKWebView`, injects a print-density `<style>` override (`printStyleScript`), waits for async diagram rendering to settle, probes safe page-break offsets, captures page-height bands via `createPDF(configuration:)`, and composes them onto fixed-size pages (`PDFPaginator`). `DocumentPrinter` reuses this same exporter for Print.

The preview and HTML export both render diagrams correctly. They differ from PDF/print in one load-bearing way: only the PDF path injects `printStyleScript`, which contains:

```css
svg, canvas, img { max-width: 100% !important; height: auto; }
```

Mermaid 10.9.1 emits each diagram as an `<svg width="100%" style="max-width: <naturalWidth>px" viewBox="…">`. Its self-sizing relies on the pair `width="100%"` (cap at the container) **and** inline `max-width: <naturalWidth>px` (cap at natural size): together they make a small diagram render at natural size and a wide diagram shrink to the column.

The `!important` on `max-width: 100%` overrides the inline `max-width` cap. `width="100%"` then wins and, with `height: auto` and the `viewBox` aspect ratio, the height inflates. Measured in an offscreen `WKWebView` mirroring the exporter:

| Render path | SVG size |
| --- | --- |
| Preview / HTML (no override) | **41 × 218 px** |
| PDF (with `printStyleScript`) | **523 × 2810 px** |

A 3-node flowchart becomes ~5.4× the printable height, so it is sliced across pages and reads as missing.

A second, related defect: the offscreen `WKWebView` follows the system appearance. In Dark Mode it resolves `prefers-color-scheme: dark`, so `--page`/`--text` resolve dark, Mermaid selects its `dark` theme, and the captured bands are dark with light text and light diagram strokes (`fill:#ccc`). Composed onto a white page, the PDF is inverted / low-contrast. Confirmed by probing a forced-dark offscreen window: `body` background `rgb(24,24,27)`, text `rgb(243,244,246)`, Mermaid `fill` `rgb(204,204,204)`.

## Goals / Non-Goals

**Goals:**
- Mermaid diagrams render in exported/printed output at their natural size, identical to the preview.
- Wide Mermaid diagrams still scale down to the printable column and are never clipped.
- Exported/printed output is deterministic: always dark-on-white, independent of the system appearance.
- Non-Mermaid media (`flow`/`sequence` SVG, KaTeX math, images) keep their current fit-to-width behavior unchanged.

**Non-Goals:**
- Re-vendoring or upgrading Mermaid (stays 10.9.1).
- Re-theming Mermaid colors or adding diagram-type-specific CSS beyond the width-cap fix.
- Changing the on-screen preview, HTML export, or the settle/pagination pipeline.

## Decisions

**Decision 1 — Exclude Mermaid SVG from the `max-width: 100% !important` override.**

Change the print override selector so the force-cap no longer reaches Mermaid, while leaving `img`, `canvas`, and non-Mermaid `svg` capped as today. Mermaid's own `width="100%"` attribute already provides the wide-diagram shrink-to-column guarantee, so nothing needs to replace the override for Mermaid.

```css
img, canvas, svg:not(.diagram-mermaid svg) { max-width: 100% !important; height: auto; }
```

Rationale: the `!important` exists to defeat an inline `max-width` that Mermaid sets *on purpose*. For every other element the override is either redundant (the base stylesheet already sets `max-width: 100%`) or still needed for inline-styled images. Scoping it away from Mermaid restores the preview's exact sizing without touching the other paths.

Alternatives considered:
- *Drop `!important` globally* — would restore Mermaid but risks re-enabling an inline `max-width`/inline size elsewhere (e.g. a `height`-only image with inline styles) that the override was written to constrain. Broader blast radius than needed. Rejected.
- *Post-process Mermaid SVG to a fixed pixel width/height* — invasive: it re-implements Mermaid's own layout math and would need re-testing on every diagram type and engine bump. Rejected.
- *Set `width: auto` on Mermaid in print* — `width: auto` on an SVG with only a `viewBox` falls back to the replaced-element default (300px) rather than the natural size, so it does not reproduce the preview. Rejected.

**Decision 2 — Force a light appearance on the exporter's offscreen host window.**

In `PDFExporter.init`, set `hostWindow.appearance = NSAppearance(named: .aqua)` before the web view loads. This makes `prefers-color-scheme` resolve light, so `--page`/`--text` resolve light, Mermaid picks its `default` theme, and every captured band is dark-on-white. `DocumentPrinter` inherits the fix since it constructs the same exporter.

Rationale: paper is white; print output should not depend on the author's macOS theme. Forcing light at the window is a single, well-understood point of control that fixes the color inversion *and* makes the Mermaid theme deterministic, rather than adding per-property CSS overrides that could drift from the preview styles.

Alternatives considered:
- *Print CSS that force light colors* (`color-scheme: light`, explicit `--page`/`--text`) — would fix text/background but leave `prefers-color-scheme: dark` true, so Mermaid would still render its dark theme (light strokes on the now-white page). Would need a second Mermaid-specific override. More moving parts. Rejected in favor of the window appearance, which fixes everything from one point.
- *Keep dark output as an opt-in "dark print"* — out of scope and surprising for a paper artifact. Rejected.

## Risks / Trade-offs

- **Wide Mermaid no longer shrinks if its inline `max-width` were removed by a future Mermaid bump** → Mitigation: the guarantee now rests on Mermaid's stable `width="100%"` attribute; the added GUI regression test asserts both a narrow and a wide flowchart, so any engine change that breaks self-sizing is caught.
- **A Mermaid diagram taller than one page is still an atomic block and may be split as a last resort** → Mitigation: this is pre-existing, unchanged behavior (same as the preview's tall-diagram handling); not introduced by this fix.
- **Forcing light changes the appearance of a print made from a Dark Mode session** → Mitigation: this is the intended, documented behavior — output is paper-like regardless of theme; called out in the spec.
- **Selector `svg:not(.diagram-mermaid svg)` relies on `:not()` with a descendant** → Mitigation: WebKit has supported complex `:not()` since Safari 9 (macOS 14 minimum here is well above); verified in the GUI test that exercises the real override path.
