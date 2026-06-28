## Context

PDF export (`Sources/MD2App/PDFExporter.swift` + `PDFPaginator.swift`) renders the
preview HTML in an offscreen `WKWebView` laid out at the **printable width**
(`pageSize.width − left − right ≈ 499pt` for A4 with 48pt margins), injects a
print stylesheet, runs a JavaScript break-probe to find safe split offsets,
captures each page band with `WKWebView.createPDF(configuration:)`, and composes
the bands onto fixed A4 pages with Core Graphics.

Exporting the real document `matrix-cli-security.md` (24 pages) surfaced concrete
defects, confirmed by rendering the output pages to images:

1. **Wide content is clipped at the right margin and lost.** The web view is laid
   out at a *fixed* printable width, but several block types do **not** wrap:
   - Tables are styled `display: block; overflow-x: auto`, so a wide table becomes
     a horizontal-scroll box. There is no scrollbar in a PDF — everything past the
     printable width is simply cut. On page 22 the four-column P3 table lost its
     entire rightmost column (`修复`) and the `问题` column was sliced mid-word.
   - Fenced code is `pre code { white-space: pre }`, so long lines never wrap. On
     page 20 `replace … github.com/golang-jwt/jwt/v4 v4.5.1` was truncated to
     `… github.com/golang-jwt/j`.
   - The capture rect width is `webView.bounds.width` and `composePDF` scales by
     `printableWidth / sourceRect.width = 1`, so overflow is neither captured nor
     scaled — it is discarded.

2. **The bottom line of a near-full page is clipped.** `composePDF` draws each band
   with `drawnHeight = min(sourceRect.height * scale, printableHeight)` and clips to
   that height. When a band is a *maximal* page (its height equals the printable
   height) and the captured page height rounds even slightly above the requested
   band height, the clamp to `printableHeight` shaves the bottom line's descenders.
   On page 19 the last line `修复: 运行时阶段添加:` lost its lower strokes.

3. **Table rows can be sliced across a page boundary.** Because wide tables are
   scroll-blocks, their measured row geometry and the maximal-page boundary
   combine so that a row straddling the boundary is cut horizontally (top of the
   row on one page, nothing on the next). Page 21→22 shows a sliced top row.

These are not visible in the live preview (which has working horizontal scroll and
no pagination), so they only appear in the exported PDF.

## Goals / Non-Goals

**Goals:**
- No exported content is ever clipped horizontally: tables, code blocks, diagrams,
  images, and math all fit within the printable page width.
- No text line or block is sliced at a page boundary, **including the last line of
  a full page**; a row/line/atomic block that fits on a page is kept whole.
- The fix is verifiable in isolation (pagination geometry) and by re-exporting the
  reference document.

**Non-Goals:**
- Scaling wide content down to preserve its original column/line layout. The chosen
  strategy is to **wrap** wide content to full-size, readable text (see Decisions);
  scale-to-fit is explicitly not implemented.
- Any change to the export command, save panel, A4 geometry, margins, settle/timeout
  behavior, image/math/diagram rendering pipeline, or document-state semantics.
- New configuration UI, headers/footers, or other export formats.

## Decisions

### Decision: Make wide content fit by wrapping it within the printable width

The exporter already injects a print stylesheet before capture. Extend it so every
block type that can exceed the layout width is forced to wrap, rather than scroll:

- **Tables**: override the preview's `display: block; overflow-x: auto` with
  `display: table; table-layout: fixed; width: 100%; overflow-x: visible;` and make
  cells wrap (`th, td { word-break: break-word; overflow-wrap: anywhere;
  white-space: normal; }`). Fixed layout makes columns share the page width and the
  cells wrap their content, so the table fills the width exactly and never
  overflows.
- **Code blocks**: `pre { overflow-x: visible; }` and
  `pre code { white-space: pre-wrap; overflow-wrap: anywhere; word-break:
  break-word; }`, so long lines wrap onto the next line instead of being cut.
- **Inline code / long tokens**: `code { overflow-wrap: anywhere; word-break:
  break-word; }` so a long inline token (path/URL) cannot push a line wide.
- **Diagrams / images / math**: `svg, canvas, img, .math-display .katex { max-width:
  100% !important; height: auto; }` and `.math-display { overflow-x: hidden; }` so a
  wide Mermaid SVG or display formula scales to the page width.

Because `overflow-wrap: anywhere` / `word-break: break-word` breaks even otherwise
unbreakable tokens, **nothing can exceed the layout width after this CSS**. The
capture then sees `sourceRect.width == printableWidth`, the existing
`scale = printableWidth / sourceRect.width` stays `1`, and there is no horizontal
clipping to compensate for. This keeps the capture/compose path unchanged for
width and avoids a global down-scale that would shrink all text.

**Why wrap, not scale (user decision):** the user chose full-size, readable text
over preserving wide-table column layout. Wrapping keeps every glyph at the print
base size; the cost is that a very wide table becomes taller (more rows of wrapped
text) and a long code line occupies two visual lines. Scale-to-fit was considered
and rejected as the *general* strategy: a single very wide element would shrink the
entire page's text, and it adds per-element measuring/transform code paths that
wrapping does not need.

### Decision: Scale the blocks that cannot wrap (display math, diagrams) to fit

Two block types cannot be made to wrap: a display-math formula is a single
unbreakable KaTeX box, and a diagram is one SVG. For these, fitting *is* scaling —
there is no other way to avoid clipping. A small JavaScript pass, run in the
settled page just before the break-probe measures it, finds any `.math-display` or
`.diagram` whose `scrollWidth` exceeds its available width and scales its inner
content down (`transform: scale(avail/scrollWidth)`, `transform-origin: left top`)
while reserving the scaled height on the container. This is the narrow,
per-element scaling that the general wrap strategy avoids — applied only where
wrapping is impossible — so ordinary text is never globally shrunk. Verified: a
14-term polynomial that the original export clipped at `a₈x⁸` now renders in full.

An earlier attempt to constrain math with CSS alone (`.katex { max-width: 100% }`
plus `overflow: hidden`) made it *worse* — `max-width` clamps the KaTeX box but
its content does not reflow, so `overflow: hidden` then sliced it. CSS cannot
fit-scale arbitrary unbreakable content; measuring in JS and applying a transform
is required.

### Decision: Reserve a boundary cushion so a band never fills the page to the pixel

The page-bottom clipping (defect 2) is a maximal-page rounding problem: when a
band's height equals the printable height exactly, `createPDF`'s captured page can
round a hair taller and the `min(…, printableHeight)` clamp slices the last line.

Fix: feed `PDFPaginator.bands` (and the break-probe's atomic "fits on a page"
threshold) a single effective content height that is the printable height minus a
small **boundary cushion** (on the order of one line, e.g. ~18–24pt), instead of the
exact printable height. Bands then always end with clearance below the last line,
so capture rounding can no longer clip it. Using the *same* reduced height for the
probe's `maxAtomicHeight` keeps "atomic block fits on a page" consistent with "band
fits on a page", so an atomic block that is kept whole is one a band can actually
hold.

Alternative considered: round band heights down and grow the clip rect by an
epsilon. Rejected — it fights the symptom at compose time and still leaves the band
boundary touching the glyph; a content-side cushion removes the failure class.

### Decision: Correct `composePDF` so it scales/clips to the band, never through content

Rework the per-band draw so the captured page is placed without clamping real
content away:

- Compute `scale = min(printableWidth / sourceRect.width, printableHeight /
  sourceRect.height)` — fit width, and guard the degenerate case where a single
  atomic block taller than a page was captured (then fit height too). For ordinary
  bands `sourceRect.width == printableWidth` and `sourceRect.height ≤
  printableHeight − cushion`, so `scale == 1`.
- Set `drawnHeight = sourceRect.height * scale` (no `min(…, printableHeight)` that
  can clip) and clip to exactly `drawnHeight`, top-aligned. With the cushion this is
  always `≤ printableHeight`, so the clip never cuts a line.

This makes defect 2 and the row-slice tail of defect 3 impossible by construction:
every band ends at a safe break with clearance and is drawn whole.

### Decision: Tables become normal table boxes for the probe, fixing row measurement

Switching tables from scroll-blocks to `display: table` also means the break-probe
measures real `tr` rectangles that share the page width and wrap. Combined with the
cushion, a row that fits a page is atomic and kept whole; only a row genuinely
taller than a page (very rare once wrapped) is split as a last resort — matching the
spec's "atomic block taller than a page MAY be divided" escape hatch.

## Risks / Trade-offs

- **Wrapped code loses its single-line shape** → acceptable and explicitly chosen;
  preserving content beats preserving line breaks, and clipping (the current
  behavior) loses content outright. No continuation marker is added (keeps it simple
  and matches browser print behavior).
- **Very wide tables become tall** → expected consequence of wrapping; the table
  still paginates safely at row boundaries. If a single wrapped row exceeds a page it
  is split as a last resort.
- **Cushion slightly reduces content per page** → at most ~one line per page; a
  negligible page-count increase in exchange for never clipping the last line.
- **`!important` overrides in the print CSS could fight future preview CSS** → scope
  every rule to the export-only injected `#md2-print-overrides` stylesheet (already
  the pattern) so it affects export only, not the live preview.
- **Mermaid SVGs with intrinsic pixel width** → `max-width: 100%; height: auto`
  scales them down to fit; if an SVG sets an explicit `height` that ignores
  `auto`, verify against the reference document during apply.

## Migration Plan

Pure rendering/geometry fix; no data, no persistence, no API surface. Ship in one
change. Rollback is reverting the `PDFExporter`/`PDFPaginator` edits — the export
command and all surrounding behavior are untouched.

## Open Questions

- ~~Exact cushion size~~ — **resolved**: `boundaryCushion = 22pt` (≈ one print line
  at 14px × 1.55). Re-exporting the reference document confirmed the last line of
  full pages is intact with no wasted space.
- ~~Whether diagrams need explicit sizing~~ — **resolved**: `svg { max-width: 100% }`
  plus the JS fit-scale pass handle diagram width; no extra `width: auto` needed.

## Out of scope (pre-existing, separate from clipping)

Verification surfaced that **Mermaid diagrams do not render at all** in the
offscreen export web view (the `.diagram` box stays blank; KaTeX math, by
contrast, renders). This reproduces on the **pre-change** code (confirmed in a
clean worktree at `HEAD`), so it is a pre-existing engine-execution problem, not a
clipping/pagination one — the diagram-fit code added here is correct for when a
diagram *does* render. The reference document `matrix-cli-security.md` contains no
diagrams, so it is unaffected. Fixing offscreen Mermaid execution is a distinct
concern (engine bootstrap/visibility in a window-less `WKWebView`) and belongs in
its own change; it is intentionally not addressed here.
