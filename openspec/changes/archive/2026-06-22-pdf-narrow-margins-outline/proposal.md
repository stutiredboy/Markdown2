## Why

The **Export as PDF…** command produces a usable but bare document: its page
margins are wider than necessary (~0.67" all sides), wasting page area and pushing
content down, and the output carries **no outline/bookmarks**, so a long exported
document cannot be navigated by heading in any PDF reader. A document app whose
core artifact is a structured Markdown file should hand off a PDF that is both
space-efficient and navigable by its own heading structure.

## What Changes

- **Narrow the default page margins.** Reduce the exporter's uniform print margin
  from ~0.67" to a narrow ~0.5" (36pt) on every side, so more content fits per page
  while keeping a clean, document-like border. This is the new default geometry;
  no UI toggle is added.
- **Always generate a PDF outline (bookmarks) from the document headings.** Every
  exported PDF SHALL include a hierarchical outline built from the document's `#`…
  `######` headings, nested by heading level, with each entry linking to the page
  where that heading appears. This is on **by default** and unconditional — any
  document that contains headings gets a matching outline; a document with no
  headings simply gets no outline (no error).
- Thread the rendered document's existing `outline: [Heading]` through to the
  exporter and map each heading to its output page using the heading element's DOM
  position discovered during the existing break-probe pass.
- Add regression coverage for the heading→page mapping and outline-tree geometry so
  the navigation cannot silently break.

This change modifies the behavior of the existing `pdf-export` capability only; it
adds no new menu commands or export formats.

## Capabilities

### New Capabilities
<!-- None: both changes extend existing PDF export behavior. -->

### Modified Capabilities
- `pdf-export`: (1) Tighten the existing "Paginated, print-ready output" requirement
  to specify narrow (~0.5") default page margins instead of merely "compact"
  margins. (2) Add a new requirement that the exported PDF always includes a
  navigable outline/bookmark tree derived from the document headings.

## Impact

- **Page geometry**: `Sources/MD2App/PDFExporter.swift` — reduce `printMargin` to
  the narrow value; the printable width/height and band math derive from it
  automatically (`PDFPaginator` is unaffected by the constant change).
- **Outline plumbing**: `Sources/MD2App/DocumentStore.swift` (`PDFExporting`
  protocol + `exportPDF()`) passes `rendered.outline` to the exporter;
  `Sources/MD2App/PDFExporter.swift` collects per-heading DOM offsets in the
  break-probe script, maps each heading to its page band, and writes a hierarchical
  outline into the composed PDF (via PDFKit `PDFOutline`/`PDFDestination`).
- **Heading source**: reuses the existing `RenderedDocument.outline` (`[Heading]`,
  with `id` matching the rendered heading `id` attribute) — no new parsing.
- **Dependencies**: adds `import PDFKit` (system framework, already available on
  macOS); WebKit/AppKit/CoreGraphics already linked. No third-party deps.
- **Tests**: `Tests/` — pure heading→page mapping and outline-nesting helpers.
- **Out of scope**: configurable margin/page-size/orientation UI, headers/footers,
  page numbers, and other export formats — unchanged.
