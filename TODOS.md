# TODOS

Tracked work considered and explicitly deferred from in-flight changes. Each item carries its reasoning so a future picker-upper has the context.

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

## Pre-existing bare-URL bugs found by the token-grammar differential

**What:** Fix two bare-URL bugs. (1) A trailing entity after a bare URL is double-escaped: `see https://a.com&amp; next` renders `</a>&amp;amp; next`, so the reader sees `&amp;` instead of `&`. (2) A combining mark right after `http://`, `https://` or `www.` turns the URL into a `mailto:` link: `http://` + U+0301 + `x.com` renders `<a href="mailto:http://…x.com">`.

**Why:** Both surfaced in the `unify-token-grammar` differential run (2026-10-31) and reproduce on `main` with no private-use text, so they are independent of that change and were left out of its scope.

**Current state:** (1) `protectBareAutolinks` moves a trailing entity spelling, which `source(in:)` deliberately keeps authored, into `trailing`, then emits `escapeHTML(trailing)`. (2) The `isURL` check uses `Character`-level `hasPrefix`, so a mark that fuses with the scheme's last character fails it and the candidate falls through to the email branch.

**Pros:** Small, local fixes in one function; (1) is visible in ordinary prose.
**Cons / cost:** Each changes output for its inputs, so each needs tests and a differential run over the real corpus. (human: ~2h / CC: ~30-45min)

**Depends on:** nothing.

**Start here:** in `protectBareAutolinks`, emit the trailing entity spelling as the entity it already is, and compare the scheme prefixes on `unicodeScalars`; reuse the `swiftc -O` differential probe described in the `unify-token-grammar` design.

## Source-line attribute lands on the closing tag after a leading combining mark

**What:** A paragraph whose text starts with a combining mark gets its `data-md2-source-line` attribute on the closing tag: U+0301 + `para` renders `<p>…para</p data-md2-source-line="1">`.

**Why:** The HTML is invalid, and the block loses its line mapping, which the preview gutter and mode-switch anchoring read. Found by the same differential run (2026-10-31); reproduces on `main`.

**Current state:** `taggedWithSourceLines` finds the end of the opening tag with `html.firstIndex(of: ">")`, a `Character` search. A combining mark at the start of the content fuses with the opening tag's `>` into one grapheme, so the search lands on the closing tag.

**Pros:** A one-line fix (search the UTF-8 or scalar view).
**Cons / cost:** It touches how every block is stamped, so `MetadataInvariantTests`, the conformance suite and the GUI gutter suites must stay green. (human: ~1h / CC: ~15-30min)

**Depends on:** nothing.

**Start here:** search `html.utf8` for `>` in `taggedWithSourceLines` and add a paragraph test that starts with U+0301.
