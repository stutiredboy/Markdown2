# TODOS

Tracked work considered and explicitly deferred from in-flight changes. Each item carries its reasoning so a future picker-upper has the context.

## Headless-GUI CI lane for `MD2_RUN_GUI_TESTS`

**What:** Add a macOS GUI-capable CI runner that runs `MD2_RUN_GUI_TESTS=1 swift test` on every PR.

**Why:** All regression guards for the PDF/print Mermaid fix (and the existing offscreen/E2E tests in `Tests/MD2CoreTests/`) are GUI-gated and skipped by plain `swift test`. CI never runs them, so a silent regression — dark/inverted PDFs, disappearing Mermaid diagrams, clipped flow/sequence/KaTeX media — lands green unless a human ran the GUI suite. The fixes fail SILENTLY (no error thrown), which is exactly the failure class CI-blindness makes dangerous. The `settings-window-presentation` guard from `fix-settings-window-on-launch` adds a second reason: all its behavioral evidence was gathered on macOS 26, and this lane — landing on `macos-15` runners, the same image `release.yml` builds on — is the planned place to verify the suppression behavior on macOS 15 itself.

**Current state (the in-scope guard shipped with the fix):** A pre-ship checklist note in CLAUDE.md's testing section plus load-bearing comments at the two silent-failure lines in `PDFExporter.swift` (the `printStyleScript` selector and `hostWindow.appearance = .aqua`). These rely on humans following the note.

**Pros:** Every PR automatically runs the silent-failure guards; no reliance on human memory.
**Cons / cost:** Real macOS CI infra — a self-hosted runner with a window-server session, or a macOS-cloud runner; non-trivial setup and maintenance. (human: ~1-2 days / CC: ~30min)

**Depends on:** nothing blocking; pure CI infrastructure work, independent of any code fix.

**Start here:** pick a runner strategy (self-hosted mac with a `loginwindow`/`launchctl` GUI session vs. macOS-cloud), wire `MD2_RUN_GUI_TESTS=1` into the test step, and gate merge on it.

## Click a line-number gutter number to jump to that line

**What:** Make gutter numbers interactive. In the editor, clicking a number selects that source line and scrolls it into view; in the preview, clicking a block's number opens/selects that line in the editor pane (relevant in Side by Side and on mode switch).

**Why:** Completes the "locate" story the line-numbers feature starts. Preview numbers are block-start annotations by design (a 400-line code block shows one number), so precise in-block location has no affordance today; click-to-jump is the deferred follow-up named in the feature's proposal and Open Questions.

**Current state:** The `add-line-numbers` change ships gutters as display-only (`pointer-events: none` in the preview; plain drawing in the editor inset). No interaction surface exists.

**Pros:** Turns passive numbers into navigation; directly answers "I see line 214 in the preview, take me there"; small AppKit hit-test + focus-routing change.
**Cons / cost:** New interaction semantics must coexist with existing editor gestures (Esc, find, mode shortcuts — the reason the feature deferred it); preview-side click needs a focus handoff from WKWebView to the editor. (human: ~2-4h / CC: ~30-60min)

**Depends on:** `add-line-numbers` implemented and archived (the gutter geometry and preview spans are the substrate).

**Start here:** editor side: hit-testing `x < textContainerInset.width` in `MarkdownSourceTextView` (mouseDown override, mirroring the existing `performKeyEquivalent` interception pattern); preview side: make spans `pointer-events: auto` with a JS bridge to the coordinator, reusing the existing `evaluateJavaScript` round-trip pattern.

## Number nested preview blocks (list items) in the gutter

**What:** Emit `data-md2-source-line` on regular list items (today only footnote `<li>`s carry it) and render a gutter number beside each `<li>` in the preview.

**Why:** A 60-item list is the same locate problem as a 400-line code block: one number for the whole block, nothing for the items inside. The feature's Open Questions deferred it rather than expanding the renderer mid-feature.

**Current state:** `MarkdownRenderer` stamps top-level blocks only (plus footnote `<li>`s, `MarkdownRenderer.swift:980`); `MetadataInvariantTests` invariant-tests the coverage and documents the footnotes/bibliography wrapper exceptions.

**Pros:** Fills the biggest remaining coverage gap in the preview gutter; the overlay mechanism (direct-children spans) extends naturally to `li` anchors.
**Cons / cost:** Renderer change (Decision 6 of the feature said "no renderer change" — this deliberately revisits that for a scoped case); the metadata invariant corpus and tests need extending; exported-HTML neutrality must be re-verified (attribute-only emission is safe — it ships today for footnotes); an open product call: is a number on every list item signal or noise? (human: ~1-2 days / CC: ~2-3h)

**Depends on:** `add-line-numbers` implemented first; a product decision on per-item density (maybe limit to items above a length threshold, or multi-line items only).

**Start here:** extend the top-level block emitter to stamp `li` elements (mirroring the footnote `li` path at `:980`), update `MetadataInvariantTests`' exception list, then extend `__md2RenderLineNumbers`' eligibility rules to nested `li` anchors.

## Left-to-right delimiter ownership scan (inline pipeline)

**What:** Replace the independent inline passes for code/math (`protectCodeSpans`, `protectInlineMath`, and the new `protectInlineParenMath`) with one left-to-right scan that establishes delimiter ownership by position, then applies each delimiter's own rules.

**Why:** Independent sequential passes cannot establish ownership. A `$...$` span inside a prospective `\(...\)` span is claimed first, and its protection token (`\u{E000}MD2-<n>\u{E000}`, `MarkdownRenderer.swift:2522`) restores as nested HTML — the outer math span's `textContent` then drops the inner markup, silently altering valid input (`\text{$x$}` reaches the engine as `\text{x}`). The same class exists today for code spans inside `$...$` math. Demonstrated against the bundled KaTeX by the Codex outside voice during the `add-latex-math-compat` eng review (2026-09-24).

**Current state:** Declared boundary in the change's design (cross-delimiter risk text) plus a test pinning current behavior (span produced, inner span nests on restore, no crash). That test is the regression baseline for this refactor.

**Pros:** The verbatim-TeX guarantee holds for every nesting combination; removes the whole silent-alteration class rather than one instance; one ownership scanner replaces N passes whose order is only comments.
**Cons / cost:** Touches the most regression-sensitive inline machinery in the renderer; every existing math/code-span test needs re-verification against the new scanner. (human: ~2-3 days / CC: ~2-4h)

**Depends on:** `add-latex-math-compat` landing (its boundary test is the before-state proof).

**Start here:** scan once for code spans and both math delimiter pairs in reading order; the earliest opener owns the span; apply the matched delimiter's guards (currency/`$$`/whitespace rules for `$`, none for `\(`).

## Authored placeholder-token output amplification (pre-existing)

**What:** Bound the output growth from well-formed authored `\u{E000}MD2-<n>\u{E000}` tokens that reference real fragments. Each occurrence re-inserts the whole fragment, so output = occurrences × fragment size; a 7.5 KB input can produce about 1 MB of output.

**Why:** The D4 boundary intentionally resolves authored tokens; the lazy resolver now avoids materializing discarded entries, but reachable authored tokens still amplify without a cap. Found by the adversarial review (2026-10-19).

**Current state:** Pinned by the D4 constructed-token/shared-sentinel tests; no document-size or expansion cap in the preview/export paths.

**Pros:** Removes a memory-amplification DoS on crafted documents.
**Cons / cost:** Capping output or making in-range PUA sequences literal changes declared behavior; needs a product decision and spec/test updates. (human: ~0.5 day / CC: ~1-2h)

**Depends on:** D4 sign-off.

**Start here:** measure the output/input ratio in `DocumentRenderWorker`, choose a cap or literal policy, and add a repo-size regression.

## Adopt `.gstack/pregate.json` on the base branch

**What:** Add `!.gstack/pregate.json` to `.gitignore` and commit a Swift lane config to `main` (runner `swift test`, `Sources/MD2Core/**` → the test suite, `openspec/**` as an empty lane).

**Why:** `gstack-pregate` reads the base branch's config; this repo ignores all of `.gstack/`, so every `/ship` pre-gate fails `PREGATE_NO_LANE` on a Swift source change and the Swift test lane cannot be inferred. The 2026-10-19 ship ran the pre-gate with `--policy-from head` as a local workaround.

**Current state:** No config on `main`; the local `/ship` run has a working-tree config with `sh -c 'swift test' pregate {files}`.

**Pros:** The ship pre-gate works for every future branch; the test lane is explicit.
**Cons / cost:** A tiny repo config commit plus a `.gitignore` exception; review the lane mapping when test targets change. (human: ~15min / CC: ~5min)

**Depends on:** nothing.

**Start here:** copy the local config, add the `!.gstack/pregate.json` exception, and run `gstack-pregate validate` before committing.

## Deferred inline review refactors (token grammar and close bookkeeping)

**What:** Expose one token-scanning API on `InlineProtector` for `protectBareAutolinks` (removing the independent `MD2-(\d+)` regex and `Int()` conversion) and replace the global-balance close bookkeeping in `LinkDestinationIndex` with a stack (about -28 lines; fuzz-verified equivalent).

**Why:** The token grammar lives in three places with different leading-zero/Unicode behavior, and the balance bookkeeping re-derives what a stack records directly. Both were found by the pre-landing review (2026-10-19); the user deferred them from this change.

**Current state:** Existing tests pin the current behavior; the deferred refactors have no behavior change.

**Pros:** One token grammar; simpler close bookkeeping; fewer drift surfaces.
**Cons / cost:** Touches the bare-URL and destination hot paths; needs the full suite and a re-fuzz. (human: ~0.5 day / CC: ~1-2h)

**Depends on:** nothing.

**Start here:** add `InlineProtector.firstToken(in:)` using the scalar parser, then switch `protectBareAutolinks`; do the stack refactor separately with the fuzz harness.

## Reproducible release probe for the inline workloads

**What:** Add the fragment/autolink/paren-math workloads to `Scripts/benchmark_p1.swift` (or a sibling probe) so the before/after numbers in `measurements.md` can be reproduced from the checked-in script.

**Why:** The 2026-10-18 measurements came from an ad-hoc release probe; the checked-in benchmark has no fragment scenario, so reviewers cannot re-derive the speedups. The design makes committed benchmark documentation optional, so this is not a blocker.

**Current state:** Timing evidence is the regression suite's ratios plus `measurements.md`.

**Pros:** Reproducible performance evidence for future changes.
**Cons / cost:** A small script addition plus a documented command. (human: ~2h / CC: ~15min)

**Depends on:** nothing.

**Start here:** reuse the `swiftc -O` probe layout from `measurements.md`, add the eight single-line workloads and the one-per-line cases, and record the command in the README or the change notes.

## CJK compatibility punctuation and invisible format characters in bare-URL boundaries

**What:** Extend `bareURLBoundaryCharacters` to the CJK compatibility punctuation blocks U+FE10–U+FE19, U+FE30–U+FE4F and U+FE50–U+FE6B, and decide on the invisible format characters U+FEFF, U+00AD, U+2060 and bidi marks.

**Why:** `https://example.com﹐tail` (U+FE50 SMALL COMMA) and `https://example.com<U+FEFF>tail` render literally because the character is absorbed into the authority and domain validation rejects the candidate. This is the same silent-loss class the 2026-10-20 change fixes for U+FF0C. Vertical/small-form CJK text and pasted Word/web text can trigger it. Found by the Red Team review on 2026-10-20.

**Current state:** The change declares the enumerated set; other Unicode punctuation and format characters are outside it and documented as such in the matrix and support doc.

**Priority:** P3

**Pros:** Closes the remaining silent-loss cases for CJK compatibility forms and pasted text.
**Cons / cost:** Adds two punctuation blocks and at least three format characters to the boundary contract; needs spec/design/matrix/docs/sample-table/test updates and a decision on bidi marks. (human: ~3-4h / CC: ~30min)

**Depends on:** nothing; extends the `cjk-autolink-boundaries` contract.

**Start here:** add the ranges to `bareURLBoundaryCharacters`, extend `bareURLBoundarySamples`, and pin `https://example.com﹐tail` and `https://example.com\u{FEFF}tail`; run `swift test --filter CommonSyntaxTests --filter CrossArtifactConsistencyTests`.
