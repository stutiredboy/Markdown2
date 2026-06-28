## Why

PDF export already produces clean, paginated, outlined output — but its page
geometry is hard-wired to A4 with narrow margins, and there is no way to add
page numbers, headers, or footers. The project is moving from "a Markdown
previewer" toward "writing to delivery," where the author controls how the
finished document looks and can hand off more than just a PDF. Today that ceiling
blocks common needs (Letter paper, landscape diagrams, page numbers for print,
a portable single-file HTML to email). A pre-existing defect compounds this:
Mermaid diagrams render in the live preview but come out **blank** in the
offscreen export/print web view (documented in the archived
`fix-pdf-export-clipping/design.md`), so any document with a Mermaid diagram
exports incorrectly. This change turns export from a fixed pipeline into a
configurable "export & print configuration center," and fixes the diagram defect
so the configurable output is also a faithful one.

## What Changes

- **Fix offscreen diagram rendering.** Mermaid (and, by audit, flow/sequence)
  diagrams render reliably in the offscreen export/print `WKWebView`, so exported
  and printed output matches the live preview. Export waits for diagram engines
  to actually finish instead of relying solely on a fixed settle delay.
- **Configurable page geometry.** PDF export and Print gain a configurable page
  **size** (A4, Letter, Legal, …), **orientation** (portrait/landscape), and
  **margins** (preset Normal / Narrow / Wide / None, plus custom). A4 + narrow
  stays the default, so existing behavior is unchanged unless the user opts in.
  When printing, the print dialog opens pre-configured with the profile's page
  size so the user does not have to manually align the system paper size.
- **Page numbers + headers/footers.** Optional page numbers and header/footer
  text drawn into the page margins, with left/center/right zones and a small set
  of substitution tokens (document title, date, page number, total pages).
- **Export & print configuration center.** A persisted "export profile" (in
  Settings, localized EN/zh-Hans) holds these choices and is applied to every PDF
  export and Print, so the user configures once and every hand-off is consistent.
- **Self-contained HTML export.** A new "Export as HTML…" command writes a single
  portable `.html` file with CSS, math/diagram engines, and images inlined — no
  external files or network needed to open it.
- **Optional DOCX/EPUB via Pandoc.** When a Pandoc binary is detected, "Export as
  DOCX…" / "Export as EPUB…" become available and delegate to Pandoc; when it is
  absent these stay disabled with clear guidance. The native pipeline stays
  lightweight and dependency-free by default.

## Capabilities

### New Capabilities
- `export-configuration`: The persisted, localized export/print profile — page
  size & orientation presets, margin presets and custom margins, page numbers,
  and header/footer text with substitution tokens — surfaced in Settings and
  applied to PDF export and Print.
- `html-export`: Export the rendered document as a single self-contained HTML
  file with all assets (styles, KaTeX/diagram engines, and images) inlined so the
  file is portable and opens offline.
- `document-conversion`: Optional DOCX/EPUB export delegated to an external
  Pandoc binary, available only when Pandoc is detected and degrading gracefully
  (disabled affordance + guidance) when it is not.

### Modified Capabilities
- `pdf-export`: Page geometry becomes configurable (size, orientation, margins)
  instead of fixed A4/narrow, with A4/narrow as the default; the PDF gains
  optional page numbers and headers/footers; and the offscreen export/print
  render reliably produces Mermaid/flow/sequence diagrams that were previously
  blank.

## Impact

- **Code (modified):** `PDFExporter` (parameterize page geometry; draw page
  numbers/headers/footers in `composePDF`; await diagram completion before
  capture), `PDFPaginator` (geometry derived from configuration rather than
  constants), `DocumentPrinter` (thread configuration through; synchronize the
  print dialog's paper size with the profile), `DocumentStore` (read the
  profile; add HTML/DOCX/EPUB export entry points and extend
  `isProducingDerivedArtifact` guarding to cover all export types),
  `AppSettings`/`SettingsView` (profile model, persistence, UI, and new
  localized strings), `MD2App`/menu (new export menu items, enabled state),
  `MarkdownRenderer`/diagram bootstrap (expose a diagram-completion signal the
  exporter can await).
- **Code (new):** an export-profile model type, a self-contained HTML builder
  (asset/image inlining), and a Pandoc detection + invocation helper.
- **Dependencies:** no new bundled dependencies; DOCX/EPUB relies on an
  *external, user-installed* Pandoc and is inert without it.
- **Behavior/compatibility:** defaults preserve current output; new persisted
  `UserDefaults` keys for the profile; the `PDFExporting`/`DocumentPrinting`
  protocols gain a configuration parameter (internal API).
