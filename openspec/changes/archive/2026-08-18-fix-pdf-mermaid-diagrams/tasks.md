## 1. Regression coverage

- [x] 1.1 Add a GUI-gated test asserting a narrow Mermaid flowchart keeps natural SVG dimensions under the PDF print override (mirror the exporter's `printStyleScript` injection), guarding against the `max-width: 100% !important` inflation
- [x] 1.2 Add a GUI-gated test asserting a wide Mermaid diagram still scales down to the printable column and is not clipped
- [x] 1.3 Extend the offscreen-render coverage to assert the exporter's host window resolves `prefers-color-scheme: light` (and Mermaid renders its `default` theme) even when the window appearance is forced dark

## 2. Implementation

- [x] 2.1 In `Sources/MD2App/PDFExporter.swift`, scope the `printStyleScript` media override to `img, canvas, svg:not(.diagram-mermaid svg)` so Mermaid's inline `max-width` cap is preserved
- [x] 2.2 In `PDFExporter.init`, set `hostWindow.appearance = NSAppearance(named: .aqua)` so the offscreen render is deterministic light (fixes dark-mode inversion and forces Mermaid's `default` theme)

## 3. Verification

- [ ] 3.1 Build and run the non-GUI suite (`swift test`)
- [ ] 3.2 Run the GUI-gated tests (`MD2_RUN_GUI_TESTS=1 swift test --filter MermaidOffscreenRenderingTests --filter PDFExportEndToEndVerification`) and confirm the new assertions pass
- [ ] 3.3 Manually export a document containing a Mermaid flowchart to PDF in both Light and Dark Mode and confirm the diagram appears at natural size, dark-on-white, and is not clipped
- [ ] 3.4 Manually confirm `flow` and `sequence` diagrams and KaTeX math still render and scale correctly in the exported PDF (regression check for the selector change)
