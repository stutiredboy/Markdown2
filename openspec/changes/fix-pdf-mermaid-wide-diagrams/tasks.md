## 1. Regression coverage (GUI-gated, fail-first)

- [x] 1.1 Add a GUI-gated test in `MermaidOffscreenRenderingTests` that renders the reference diagram (two `graph TD` subgraphs each carrying a long plain-CJK note label) and asserts the emitted SVG's `viewBox` width is bounded below a threshold — the current regression is ~1378 px, so assert well under it (e.g. `< 800`)
- [x] 1.2 Add a GUI-gated test that a long plain-latin node label renders wrapped (bounded width, multiple lines) rather than at its full un-wrapped length
- [x] 1.3 Add a GUI-gated test that the wrap leaves untouched: short labels, an HTML label containing an explicit `<br/>`, an edge label (`-->|label|`), a subgraph title, and a `style`/`classDef` directive

## 2. Implementation

- [x] 2.1 In `MarkdownRenderer.diagramBootstrap`, add a `wrapLongLabels(source)` helper that finds plain-text labels inside `[...]` / `(...)` / `{...}` node containers longer than a threshold and inserts `<br/>` (latin: break at the last space; CJK: break between characters)
- [x] 2.2 Apply `wrapLongLabels` to each Mermaid block's `source` before `mermaid.render`, so the preview and the offscreen PDF/print render share the same wrap behavior
- [x] 2.3 Expose the length threshold and the per-line break budget as named constants with a comment explaining the bounded-width goal

## 3. Verification

- [x] 3.1 Build and run the non-GUI suite (`swift test`) — 430 tests / 55 suites pass
- [x] 3.2 Run the GUI-gated suite (`MD2_RUN_GUI_TESTS=1 swift test --filter MermaidOffscreenRenderingTests --filter PDFExportEndToEndVerification`) and confirm the new assertions pass — 10 mermaid + 8 PDF tests pass
- [ ] 3.3 Manually export the reference diagram to PDF and confirm the diagram text is legible (no longer shrunk to ~6 px), matches the preview, and no diagram type regressed — **not achieved**: the wrap reduces the natural width 1378 → ~1019 px but the diagram is still ~8 px text, and the export reveals a separate, pre-existing squashing bug (the diagram rasterizes ~1 px tall) that this change does not address
