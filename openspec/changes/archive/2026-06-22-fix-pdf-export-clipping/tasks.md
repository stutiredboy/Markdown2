## 1. Make wide content fit the page width (no horizontal clipping)

- [x] 1.1 In `Sources/MD2App/PDFExporter.swift`, extend `printStyleScript` so tables fit the printable width: override the preview's `display: block; overflow-x: auto` with `table { display: table !important; table-layout: fixed; width: 100%; overflow-x: visible; }`.
- [x] 1.2 Make table cells wrap: `th, td { word-break: break-word; overflow-wrap: anywhere; white-space: normal; }`.
- [x] 1.3 Make fenced code wrap instead of scroll: `pre { overflow-x: visible; }` and `pre code { white-space: pre-wrap; overflow-wrap: anywhere; word-break: break-word; }`.
- [x] 1.4 Break long inline tokens (paths/URLs): `code { overflow-wrap: anywhere; word-break: break-word; }`.
- [x] 1.5 Scale wide diagrams/images/math to the page: `svg, canvas, img { max-width: 100% !important; height: auto; }` and `.math-display { overflow-x: hidden; } .math-display .katex { max-width: 100%; }`.
- [x] 1.6 Keep all rules scoped to the injected `#md2-print-overrides` stylesheet so the live preview CSS is unaffected.
- [x] 1.7 Scale unwrappable blocks (display math, diagrams) to fit: a JS pass in the break-probe finds any `.math-display`/`.diagram` whose `scrollWidth` exceeds its available width and applies `transform: scale(...)` (origin top-left) with the scaled height reserved, so wide math/diagrams are never clipped. (CSS-only `max-width`/`overflow:hidden` cannot do this — it slices KaTeX.)

## 2. Reserve a boundary cushion so a band never fills the page to the pixel

- [x] 2.1 In `PDFExporter`, define a single `effectivePageContentHeight = printableHeight - boundaryCushion` (cushion ≈ one print line, e.g. ~20–24pt) and use it both for the break-probe `maxAtomicHeight` and for the `maxBand` passed to `PDFPaginator.bands`, so "atomic block fits a page" and "band fits a page" stay consistent.
- [x] 2.2 Verify the break-probe still emits dense safe breaks and that no band height can reach the full printable height.

## 3. Fix `composePDF` geometry so content is never clamped away

- [x] 3.1 Replace the width-only scale + `min(sourceRect.height * scale, printableHeight)` clamp with `scale = min(printableWidth / sourceRect.width, printableHeight / sourceRect.height)` (fit width, with a height guard for a single atomic block taller than a page).
- [x] 3.2 Draw each band at `drawnHeight = sourceRect.height * scale`, top-aligned, clipping to exactly the drawn size so the bottom line is never sliced.
- [x] 3.3 Extract the scale/fit computation into a pure, dependency-free helper (e.g. on `PDFPaginator`) so it can be unit-tested without WebKit.

## 4. Confirm table-row pagination after the layout change

- [x] 4.1 With tables now `display: table`, confirm the break-probe measures real `tr` rectangles; ensure a row that fits a page is treated as atomic and kept whole, and only a row taller than a page is split as a last resort.

## 5. Tests

- [x] 5.1 In `Tests/MD2CoreTests/PDFPaginatorTests.swift`, add cases asserting no returned band height exceeds `maxBand` for representative inputs (the invariant the compose math relies on).
- [x] 5.2 Add tests for the extracted scale/fit helper: `scale == 1` when source width equals printable width and height fits; scale shrinks to fit when a band is wider or taller than the page; never returns a scale that leaves content larger than the page.
- [x] 5.3 Keep the existing `PDFPaginatorTests` green (boundary, safe-break snapping, runaway guard).

## 6. Verify against the reference document

- [x] 6.1 Re-export `/Users/tiredboy/Downloads/matrix-cli-security.md` and confirm: the four-column P3 table shows all columns within the page width (now p22, with the previously-lost 修复 column wrapping); the `replace … golang-jwt/jwt/v4 v4.5.1` line is complete (wrapped, not truncated); the `修复: 运行时阶段添加:` last line is intact with no clipped descenders. ✓ Verified via the real `PDFExporter` against the document.
- [x] 6.2 Spot-check a math-heavy / long-token document: wide display math now scales to fit (a 14-term polynomial that was clipped at `a₈x⁸` renders in full) and a long unbreakable inline token wraps. NOTE: Mermaid diagrams do not render in the offscreen export web view — confirmed pre-existing (reproduces on `HEAD` in a clean worktree), a separate engine-execution issue out of scope for this clipping change; the reference document has no diagrams.
- [x] 6.3 Run `swift build` and `swift test`; confirm the suite passes.
