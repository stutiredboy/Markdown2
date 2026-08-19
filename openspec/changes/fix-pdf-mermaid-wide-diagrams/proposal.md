## Why

The archived `fix-pdf-mermaid-diagrams` change correctly fixed the `max-width: 100% !important` inflation and the Dark Mode inversion in PDF/print export, and its tests still pass. But a Mermaid diagram whose nodes carry long CJK labels (e.g. a subgraph note with a full-width Chinese sentence) still comes out unreadable in the exported PDF: Mermaid lays the diagram out at the label's full un-wrapped width — measured at **1378 px** natural width for the reference diagram below — and the exporter scales that down to the ~523 px A4 printable column, shrinking every glyph to ~6 px. The same diagram is needlessly wide in the preview too. The root cause is that Mermaid 10.9.1 does not wrap plain CJK node labels: its `flowchart.wrappingWidth` only applies to markdown-formatted labels, and CJK text has no word boundaries to break on, so the diagram's natural width is pinned to the longest label.

## What Changes

- Make the diagram render bootstrap wrap long node labels — including CJK text — to a bounded width before handing the source to Mermaid, so a diagram lays out at a reasonable natural width instead of ballooning to the longest label's un-wrapped length.
- Apply the wrap identically in the live preview and the offscreen PDF/print render, preserving the existing invariant that exported diagrams match the preview.
- Add GUI-gated regression coverage that a Mermaid diagram with long CJK labels renders at a bounded natural width and remains legible under the PDF print override.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `diagram-rendering`: add a requirement that Mermaid diagrams wrap long node labels (including CJK text) to a bounded width, so a diagram's natural width does not balloon to the longest label's un-wrapped length.

## Impact

- `Sources/MD2Core/MarkdownRenderer.swift` — the `diagramBootstrap` JavaScript, which currently passes each Mermaid block's source through `mermaid.render` unchanged; it gains a label-wrapping pre-processing step.
- `Tests/MD2CoreTests/MermaidOffscreenRenderingTests.swift` — GUI-gated tests asserting a long-label Mermaid diagram renders at a bounded natural width and, under the print override, stays legible.
- No dependency or vendored-asset changes; Mermaid stays at 10.9.1.
