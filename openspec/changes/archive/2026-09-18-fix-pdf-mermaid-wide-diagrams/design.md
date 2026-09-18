## Context

`MarkdownRenderer.diagramBootstrap` renders each Mermaid block by reading the fenced source and passing it straight to `mermaid.render`:

```js
var source = el.textContent;
mermaid.render("md2-mermaid-" + idx, source).then(...)
```

Mermaid 10.9.1 lays each node out at the full un-wrapped length of its label. For CJK text this is unbounded, because CJK has no word-boundary characters and Mermaid's `flowchart.wrappingWidth` only takes effect for labels it classifies as "markdown" — a plain label such as `特点：迭代更快、业务隔离、…` is not markdown, so it is never wrapped. Measured on the reference diagram (two subgraphs, each carrying a full-width Chinese note), the emitted SVG has `viewBox` width **1378 px** against a ~523 px printable column, so the PDF export scales it to 0.38× and every glyph lands at ~6 px. The live preview shows the same over-wide layout, just less badly (its column is ~860 px).

The archived `fix-pdf-mermaid-diagrams` fix is load-bearing and remains correct — the sizing/inflation and Dark Mode fixes are unchanged. This change addresses a distinct, residual defect: the diagram's *natural* width is itself unreasonable because labels never wrap.

## Goals / Non-Goals

**Goals:**
- Bound a Mermaid node's label width so a diagram with long CJK (and long latin) labels lays out at a reasonable natural width instead of the longest label's full length.
- Keep the wrap behavior identical in the live preview and the offscreen PDF/print render (same `diagramBootstrap`), preserving the "export matches preview" invariant.
- Preserve the diagram's structure and semantics: only the *display* of long labels changes, never the graph topology, edge labels, styling directives, or subgraph titles.

**Non-Goals:**
- Re-vendoring or upgrading Mermaid (stays 10.9.1).
- Changing Mermaid's graph layout (subgraph placement / direction) — that is the engine's choice and is out of scope.
- Wrapping short labels, labels that already contain HTML/markup, edge labels, `classDef`/`style`/`linkStyle` directives, or subgraph titles.
- Changing the on-screen reading width, the print overrides, or the pagination pipeline.

## Decisions

**Decision 1 — Wrap long plain-text node labels by inserting `<br/>` into the Mermaid source before render.**

In `diagramBootstrap`, transform each block's `source` before `mermaid.render` so long node labels are broken into lines. Mermaid with `htmlLabels: true` (the default, and already active here via `securityLevel: "loose"`) renders `<br/>` as a line break, and its layout then sizes the node to the widest line rather than the full run.

Rationale: it is the only lever the app controls. Mermaid's own `flowchart.wrappingWidth` was verified not to wrap a plain CJK label (the label never enters the markdown path that applies it), and there is no `markdownAutoWrap`/force-markdown config in 10.9.1. A post-render CSS `word-break` cannot help either, because Mermaid computes node geometry *before* the SVG is styled.

The transformation is deliberately conservative — it only rewrites a label that is:
- inside a square (`[ … ]`), round (`( … )`), or curly (`{ … }`) node-label container, **and**
- longer than a threshold (default ~20 code points), **and**
- plain text: it contains none of `<`, `>`, `&`, `|`, `"`, backticks, or markdown emphasis (`*`/`_`), so it cannot be an HTML or markdown label and cannot be an edge, a subgraph title, or a directive.

For each such label, break every ~N code points: latin scripts break at the last space before the limit; CJK breaks between characters (CJK allows a break between any two characters). The resulting source is otherwise byte-for-byte identical.

Alternatives considered:
- *Set `flowchart.wrappingWidth` / `htmlLabels`* — verified ineffective: wrapping is gated on Mermaid's internal "is markdown" detection, which a plain CJK label fails.
- *Upgrade Mermaid to a version with CJK-aware auto-wrap* — the archived change already scoped Mermaid upgrades out; a version bump risks regressions across every diagram type and needs re-testing. Rejected.
- *Force labels through the markdown path (e.g. wrap every label in markdown syntax)* — fragile and semantically surprising; a label like `**` or `` ` `` would be mis-parsed. Rejected.
- *Post-render CSS `word-break` on `.diagram-mermaid foreignObject`* — the node box is already sized to the full label, so the text would overflow the box. Rejected.

**Decision 2 — Wrap at a fixed code-point budget, not a pixel measurement.**

The wrap width is expressed as a character budget (default 20 code points) rather than pixels, so it applies uniformly in the preview and the offscreen export without needing to know the column width at render time. This bounds a single node to roughly the length of a short sentence (~320 px at Mermaid's default 16 px font), which is narrow enough to make the reference diagram's text legible in the PDF and short enough to remain readable in the preview.

## Risks / Trade-offs

- **A conservative regex mis-classifies or skips a label** → Mitigation: only plain-text labels in the three common containers are touched, with a whitelist of forbidden characters; anything ambiguous is left unchanged (a skipped label is the current, correct-but-wide behavior, not a regression). GUI tests cover the reference diagram plus an HTML-label and an edge-label case to lock the boundary.
- **`<br/>` changes how a label is interpreted** → Mitigation: `securityLevel: "loose"` + `htmlLabels: true` are already active, so `<br/>` is a line break, never shown literally. The wrapping only targets labels the heuristics identify as plain text.
- **The fix reduces, but does not eliminate, extreme width** → the diagram's *layout* (subgraph placement, direction) is Mermaid's and is not touched; a diagram whose structure is genuinely wide still scales down, only now from a smaller natural width. Noted in the spec as the bounded-width guarantee, not a hard "always fits" guarantee.
- **Label length threshold / break budget are magic numbers** → exposed as named constants in `diagramBootstrap` with a comment; the GUI test asserts the outcome (bounded natural width) rather than the constant, so it can be tuned without breaking the contract.
