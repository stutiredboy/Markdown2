## Why

The app can save documents only as Markdown source. Users who want to share a
finished document with people who don't use a Markdown editor (or who want an
archival, print-ready copy) have no way to produce one — they must round-trip
through another tool. Exporting the rendered preview to PDF turns Markdown2 into
a complete authoring-to-delivery tool: what you see in the preview is what you
can hand off.

## What Changes

- Add a **Export as PDF…** (导出为 PDF…) command to the File menu, placed
  directly after **Save As…**, with no default keyboard shortcut.
- The command presents a save panel defaulting to the document's name with a
  `.pdf` extension, then writes a PDF that matches the Read-mode preview —
  including KaTeX math, diagrams (Mermaid/flow/sequence), code highlighting, and
  images referenced by relative paths.
- Export renders the document in a dedicated offscreen web view and waits for
  asynchronous engines (math/diagrams) to settle before producing the PDF, so
  the result is faithful regardless of which editor mode is currently active.
- Output is paginated to fixed A4 pages with print-oriented density, suitable
  for printing and sharing.
- Failures (render timeout, write error) surface through the existing document
  alert mechanism rather than failing silently.

Decision: this is a distinct **export** action, not a new format inside the
existing **Save As…** panel. Save As… continues to write Markdown source and
remains the document's on-disk representation; PDF is a derived artifact that
does not become the document's `fileURL` or clear its dirty state.

## Capabilities

### New Capabilities
- `pdf-export`: Exporting the rendered document to a paginated PDF file from the
  File menu, faithful to the Read-mode preview, with explicit success/failure
  behavior.

### Modified Capabilities
<!-- No existing capability's requirements change. -->

## Impact

- **Menu / commands**: `Sources/MD2App/MD2App.swift` — new File-menu button in
  the save command group.
- **Localization**: `Sources/MD2App/AppSettings.swift` — new `exportPDF`
  `L10nKey` with English and Simplified Chinese strings.
- **Document model**: `Sources/MD2App/DocumentStore.swift` — new `exportPDF()`
  entry point (save panel + invoke the exporter); reuses `rendered.html`,
  `baseURL`, and `flushPendingRender()`.
- **New file**: `Sources/MD2App/PDFExporter.swift` — offscreen `WKWebView` that
  loads the rendered HTML (granting read access to the document directory for
  relative images), waits for engines to settle, probes safe page breaks,
  captures each page-height band with `WKWebView.createPDF(configuration:)`,
  and composes a paginated PDF via `PDFPaginator`.
- **Dependencies**: none new; uses WebKit/AppKit already linked by the app.
- **Out of scope**: page-size/margin configuration UI, headers/footers, and
  exporting to other formats (HTML/DOCX).
