## Context

The rendered preview HTML is produced by `MarkdownRenderer.htmlDocument(body:)` in `Sources/MD2Core/MarkdownRenderer.swift`. The content column is governed by a single CSS rule:

```css
main {
    box-sizing: border-box;
    width: min(100%, 860px);
    margin: 0 auto;
    padding: 52px 58px 80px;
}
```

`width: min(100%, 860px)` caps the readable column at 860px and centers it. On the wide displays most users have, this leaves large empty margins on both sides. The complaint is that this whitespace is excessive and the preview should use more of the horizontal space.

The same `htmlDocument` output feeds both the on-screen preview and PDF export. PDF export, however, injects `PDFExporter.printStyleScript` before capture, which sets `main { max-width: none !important; width: 100% !important; margin: 0 !important; padding: 0 !important; }`. So the preview column width is purely a preview/on-screen concern; PDF supplies its own page margins and is not affected by changes here.

This is a presentation-only, single-rule CSS change. A design doc is included mainly to record the width/readability trade-off and the chosen values.

## Goals / Non-Goals

**Goals:**
- Make the preview use noticeably more horizontal space on wide displays.
- Keep the text centered and keep a maximum width that preserves comfortable line length on very wide / ultrawide windows.
- Keep responsive behavior on narrow windows (shrink to fit, no horizontal page scroll) and make the side gutter scale with window width.
- Leave PDF export output unchanged.

**Non-Goals:**
- Making the column fully fluid/edge-to-edge with no maximum (rejected — unbounded line length hurts prose readability).
- Adding a user-configurable width setting (out of scope for this change; could be a follow-up if desired).
- Changing fonts, line height, vertical padding, or any block-level styling.
- Changing the Side by Side pane split or the editor pane.

## Decisions

### Decision: Raise the column cap and make padding responsive, keep it centered
Replace the `main` rule with a wider, responsive column:

```css
main {
    box-sizing: border-box;
    width: 100%;
    max-width: 1280px;
    margin: 0 auto;
    padding: 52px clamp(28px, 4vw, 64px) 80px;
}
```

- `width: 100%` + `max-width: 1280px` lets the column fill the window up to a 1280px cap (~49% wider than 860px). At common window widths (≈1280–1680px wide) the column is now near-full instead of a narrow centered strip.
- `margin: 0 auto` keeps the content centered, so on windows wider than 1280px the surplus becomes balanced left/right margins (satisfies the readability cap requirement).
- `padding: 52px clamp(28px, 4vw, 64px) 80px` keeps the vertical padding identical and makes the horizontal gutter responsive: 28px on narrow windows, growing with the viewport up to 64px on wide windows. This satisfies "gutters scale with window width" and avoids text touching the window edge on small windows.

**Why 1280px:** at the 16px base font, 1280px minus ~2×64px padding leaves ~1150px of text — generously wide while still bounded. A hard cap is kept because unbounded line length is a known readability problem. 1280 is the primary tunable: if the owner wants more or less aggression, only this number changes.

**Alternatives considered:**
- *Just bump 860 → ~1100px (`width: min(100%, 1100px)`).* Simplest, but a smaller win on wide displays and keeps the fixed gutter. Rejected in favor of also making padding responsive.
- *Fully fluid (`width: 100%`, no max).* Maximizes space use but produces very long, hard-to-read lines on wide/ultrawide monitors. Rejected.
- *Viewport-proportional width (e.g. `min(100%, max(960px, 85vw))`).* Scales continuously with the window, but on ultrawide displays still yields uncomfortably long lines unless additionally capped — equivalent in practice to a max-width cap, but harder to reason about. Rejected for simplicity.
- *User setting for column width.* More flexible but larger scope (settings UI + persistence). Deferred.

### Decision: Do not touch the PDF export path
`PDFExporter.printStyleScript` already overrides `main` width/padding to `none`/`0` during capture, so the new preview values are irrelevant to PDF. No change is needed there, and the spec asserts PDF output stays identical.

## Risks / Trade-offs

- **Longer lines slightly reduce prose readability at the new max width** → Capped at 1280px (not fluid) and side padding preserved, keeping line length within a comfortable range.
- **Wide tables / code blocks that previously scrolled within 860px now have more room** → This is an improvement (less scrolling); `pre`/`table` keep `overflow-x: auto`, so anything still wider continues to scroll within the column as before. No regression.
- **A user who preferred the narrow column may find the wider one less to taste** → The cap (1280px) is a single, easily tuned value; a configurable setting can be added later if requested.
- **Very wide content blocks in Side by Side's narrower preview pane** → `width: 100%` + `max-width` is responsive, so the column simply tracks the pane width; behavior is the same mechanism as today, just with a higher cap.

## Migration Plan

Single-file CSS edit in `htmlDocument(body:)`; no data, API, or settings migration. Rollback is reverting the one `main` rule. Verify by building and opening a document in preview and Side by Side on a wide window, and by exporting a PDF to confirm unchanged output.

## Open Questions

- Is 1280px the desired cap, or should the column be more aggressive (e.g. 1440px) / fluid for the owner's typical monitor? Default chosen: 1280px; adjustable at implementation time.
