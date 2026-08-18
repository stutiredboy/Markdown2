## Why

Exporting a document that contains Mermaid diagrams (e.g. a `mermaid` flowchart) to PDF produces broken output — the diagram is stretched to the full printable width and inflated to several pages tall, so it effectively disappears. HTML export and the live preview render the same diagrams correctly. The cause is a print-time CSS override that strips Mermaid's own width cap, and the bug is compounded by the offscreen render following the system color scheme, so a Dark Mode user also gets an inverted, low-contrast PDF.

## What Changes

- Fix the PDF/print CSS override so it no longer forces `max-width: 100% !important` onto Mermaid SVG, which currently overrides Mermaid's inline `max-width` and inflates the diagram (measured: a 3-node flowchart renders 41×218 px in the preview but 523×2810 px under the PDF override).
- Make the offscreen PDF/print render deterministic: force a light appearance on the exporter's host window so the captured output is always dark-on-white regardless of the system appearance, and Mermaid renders with its light `default` theme.
- Keep wide Mermaid diagrams scaling down to the printable width (Mermaid's own `width="100%"` attribute already provides this; the fix must not regress it).
- Preserve the existing scaling behavior for non-Mermaid media (`flow`/`sequence` SVG, KaTeX math, images) — these must still fit the page width and not be clipped.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `pdf-export`: the requirement that exported/printed diagrams match the preview and fit the printable width is strengthened to guarantee Mermaid diagrams keep their natural size (scaled down only when wider than the printable column) and that exported output is always rendered light, independent of the system appearance.

## Impact

- `Sources/MD2App/PDFExporter.swift` — the `printStyleScript` CSS override (targeted selector change) and the offscreen `hostWindow` appearance (forced light). `DocumentPrinter` reuses `PDFExporter`, so print output is fixed by the same change.
- `Tests/MD2CoreTests/MermaidOffscreenRenderingTests.swift` and `Tests/MD2CoreTests/PDFExportEndToEndVerification.swift` — extend the GUI-gated coverage to assert a Mermaid SVG keeps natural dimensions under the print override and that exported output is light in both system appearances.
- No dependency or vendored-asset changes; Mermaid stays at 10.9.1.
