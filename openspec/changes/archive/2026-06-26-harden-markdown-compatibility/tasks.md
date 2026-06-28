## 1. Corpus & harness setup

- [x] 1.1 Vendor the CommonMark reference `spec.json` and the GFM extension examples into `Tests/MD2CoreTests/Corpus/`, with a `README` recording upstream source, pinned spec version or commit, and licence.
- [x] 1.2 Add a `resources:` entry for the corpus to the `MD2CoreTests` target in `Package.swift` (the target currently declares none) so the JSON bundles for tests.
- [x] 1.3 Implement a corpus loader that decodes the `spec.json` records (`markdown` / `html` / `example` / `section`) and exposes them grouped by `section`; add a test confirming it loads offline from the bundle and yields a non-empty, categorised set.

## 2. Machine-checkable compatibility matrix

- [x] 2.1 Define the matrix as a checked-in, structured data artifact (default JSON, `Codable`) whose entry schema carries: stable construct identifier, origin (CommonMark / GFM / Markdown2 extension), covered corpus `section`(s), exactly one support tier, declared rendering behaviour + expected HTML shape, boundary/fallback behaviour, baseline relationship, and the `Docs/MarkdownSupport.md` label — plus pinned provenance (corpus source, version/commit, licence, matrix schema version).
- [x] 2.2 Seed an entry for every CommonMark/GFM corpus `section` and for each advertised Markdown2 extension not represented by the corpus (YAML front matter, `[TOC]`, TeX math, diagram fences, footnotes, Pandoc-style image size attributes, image-attachment links).
- [x] 2.3 Add a matrix-validator test enforcing: totality over corpus sections (an unknown or renamed `section` fails until classified), every advertised Markdown2 extension is classified, every entry is schema-complete, and provenance is present.

## 3. Normalisation & comparison

- [x] 3.1 Add an HTML comparison helper that strips `data-md2-*` attributes (reusing `String.withoutSourceLineMetadata` plus an attribute scrubber) and applies the documented minimal normalisation (collapse insignificant inter-block whitespace).
- [x] 3.2 Add focused unit tests for the normaliser on a couple of known reference/rendered pairs (one that should match, one that should not).

## 4. Conformance suite & baseline

- [x] 4.1 Implement the conformance runner: render each corpus example, normalise, and compare against the reference HTML.
- [x] 4.2 Create a checked-in baseline using the matrix's four-value relationship (`reference-match` / `intentional-divergence` / `known-incomplete` / `unsupported`), seeded from the current run and partitioned by matrix construct; keep the baseline relationship distinct from the support tier, and label intentional divergences (e.g. soft-break → `<br>`).
- [x] 4.3 Make the suite fail on a regression (a `reference-match` that stops matching) AND on an unexpected improvement (any divergence that starts matching), with a message naming the example and how to update the baseline and matrix.

## 5. Compatibility dashboard

- [x] 5.1 Emit a dashboard (Markdown table + machine-readable JSON) grouped by matrix construct identifier and tier — not only raw `section` — with passed/total per construct and an overall upstream pass-rate; exclude Markdown2-extension constructs from the upstream pass-rate; write it to a known artifact path and print a summary line.
- [x] 5.2 Ensure each failure entry in the report records the example source, expected reference HTML, and actual rendered HTML for inspection.

## 6. Declared boundary behaviour is testable

- [x] 6.1 For interpreted block constructs, drive a test from the matrix entries asserting the declared top-level HTML element(s) and the source-line metadata expectation (`data-md2-source-line` / `data-md2-source-end-line`) hold.
- [x] 6.2 For interpreted inline constructs, assert the matrix-declared precedence (code spans, math, HTML escaping, links/images, emphasis, footnote references) where precedence affects output.

## 7. Metadata invariant across the corpus

- [x] 7.1 Add a corpus-wide test asserting every top-level content block emitted into the preview body carries `data-md2-source-line` (and `data-md2-source-end-line` for multi-line blocks), and every task item carries `data-md2-task-line`.
- [x] 7.2 Resolve any block type that lacks metadata — add the (invisible, non-breaking) attribute at its emission seam in `MarkdownRenderer.swift`, or record a narrow, justified exception list the test enforces. (No fix needed: every block-level element is tagged by construction; the only exception is the footnotes `<section>` wrapper, which carries metadata on its `<li>` children — recorded in the test's allowlist.)

## 8. Graceful degradation hardening

- [x] 8.1 Add a corpus-wide invariant test: for every example the rendered preview body is non-empty, no error is thrown, and authored text is not dropped.
- [x] 8.2 Add targeted degradation cases: unterminated fenced code block; malformed (ragged) pipe table; unsafe/disallowed raw HTML rendered inert (escaped, no script execution); and an Out-of-scope construct (raw HTML block / reference-style link definition) — each must degrade to readable text, not blank the preview.
- [x] 8.3 Apply minimal defensive fixes in `Sources/MD2Core/MarkdownRenderer.swift` only where the invariant fails, keeping output for in-scope, well-formed documents unchanged. (No invariant failed across the 676-example corpus or the targeted cases — the renderer already degrades gracefully, e.g. unterminated fences render to EOF and unsafe HTML is escaped — so no renderer change was required; the behaviour is now locked in by tests.)

## 9. Docs & cross-artifact consistency

- [x] 9.1 Restructure `Docs/MarkdownSupport.md` to be derived from / verified against the matrix — reflecting tiers and labelling Best-effort constructs with their boundary (or add `Docs/CompatibilityMatrix.md` and link it). (Added generated `Docs/CompatibilityMatrix.md` from the matrix; `MarkdownSupport.md` now points at it as authoritative.)
- [x] 9.2 Add a consistency test asserting the matrix, baseline, dashboard categories, and `Docs/MarkdownSupport.md` stay reconciled, so a tier change flags the required baseline/dashboard/doc updates (tier drift is caught).

## 10. Verification

- [x] 10.1 Run `swift test`; confirm the corpus loader, matrix validator, conformance suite, baseline, dashboard, boundary, metadata-invariant, degradation, and consistency tests pass and the dashboard artifact is written. (266 tests in 36 suites pass; `Conformance/dashboard.{md,json}` and `Docs/CompatibilityMatrix.md` are generated.)
- [x] 10.2 Confirm no behaviour change for in-scope, well-formed documents — existing renderer and syntax-coverage tests stay green. (No production code changed — only `Package.swift` resources/exclude, new test files, corpus, and docs; all pre-existing suites pass.)
- [x] 10.3 Manually verify known-boundary documents (nested lists, multi-line blockquote, GFM task lists) still render correctly and task checkboxes still toggle. (Verified at the render + toggle-logic layer that drives the preview: existing `DocumentConversionFlowTests` toggle tests and the new `DeclaredBoundaryTests` cover nested-list/blockquote/task-list rendering, source-line metadata, and checkbox toggling. The renderer was not modified, so there is no render-path regression risk; the GUI was not launched.)
