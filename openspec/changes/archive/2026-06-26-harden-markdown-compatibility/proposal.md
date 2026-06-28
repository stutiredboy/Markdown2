## Why

`MarkdownRenderer` is a hand-rolled, line-based renderer that deliberately does
not target full CommonMark conformance. Its real boundaries surface one document
at a time: the archive shows repeated one-off fixes for list nesting, multi-line
blockquotes, soft/hard line breaks, ordered-list numbering, and inline-math
escapes. Each fix landed without a shared safety net, so the next imported
document can re-break a neighbouring edge case. When a user imports existing
Markdown, *compatibility* — does my document look right? — drives trust far more
than any new feature. We need the renderer's behaviour to be **declared**,
**measured**, and **pinned**, so boundaries are stable and regressions are caught
before release instead of by users.

## What Changes

- Introduce a **declared compatibility matrix** that classifies each CommonMark /
  GFM construct as **Supported**, **Best-effort**, or **Out-of-scope**, and states
  the renderer's defined boundary behaviour for each. This becomes the single
  source of truth that `Docs/MarkdownSupport.md` reflects.
- Guarantee **graceful degradation**: out-of-scope or malformed input renders as
  readable text and never blanks the preview, drops document content, or crashes —
  generalising the existing diagram "fall back to raw text" behaviour into a
  documented, tested, renderer-wide invariant.
- Vendor a **CommonMark / GFM test corpus** (the reference `spec.json` example
  format) and run it against the renderer as a categorised conformance suite.
- Produce a **compatibility dashboard**: a generated report of pass-rate per
  construct category, so the boundary is a visible, tracked number rather than
  tribal knowledge.
- Add **characterization tests** that pin the renderer's *current* output on the
  corpus, so any future change (including a parser swap) that shifts a boundary
  fails loudly and on purpose.
- Pin the **source-line / task-line metadata invariant**: every block the corpus
  renders must carry `data-md2-source-line`/`data-md2-source-end-line`, and every
  task item must carry `data-md2-task-line`. This guards scroll-sync and task
  toggling now, and constrains the mid-term AST/parser direction so it cannot
  silently break them.
- This change is **non-breaking** for in-scope, well-formed documents: it declares
  and pins existing behaviour and adds tooling. It does not rewrite the renderer.
  Individual boundary *fixes* the dashboard motivates are follow-on changes, each
  carrying its own spec delta.

## Capabilities

### New Capabilities
- `markdown-compatibility-matrix`: The tiered, versioned support contract
  (Supported / Best-effort / Out-of-scope) for CommonMark and GFM constructs,
  including the defined boundary behaviour per construct and the renderer-wide
  graceful-degradation guarantee. It is authoritative over `Docs/MarkdownSupport.md`.
- `markdown-conformance-suite`: The vendored CommonMark/GFM corpus, the categorised
  conformance dashboard (pass-rate per category), the characterization tests that
  pin current boundary output, and the source-line/task-line metadata invariant
  enforced across every corpus block.

### Modified Capabilities
<!-- None. This change is additive: it declares, measures, and pins existing
     rendering behaviour rather than changing any current spec requirement.
     Boundary fixes the dashboard reveals will be separate changes, each modifying
     the relevant rendering spec (e.g. list-rendering, line-break-rendering). -->

## Impact

- Code: `Sources/MD2Core/MarkdownRenderer.swift` — defensive hardening only, to
  guarantee graceful degradation (no blanking / no dropped content / no crash) on
  out-of-scope and malformed input. No public API change.
- Build: `Package.swift` — add a `resources:` entry to the `MD2CoreTests` target so
  the vendored corpus `spec.json` files are bundled for the suite (the test target
  currently declares no resources).
- Tests: new `Tests/MD2CoreTests/Corpus/` resources (CommonMark + GFM `spec.json`),
  a conformance runner, characterization tests, and a metadata-invariant test that
  extends the existing `SourceLineMetadataTests` guarantees across the corpus.
- Tooling: a dashboard generator (script under `Scripts/` or a report-emitting
  test) that writes a pass-rate report grouped by matrix construct and tier.
- Docs: restructure `Docs/MarkdownSupport.md` into / alongside the tiered
  compatibility matrix.
- No dependency on a third-party parser is added in this change; AST-ification or
  adopting a mature parser is recorded as a constrained future direction, gated on
  preserving the metadata invariant.
