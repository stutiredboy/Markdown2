## Context

`MarkdownRenderer` (`Sources/MD2Core/MarkdownRenderer.swift`, ~1900 lines) is a
hand-rolled, line-based block renderer. It walks normalised source lines, detects
block starts (fence, table, blockquote, list, math, setext, paragraph…), and
emits HTML, wrapping each block with `taggedWithSourceLines(_:startLine:endLine:)`
so the preview carries `data-md2-source-line` / `data-md2-source-end-line`. Inline
rendering uses a "protector" pipeline (code spans → backslash escapes → math →
entities → autolinks → raw HTML → emphasis/images/links). Task items emit
`data-md2-task-line`.

That metadata is load-bearing: `ModeSwitchAnchor`, `ViewportAnchor`, and
`mode-switch-scroll-anchoring` map preview blocks back to editor lines with it,
and `preview-task-toggle` rewrites a source line from the checkbox's
`data-md2-task-line`. Any future renderer must keep emitting both.

The renderer intentionally does **not** target full CommonMark conformance
(`Docs/MarkdownSupport.md`, "Not Yet Supported"). Its boundaries are discovered
one document at a time — the archive holds standalone fixes for nested lists,
multi-line blockquotes, soft/hard breaks, ordered-list numbering, and inline-math
escapes. There is no corpus, no regression net spanning constructs, and no single
declared contract; tests are curated, fragment-based `.contains()` assertions.
`String.withoutSourceLineMetadata` already exists to strip the metadata for
comparison. The `MD2CoreTests` target currently declares **no** `resources:`.

## Goals / Non-Goals

**Goals:**
- A declared, tiered, machine-checkable compatibility matrix (Supported /
  Best-effort / Out-of-scope) with a validated per-entry schema and pinned
  provenance, authoritative over both the support doc and the dashboard's categories.
- A renderer-wide graceful-degradation guarantee: malformed / out-of-scope input
  never blanks the preview, drops content, or crashes.
- A vendored, offline CommonMark + GFM corpus run as a conformance suite, emitting
  a pass-rate dashboard grouped by matrix construct and tier.
- A checked-in baseline that pins current behaviour both ways (regressions and
  unexpected improvements both fail), as the characterization safety net.
- The source-line / task-line metadata invariant enforced across the whole corpus.

**Non-Goals:**
- **Not** chasing 100% CommonMark conformance — pass-rate is a *tracked number*,
  not a target. Several divergences (e.g. soft-break → `<br>`) are intentional
  product choices, recorded as known divergences.
- **Not** swapping in a third-party parser or AST in this change. AST-ification is
  a constrained future direction, gated on preserving the metadata invariant.
- **Not** fixing every boundary the dashboard reveals here. Fixes are follow-on
  changes, each carrying its own rendering-spec delta (e.g. `list-rendering`).
- **No** change to in-scope, well-formed document output.

## Decisions

**Decision: Vendor the reference `spec.json` corpus as test resources.**
CommonMark ships its reference tests as `spec.json` (`markdown` / `html` /
`example` / `section`); GFM publishes the same shape. Vendoring keeps the suite
hermetic and offline — matching the app's bundled-asset philosophy (KaTeX and
diagram engines are already bundled). Requires adding a `resources:` entry to the
`MD2CoreTests` target in `Package.swift`. *Alternative — shell out to `cmark` /
`commonmark.js`:* rejected; adds a runtime/toolchain dependency and non-hermetic
tests.

**Decision: Compare under documented normalisation, not byte-equality.**
Our output intentionally diverges (soft-break `<br>`, injected `data-md2-*`
attributes, slug `id`s). Comparison strips `data-md2-*` (reusing
`withoutSourceLineMetadata` plus an attribute scrubber) and applies a minimal,
documented HTML normalisation (collapse insignificant inter-block whitespace)
before matching the reference. *Alternative — exact byte match:* rejected; marks
nearly everything failing and buries signal.

**Decision: Baseline records the matrix's four-value reference relationship, kept
distinct from tier.** Each corpus example is pinned as `reference-match`,
`intentional-divergence`, `known-incomplete`, or `unsupported` — the same baseline
vocabulary the matrix declares, deliberately separate from the construct's product
tier (a Supported construct may still carry an intentional divergence such as
soft-break → `<br>`). This is the characterization mechanism and the machine twin
of the human matrix. It fails on regression *and* on unexpected improvement, so
neighbouring boundaries cannot drift silently (the exact failure mode the archive
demonstrates) and genuine fixes get locked in deliberately. *Alternative — a
three-state `pass` / `divergence` / `unsupported` baseline:* rejected; it conflates
intentional product divergence with known-incomplete coverage, which the matrix
spec explicitly forbids. *Alternative — assert only a known-good subset:* rejected;
lets adjacent constructs regress unnoticed.

**Decision: Dashboard as a report-emitting test, not a separate binary, grouped by
matrix construct + tier.** Lowest friction; runs under `swift test` in CI, writes a
report (Markdown table + machine-readable JSON) to a known artifact path, and prints
a summary line. Results aggregate by the matrix construct identifier and tier (not
only raw upstream `section` strings); Markdown2-extension constructs absent from the
corpus are excluded from the upstream pass-rate and covered by their local tests
instead. *Alternative — a `Scripts/` SwiftPM executable:* heavier; can be added later
if a standalone CLI is wanted.

**Decision: Enforce graceful degradation as a corpus-wide invariant, with minimal
defensive renderer fixes.** The corpus is a large supply of edge / malformed
input; asserting "preview body non-empty, no thrown error, no authored text
dropped" across all of it is a strong robustness net. Where an example currently
blanks/drops/crashes, fix defensively at the seam (e.g. unterminated-fence
handling) — small, localised, invisible to valid documents.

**Decision: The matrix is a checked-in, machine-checkable data artifact — the
single source of truth.** Rather than prose maintained twice, the matrix is a
structured file (default: JSON, decoded with Swift `Codable`, matching the corpus
format and adding no dependency; YAML is the fallback if hand-editing ergonomics
win). Each entry carries the full schema the matrix spec mandates — stable
identifier, origin (CommonMark / GFM / Markdown2 extension), covered corpus
`section`(s), one support tier, declared rendering behaviour + expected HTML shape,
boundary/fallback behaviour, baseline relationship, and the `Docs/MarkdownSupport.md`
label — plus pinned provenance (corpus source, version/commit, licence, matrix
schema version). A matrix-validator test enforces totality over corpus sections (an
unknown or renamed section fails until classified), classification of every
advertised Markdown2 extension, and per-entry schema completeness.
`Docs/MarkdownSupport.md` is then derived from or verified against the matrix so the
two cannot drift. *Alternative — a prose-only matrix with a tier-agreement test:*
rejected; it cannot enforce per-entry schema, provenance, or corpus totality, which
the matrix spec now requires.

## Risks / Trade-offs

- **[Corpus licence / provenance]** → Record upstream source, pinned spec version,
  and licence in the corpus directory; CommonMark spec & tests are openly licensed.
- **[Normalisation hides a real diff]** → Keep normalisation minimal and
  documented; the report stores actual vs expected HTML for every failure so a
  human can inspect; the baseline records *why* each divergence is accepted.
- **[Baseline diff noise]** → Partition the baseline by `section`; only tier
  transitions change it; failure messages name the exact examples and how to update.
- **[Metadata invariant exposes blocks that lack it]** → Those are real scroll-sync
  gaps; fix by adding the (invisible, non-breaking) attribute, or record a narrow,
  justified exception list the test checks.
- **[Scope creep into boundary fixes]** → Explicit Non-Goal; the dashboard reveals,
  follow-on changes fix. This change's renderer edits are graceful-degradation
  safety only.
- **[Pass-rate misread as a quality KPI]** → Document that it tracks divergence
  from reference, not a 100% goal; intentional product divergences are labelled.
- **[Matrix drifts from the corpus over time]** → The matrix-validator test fails CI
  on any unclassified or renamed corpus section, so totality is enforced mechanically
  rather than by reviewer diligence.
- **[Tier and reference-match conflated]** → Kept as two separate fields (support
  tier vs baseline relationship); the validator rejects entries that omit either.

## Migration Plan

Additive and reversible. Steps: add corpus resources + the `Package.swift`
resources entry; add the conformance runner, baseline, dashboard, metadata-invariant
and graceful-degradation tests; apply minimal defensive renderer edits; restructure
`Docs/MarkdownSupport.md` around the matrix. Roll back by removing the new
test files/resources and reverting the doc and any defensive edit. Verify with
`swift test` (suite runs, dashboard emitted, baseline green) plus a manual check
that known-boundary documents (nested lists, multi-line blockquote, task lists)
still render and still toggle.

## Open Questions

- Dashboard artifact location: a build artifact under `tmp/` plus a committed
  `Docs/CompatibilityMatrix.md` summary, or the report in `Docs/` directly?
  (Resolve in tasks.)
- GFM scope for the first cut: core tables / task-lists / strikethrough only, or
  also the autolink-extension section? (Start with core GFM; expand later.)
