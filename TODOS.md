# TODOS

Tracked work considered and explicitly deferred from in-flight changes. Each item carries its reasoning so a future picker-upper has the context.

## Number nested preview blocks (list items) in the gutter

**What:** Emit `data-md2-source-line` on regular list items (today only footnote `<li>`s carry it) and render a gutter number beside each `<li>` in the preview.

**Why:** A 60-item list is the same locate problem as a 400-line code block: one number for the whole block, nothing for the items inside. The feature's Open Questions deferred it rather than expanding the renderer mid-feature.

**Current state:** `MarkdownRenderer` stamps top-level blocks only (plus footnote `<li>`s, `MarkdownRenderer.swift:980`); `MetadataInvariantTests` invariant-tests the coverage and documents the footnotes/bibliography wrapper exceptions.

**Pros:** Fills the biggest remaining coverage gap in the preview gutter; the overlay mechanism (direct-children spans) extends naturally to `li` anchors.
**Cons / cost:** Renderer change (Decision 6 of the feature said "no renderer change" — this deliberately revisits that for a scoped case); the metadata invariant corpus and tests need extending; exported-HTML neutrality must be re-verified (attribute-only emission is safe — it ships today for footnotes); an open product call: is a number on every list item signal or noise? (human: ~1-2 days / CC: ~2-3h)

**Depends on:** `add-line-numbers` implemented first; a product decision on per-item density (maybe limit to items above a length threshold, or multi-line items only).

**Start here:** extend the top-level block emitter to stamp `li` elements (mirroring the footnote `li` path at `:980`), update `MetadataInvariantTests`' exception list, then extend `__md2RenderLineNumbers`' eligibility rules to nested `li` anchors.

## Adopt `.gstack/pregate.json` on the base branch

**What:** Add `!.gstack/pregate.json` to `.gitignore` and commit a Swift lane config to `main` (runner `swift test`, `Sources/MD2Core/**` → the test suite, `openspec/**` as an empty lane).

**Why:** `gstack-pregate` reads the base branch's config; this repo ignores all of `.gstack/`, so every `/ship` pre-gate fails `PREGATE_NO_LANE` on a Swift source change and the Swift test lane cannot be inferred. The 2026-10-19 ship ran the pre-gate with `--policy-from head` as a local workaround.

**Current state:** No config on `main`; the local `/ship` run has a working-tree config with `sh -c 'swift test' pregate {files}`.

**Pros:** The ship pre-gate works for every future branch; the test lane is explicit.
**Cons / cost:** A tiny repo config commit plus a `.gitignore` exception; review the lane mapping when test targets change. (human: ~15min / CC: ~5min)

**Depends on:** nothing.

**Start here:** copy the local config, add the `!.gstack/pregate.json` exception, and run `gstack-pregate validate` before committing.
