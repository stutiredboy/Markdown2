## Why

Inline rendering protects fragments (code spans, math, entities, autolinks, raw HTML, links, images, reference links, bare URLs) by swapping them for placeholder tokens, then restoring the tokens at the end. Restoration currently runs one whole-text pass per fragment, and `replaceMatches` calls `replaceSubrange` once per match, so both cost O(fragment count × text length). A paragraph carrying many URLs, email addresses, entities, or reference links therefore renders in quadratic time. The newer base also calls `InlineProtector.source(in:)`, which has the same per-fragment loop, once per bare-URL candidate and twice per reference link, and `protectAutolinks` asks `isInsideLinkDestination` to scan backward to the nearest `](` for every angle autolink; `protectInlineParenMath` makes the same backward scan for every `\(...\)` span.

Measured on the pre-rebase checkout (release build, Apple M4), with all fragments on one line so a single inline pass sees them: 500 angle autolinks take 336 ms, 1,000 take 1.30 s, and 2,000 take 5.31 s — 3.9× and 4.1× per doubling. 2,000 `mailto:` autolinks take 3.50 s and 2,000 `&nbsp;` entities take 0.81 s. These numbers are `[measured: pre-rebase 93bde83, re-measure before gate]`. After the D1 fast-forward to `origin/main` (`0a75468`), this checkout is the newer revision the report cites: `paragraphHTML` renders a whole paragraph in one inline pass, and `protectBareAutolinks` / `renderReferenceLinks` add `source(in:)` lookups. The report's 1.55 s / 6.2 s bare-URL figures are the same defect on the shipped base.

Rendering already runs off the main thread, so typing stays responsive. The cost lands on every pause: one CPU core saturates for seconds, the preview updates late, and export, print, and mode switches wait for the render to finish. Reference lists, bookmark dumps, and pasted logs are exactly the documents that hit this.

## What Changes

- **Restore placeholders in one forward scan.** `InlineProtector.restore(in:)` and `source(in:)` will share one resolver that scans the text once, resolves each `\u{E000}MD2-<n>\u{E000}` token by index, and expands nested entries once with a cache. Cost becomes O(text + fragment text), independent of the fragment count. `source(in:)` keeps returning the authored spelling, and `isLiteral` keeps terminating bare-URL matching.
- **Assemble `replaceMatches` output in order.** Instead of copying the source and calling `replaceSubrange` per match, the function will buffer transformed strings in the current descending evaluation order and assemble them forward into a pre-sized result. Cost becomes O(text + total replacement size) and figure numbering keeps its current order.
- **Classify inline destinations from a precomputed index.** One forward scan of `](` destinations replaces the backward scan in both `protectAutolinks` and `protectInlineParenMath`, so each angle autolink and paren-math span is O(1) and both workloads scale linearly.
- **Preserve rendered output and safety.** Token syntax, nesting behavior, literal private-use text, the pre-link/pre-reference `restore` and `source` calls used for URL safety, and `isLiteral` behavior stay identical for documents without private-use sentinel characters. Figure numbering follows document order (a corrected, declared behavior for multi-figure paragraphs), and a restored destination containing raw `<`, `>`, or `"` is rejected so an authored token cannot splice markup into an attribute. Tokens constructed only after an escape is restored, and shared-sentinel overlaps, are a declared, tested boundary.
- **Pin the scaling with regression tests.** New tests double the number of fragments and assert render time does not approach 4×, covering URL autolinks, Markdown links, `mailto:` autolinks, HTML entities, bare URLs, bare URLs with entities, reference links, reference links with protected keys, and paren-math spans, with correctness assertions so dropping content cannot pass. A one-fragment-per-line paragraph case covers the report's input shape and is red before the fix on this base.
- **No new Markdown syntax, HTML, CSS, export, or dependency changes.** Bare URL/email autolinking and reference links already exist on the base; they inherit the fix through the same protection, classification, and substitution path.

**Non-goals** (deliberately out of scope):

- Changing bare-URL, reference-link, or any other inline syntax or matching behavior; only the restore/source path beneath them.
- Changing the paragraph-level one-pass structure in `paragraphHTML`.
- Reordering the inline pass pipeline or changing the placeholder token format.
- Optimizing unrelated linear-scan hotspots (for example `HTMLSafety.decodeEntities`) unless measurement shows they dominate after the shared fixes.
- Changing preview, PDF, Print, or HTML-export output.
- Touching the GUI-only render paths; this is shared `MD2Core` code covered by `swift test`.

## Capabilities

### New Capabilities

- `inline-render-performance`: linear-time restoration (including `source(in:)` lookups) of protected inline fragments, linear-time inline destination classification, and linear-time match substitution, with scaling regression coverage for URL-, email-, entity-, bare-URL-, reference-link-, and paren-math-heavy paragraphs.

### Modified Capabilities

None. The rendered HTML and the declared Markdown behavior do not change for documents without private-use sentinel characters; the D4 boundary is declared and tested. This is a performance and verification contract.

## Impact

- `Sources/MD2Core/MarkdownRenderer.swift`: `InlineProtector.restore(in:)` (`:2977`), `source(in:)` (`:2963`), `replaceMatches` (`:2846`), `LinkDestinationIndex` (used by `protectAutolinks` and `protectInlineParenMath`), `renderImages`' prepare pass (`:1940`), and the mid-pipeline call sites in `protectRawHTML` (`:1543`), `renderImages` (`:1884`), `renderLinks` (`:2004`), `renderReferenceLinks` (`:2053-2054`, `:2058`, `:2066`), and `protectBareAutolinks` (`:2116`), plus the final restore (`:1402`).
- `Sources/MD2Core/HTMLSafety.swift`: the destination character guard (`isSafeURL` rejects raw `<`, `>`, or `"`).
- `Tests/MD2CoreTests/`: a new focused performance/regression suite (for example `InlineRenderingPerformanceTests.swift`), plus output-equivalence, figure-numbering, link-destination, and D4 characterization assertions. Existing `MarkdownRendererTests`, `P1RegressionTests`, the reference-link and bare-URL tests, and the conformance corpus remain the broad correctness guard.
- Not affected: public API, package dependencies, bundled resources, preview JavaScript/CSS, PDF/Print/HTML export pipelines, and the GUI-gated suites.
