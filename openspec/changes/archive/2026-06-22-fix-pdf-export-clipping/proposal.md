## Why

The new **Export as PDF…** command produces output that silently loses content.
Any block wider than the printable column — wide tables, long code-block lines,
wide diagrams — is clipped at the right page margin, so whole table columns and
the tail of code lines simply vanish from the PDF (e.g. a four-column table loses
its rightmost column; `…golang-jwt/jwt/v4 v4.5.1` becomes `…golang-jwt/j`). A
secondary defect clips the bottom line of a near-full page so its descenders are
sliced at the page boundary. A PDF that drops content without warning is worse
than no export at all, because the loss is invisible until someone reads the
printed copy.

## What Changes

- Wide content SHALL be made to **fit the printable page width** instead of being
  clipped. No table, code block, diagram, image, or math block may extend past the
  right page margin in the exported PDF; content that would overflow is wrapped or
  scaled down so it is fully visible.
- Fix the **page-bottom clipping**: a line of text or a block that ends near the
  bottom of a page SHALL be rendered whole, never sliced by a few pixels at the
  band boundary. Captured-band geometry is corrected so the last line on a page is
  not cut.
- Tighten **cross-page table handling**: a table row that fits on a page is kept
  whole; rows are never sliced horizontally across the page boundary.
- Add regression coverage for the pagination/width-fitting geometry so these
  defects cannot silently return.

This change modifies the behavior of the existing `pdf-export` capability only;
it adds no new menu commands, options, or formats.

## Capabilities

### New Capabilities
<!-- None: this is a fix to existing PDF export behavior. -->

### Modified Capabilities
- `pdf-export`: Add a requirement that exported content fits within the printable
  page width (wide tables/code/diagrams are wrapped or scaled, never clipped), and
  strengthen the existing "Paginated, print-ready output" requirement so that
  page-boundary slicing of text lines and table rows — including the bottom line of
  a full page — is prohibited in practice, not just in principle.

## Impact

- **Rendering geometry**: `Sources/MD2App/PDFExporter.swift` — the print-style
  injection (make wide blocks fit the layout width) and the band-capture /
  Core-Graphics composition (correct height/clip math so the last line is not
  clipped; handle content laid out wider than the printable width by scaling the
  composed page down to fit).
- **Pagination math**: `Sources/MD2App/PDFPaginator.swift` and the break-probe
  script — ensure safe breaks remain dense and bands never exceed the printable
  height after the boundary fix.
- **Tests**: `Tests/` — extend the existing `PDFPaginator` coverage for the
  corrected band geometry (no band exceeds the printable height; width-fit scaling
  is computed correctly).
- **No new dependencies**; WebKit/AppKit/CoreGraphics already linked.
- **Out of scope**: page-size/margin/orientation UI, headers/footers/page numbers,
  and other export formats — unchanged from the original PDF-export scope.
