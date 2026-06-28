## 1. Fix the preview diagram CSS

- [x] 1.1 In `Sources/MD2Core/MarkdownRenderer.swift`, scope the generic diagram
  legibility rules away from Mermaid: change `.diagram text { fill: var(--text) }`
  to `.diagram:not(.diagram-mermaid) text`, and change the
  `.diagram path, .diagram line, .diagram rect, .diagram ellipse, .diagram polygon { stroke: var(--text) }`
  group to `.diagram:not(.diagram-mermaid) path, …` (same five selectors).
- [x] 1.2 Delete the now-unnecessary counter-rules:
  `.diagram-mermaid text { fill: revert; }` and
  `.diagram-mermaid path, …, .diagram-mermaid polygon { stroke: revert; }`.
  Keep/adjust the explanatory comment so it states that Mermaid manages its own
  colors and the legibility override is scoped to non-Mermaid engines.

## 2. Tests

- [x] 2.1 In `Tests/MD2CoreTests/DiagramRenderingTests.swift`, add a test on the
  emitted preview CSS asserting the legibility override is scoped with
  `.diagram:not(.diagram-mermaid)` and that no `stroke: revert` / `fill: revert`
  rule remains for `.diagram-mermaid`.
- [x] 2.2 Run `swift test` and confirm the new test plus the existing
  `DiagramRenderingTests` suite pass.

## 3. Manual verification

- [x] 3.1 Build and open a document containing the `xychart-beta` block from
  `啤酒游戏-案例解答_Codex.md`; confirm in Read mode that the "订单" and "库存"
  line series render visibly with axes, ticks, title, and labels.
- [x] 3.2 Confirm a Mermaid flowchart and a Mermaid sequence diagram still render
  with their expected colors, and that a `flow` / `sequence` (non-Mermaid)
  diagram is still legible in both light and dark appearance.
