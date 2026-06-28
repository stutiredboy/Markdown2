## Context

PDF export (`Sources/MD2App/PDFExporter.swift` + `PDFPaginator.swift`) renders the
preview HTML in an offscreen `WKWebView` laid out at the printable width, injects a
print stylesheet, runs a JavaScript break-probe to find safe page-split offsets,
captures each page band with `WKWebView.createPDF(configuration:)`, and composes
the bands onto fixed A4 pages with Core Graphics (`composePDF`).

Two gaps motivate this change:

1. **Margins are wider than needed.** `PDFExporter.printMargin = 48pt` (~0.67") is
   applied uniformly. The printable width/height (`printableWidth`,
   `printableHeight`) and all band math derive from it, so a single constant governs
   the geometry. The user wants narrower margins to use more of the page.

2. **No outline/bookmarks.** `composePDF` emits a flat page tree with no document
   outline, so a long export cannot be navigated by heading. The pieces needed
   already exist: `RenderedDocument.outline` is `[Heading]` (each with `id`, `level`,
   `title`), and the rendered HTML emits each heading as `<h{level} id="{slug}">`
   where the `id` equals `Heading.id` (confirmed in `MarkdownRenderer`). What is
   missing is (a) passing the outline to the exporter, (b) mapping each heading to
   its output page, and (c) writing a hierarchical outline into the PDF.

`exportPDF()` in `DocumentStore` already flushes the pending render and holds the
`RenderedDocument`, so the outline is available at the call site. The `PDFExporting`
protocol currently passes only `html`/`baseURL`.

## Goals / Non-Goals

**Goals:**
- Default export uses narrow (~0.5") margins on every side, with the printable area
  recomputed automatically from the single margin constant.
- Every export with headings produces a hierarchical PDF outline whose entries are
  nested by heading level and link to the correct page; a heading-less document
  still exports cleanly with no outline.
- The heading→page mapping and outline-nesting logic are pure and unit-testable,
  independent of WebKit/AppKit.

**Non-Goals:**
- Any UI to configure margins, page size, orientation, or to toggle the outline —
  the outline is unconditional and the margin is a fixed new default.
- Headers/footers, page numbers, a printed table-of-contents page, or named PDF
  destinations beyond what an outline needs.
- Changes to pagination safety (line/row/atomic-block splitting), the print
  stylesheet, settle/timeout behavior, or document-state semantics.
- Other export formats.

## Decisions

### Decision: Narrow the margin to 36pt (0.5") via the existing constant

Set `PDFExporter.printMargin = 36` (0.5", matching the familiar "Narrow" preset).
Because `margins = PDFPaginator.Margins(uniform: printMargin)` and every derived
value (`printableWidth`, `printableHeight`, `pageContentHeight`, the layout width,
and `composePDF`'s placement) reads from it, this one change widens the content
column and lengthens the page band consistently — no other geometry edit is needed.
`PDFPaginator` is untouched (it takes `maxBand`/margins as inputs).

**Why 36pt:** it is a recognizable, conservative "narrow" value that still leaves a
clean border and binding-safe edge, and it is large enough that WebKit band capture
keeps working unchanged. Alternatives considered: 24pt (~0.33") — usable but visibly
tight and risks edge glyphs against the trim; 0pt — rejected, no border at all.
The value remains a single named constant so it is trivial to retune.

### Decision: Map each heading to a page by probing its DOM offset during the break-probe

The break-probe script already walks the rendered DOM and returns the document
`height` plus safe `breaks`. Extend its return payload with a `headings` array:
for each `id` in the document outline, look up the element (`document.getElementById`)
and record its top offset in document pixels (`getBoundingClientRect().top +
scrollY`). Headings with no matching element (defensive) are skipped.

On the Swift side, after `PDFPaginator.bands(...)` produces the page bands, compute
each heading's page index as the band whose `[top, top+height)` range contains the
heading's Y offset (the same coordinate space the bands use). This is pure index
math over `(headingOffset, bands)` and is extracted into a testable helper.

**Why probe the DOM rather than estimate from source lines:** the heading's pixel
position depends on rendered layout (wrapped text, images, math, diagrams), which
only the laid-out web view knows. The `Heading.line` (source line number) cannot be
converted to a reliable Y offset. Reusing the existing single probe pass avoids a
second round-trip into the web view.

### Decision: Write the outline with PDFKit (`PDFDocument` + `PDFOutline`) after composing

`composePDF` produces PDF `Data` with Core Graphics. Rather than build the outline
inline with `CGPDFContextSetOutline` (a single flat `CFDictionary` tree with
manual destination rects), load the composed `Data` into a `PDFDocument`, build a
`PDFOutlineRoot`, and attach a `PDFOutline` node per heading with a
`PDFDestination(page:at:)` pointing at the heading's page and an approximate
top-of-heading point. Nesting is done by walking the heading list with a stack keyed
on `level`: each heading becomes a child of the nearest preceding heading of a
shallower level, else a child of the root. Finally write the document's
`dataRepresentation()` to the destination.

**Why PDFKit over `CGPDFContextSetOutline`:** PDFKit's `PDFOutline`/`PDFDestination`
gives a clean hierarchical API and correct page-object destinations without
hand-encoding the PDF outline dictionary and number-tree; the cost is one extra
load/serialize of an already-in-memory `Data`, which is negligible for export. PDFKit
is a first-party macOS framework already available — no third-party dependency.
Alternative considered: `CGPDFContextSetOutline` during composition — avoids the
re-load but requires manually constructing the nested `kCGPDFOutline*` dictionary and
per-page destination rects, which is more error-prone for hierarchical nesting.

### Decision: Outline is unconditional; no outline when there are no headings

The feature is "on by default" with no toggle. The exporter builds the outline
whenever the passed `outline` is non-empty. An empty outline (no headings) means no
`PDFOutlineRoot` is attached and the plain composed `Data` is written as-is — the
export still succeeds. This satisfies "默认务必生成书签/大纲" while keeping a
heading-less document valid.

### Decision: Thread the outline through `PDFExporting.export`

Change the protocol method to
`export(html:outline:baseURL:completion:)` and have `DocumentStore.exportPDF()` pass
`rendered.outline`. This keeps the exporter self-contained (it owns mapping +
outline writing) and keeps the heading source as the single already-rendered
`RenderedDocument.outline`, with no re-parsing of Markdown in the export path.

## Risks / Trade-offs

- **Heading destination y-position is approximate** → PDFKit `PDFDestination`
  carries a point; viewers commonly scroll to the page top regardless. We compute a
  best-effort within-page offset from `headingOffset − band.top` (scaled like the
  band) so the jump lands near the heading; exactness is not required for navigation.
  Mitigation: page-level correctness is the spec guarantee; the point is a refinement.

- **A heading sitting exactly on a band boundary could map to the adjacent page** →
  Mitigation: band ranges are half-open `[top, top+height)` and headings are block
  starts that the break-probe already treats as safe break points, so a heading tends
  to begin a band rather than straddle one; off-by-one is at most one page and is
  covered by mapping unit tests.

- **PDFKit re-serialization changes the bytes** → loading and re-writing via
  `PDFDocument` may rewrite the PDF structure. Mitigation: this is exactly PDFKit's
  supported use; verify the re-saved PDF still renders all pages (the existing
  pagination/clipping guarantees are visual and re-checked on the reference doc).

- **Narrower margins push content closer to the trim** → 36pt keeps a safe border;
  if any edge glyph touches the trim in verification, the constant is trivially
  retunable. The boundary cushion at the bottom is unchanged, so last-line clipping
  protection still holds.

- **Duplicate or non-ASCII heading slugs** → slugs come from the same `Slugger` used
  by the renderer (already deduplicated and matching the DOM `id`), so
  `getElementById` resolves each uniquely; titles in the outline use `Heading.title`
  (display text), independent of the slug.

## Migration Plan

Pure rendering/geometry + output-metadata change; no data, persistence, or
user-facing API beyond the internal `PDFExporting` protocol signature. Ship in one
change. Rollback is reverting the `PDFExporter`/`DocumentStore` edits (restore the
48pt margin and the prior `export(html:baseURL:completion:)` signature); all
surrounding behavior is untouched.

## Open Questions

- **Exact narrow-margin value** — proposed 36pt (0.5"); confirm against a re-export
  of the reference document that the border looks right and nothing touches the trim.
  Retunable via the single `printMargin` constant.
- **Within-page destination offset precision** — page-level accuracy is guaranteed;
  decide during apply whether the best-effort y-offset is worth keeping or whether a
  simpler page-top destination is preferable after visual check in a PDF reader.
