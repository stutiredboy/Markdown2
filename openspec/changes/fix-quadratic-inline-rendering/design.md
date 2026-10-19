## Context

`MarkdownRenderer.inlineHTML` runs a fixed, ordered inline pipeline (`Sources/MD2Core/MarkdownRenderer.swift:1377-1402`):

| Stage | Pass | What it protects |
| --- | --- | --- |
| 1 | `protectCodeSpans` | `` `code` `` |
| 2–3 | `protectInlineMath`, `protectInlineParenMath` | `$…$`, `\(…\)` |
| 4 | `protectBackslashEscapes` | `\*`, `\_`, … |
| 5 | `protectHTMLEntities` | `&nbsp;`, `&#58;`, … |
| 6 | `protectAutolinks` | `<https://…>`, `<mailto:…>` |
| 7 | `protectRawHTML` | allowlisted formatting tags |
| 8–10 | footnote / citation / cross-reference passes | generated anchors |
| 11 | `escapeHTML` | — |
| 12–13 | `renderImages`, `renderLinks` | `<img>`, `<a>` |
| 14 | `renderReferenceLinks` | `[label][key]` references |
| 15 | `protectBareAutolinks` | bare URLs and emails |
| 16 | `renderOptionalInline` | highlight / sup / sub |
| 17 | `renderEmphasis` | `<strong>`, `<em>`, `<del>` |
| 18 | newline pass | `\n` → `<br>` |

Every protected construct is appended to an `InlineProtector` (`:2949-2984`) and replaced in the text by a token, `\u{E000}MD2-<n>\u{E000}`. `protect(_:source:literal:)` (`:2955`) now stores three parallel facts: `fragments` (rendered HTML), `sources` (the authored spelling used by bare-URL and reference-link recovery), and a `literals` index set. `protect` is append-only: an entry created at index `n` can contain tokens `0..<n` (it was built from text that existed before index `n`), never a token `≥ n`. The final `restore(in:)` puts the fragments back; `renderLinks`, `renderImages`, `renderReferenceLinks`, and `protectRawHTML` also call `restore` mid-pipeline on small spans. `renderReferenceLinks` and `protectBareAutolinks` call `source(in:)` to recover the authored URL or reference key before matching and safety checks.

Four hot spots are quadratic:

1. **`InlineProtector.restore(in:)`** (`:2977`) iterates every fragment in descending index order and calls `String.replacingOccurrences` over the whole text for each. Cost: `fragments × text length`.
2. **`InlineProtector.source(in:)`** (`:2963`) does the same over `sources`. `protectBareAutolinks` calls it once per bare-URL candidate (`:2116`), and `renderReferenceLinks` calls it twice per reference link (`:2053-2054`, with `restore` at `:2058` and `:2066`). Cost: `fragments × span length` per match.
3. **`replaceMatches`** (`:2846`) copies the source into `result` and calls `result.replaceSubrange` once per match. Each replacement shifts the remaining text. Cost: `matches × text length`. The loop evaluates transforms in descending match order; `renderImages`' `assignFigure` (`:1940`) mutates `CrossReferenceContext`, so that order is observable in figure numbering.
4. **Autolink destination classification** (`isInsideLinkDestination`, `:1486`) scans backward to the nearest `](` for every angle autolink (`:1530`). With no `](` in the prefix, N autolinks cost O(N²) even after the first three fixes.

The report's cited lines (`:2963`, `:2977`, `:2846`) and its bare-URL pass are this checkout after the D1 fast-forward to `origin/main` (`0a75468`); those symbols are authoritative.

**Measured on the pre-rebase checkout** (release `swiftc -O`, Apple M4, macOS 26.7.1, all fragments on one line so one inline pass sees them; median of 3; `[measured: design.md, pre-rebase 93bde83, re-measure before gate]`):

| Input | 500 | 1,000 | 2,000 | Doubling ratio |
| --- | ---: | ---: | ---: | ---: |
| `<https://…>` autolinks | 336 ms | 1,296 ms | 5,306 ms | 3.9× → 4.1× |
| `[link](https://…)` | — | 1,163 ms | 4,700 ms | 4.0× |
| `<mailto:…>` autolinks | — | 871 ms | 3,503 ms | 4.0× |
| `&nbsp;` entities | — | 202 ms | 808 ms | 4.0× |

Re-baselined pre-fix and post-fix numbers for every workload are recorded in
[`measurements.md`](measurements.md) (`[measured: 2026-10-18]`).

**Call granularity.** On the re-baselined checkout, `paragraphHTML` (`:993-1012`) joins all source lines and calls `inlineHTML` once per paragraph. The one-fragment-per-line case is therefore one inline pass with thousands of fragments, which is the shape behind the report's 1.55 s → 6.2 s bare-URL numbers. The fix must not depend on granularity: it makes the shared restore, source, and substitution paths linear whether a pass sees one fragment or thousands.

Constraints:

- Output must be byte-identical for existing documents; the conformance corpus and the 614-test suite are the guard.
- The security contract must survive: `HTMLSafety.isSafeURL` must still see fully restored text, including entity-obfuscated schemes (`javascript&#58;…`).
- `source(in:)` must still return the authored spelling (entity spellings included), and `isLiteral` must still terminate bare-URL matching.
- No new dependencies, no public API change, no HTML/CSS/export changes.
- Verification runs under plain `swift test` (non-GUI); no `MD2_RUN_GUI_TESTS` path is involved.

## Goals / Non-Goals

**Goals:**

- Make placeholder restoration, both `restore(in:)` and `source(in:)`, **O(text + fragment text)** and independent of the fragment count.
- Make `replaceMatches` **O(text + total replacement size)** while evaluating transforms in the same descending order as today, so `assignFigure` numbering does not change.
- Make `isInsideLinkDestination` **O(1) per autolink** via one forward pre-scan of `](` destinations, so angle autolinks scale linearly.
- Keep mid-pipeline `restore` and `source` calls cheap, so a paragraph with thousands of links, images, bare URLs, or reference links does not pay a per-match fragment scan.
- Preserve rendered HTML byte-for-byte for documents without private-use sentinel characters, preserve figure numbering, and preserve all URL-safety and `isLiteral` behavior. Adversarial tokens formed only after restoration are a declared boundary (D4).
- Add non-GUI scaling regression tests for URL autolinks, Markdown links, mailto autolinks, entities, bare URLs (single-line and one-per-line), and reference links. Each test must fail on the current implementation and pass after the fix.

**Non-Goals:**

- Changing bare-URL, reference-link, or any other inline syntax or matching behavior; this change touches only the restore/source path beneath them.
- Changing the paragraph-level one-pass structure in `paragraphHTML`.
- Reordering the inline pipeline or changing the token format.
- Optimizing other linear-scan code (`HTMLEscaping`, `HTMLSafety.decodeEntities`, emphasis passes) beyond what the shared restore/source and substitution functions make linear.
- Preview JavaScript/CSS, PDF/Print/HTML export, GUI-only paths, or benchmark documentation.

## Decisions

### 1. Restore and source lookup with one forward scan and in-place lazy expansion

Keep the append-only bookkeeping in `protect(_:source:literal:)` exactly as it is: append to `fragments` and `sources`, record `literals`, and return `\u{E000}MD2-<fragments.count>\u{E000}`. Replace `restore(in:)` and `source(in:)` with one shared resolver parameterized by the array to emit (`fragments` or `sources`):

1. **Fast path** — if the input contains no `\u{E000}` sentinel, return it unchanged (no allocation).
2. **Expand pending entries once** — maintain one `expandedCount` watermark. The two arrays are appended in lockstep, so one watermark covers both. While `expandedCount < fragments.count`, expand both `fragments[expandedCount]` and `sources[expandedCount]` in place by scanning each once and replacing only tokens whose index is `< expandedCount`; then advance the watermark. By induction every expanded entry is token-free, so an entry can be expanded against the already-expanded lower indices.
3. **One scan of the input** — walk forward to each sentinel, append the literal run before it, parse `MD2-<canonical decimal>` followed by a closing sentinel, append the selected array's entry when the index is already expanded, and continue after the closing sentinel. Any malformed or out-of-range token is emitted literally, one character at a time, so author text containing private-use characters is preserved exactly.

Complexity: each entry is expanded at most once (total O(fragment text + source text)); each call scans only its own input (O(input length)). The final restore over a paragraph is linear, and the per-link, per-image, per-reference, and per-bare-URL lookups scan only the small span instead of all fragments.

One resolver, not two, because the grammar, the nesting induction, and the literal fallback are identical for `fragments` and `sources`; a second scanner would duplicate roughly 40-60 lines and create a second correctness surface.

Token lifecycle:

```
protect(fragment, source, literal)
  fragments.append(rendered)          sources.append(authored)
  literals.insert(index) if literal
  return "\u{E000}MD2-<index>\u{E000}"

restore(text) / source(text)
  if text has no "\u{E000}": return text
  while expandedCount < fragments.count:
      expand fragments[expandedCount] and sources[expandedCount]
          (replace only tokens with index < expandedCount)
      expandedCount += 1
  scan text left to right:
      literal run                      -> append
      "\u{E000}MD2-" <digits> "\u{E000}" -> append array[index] when index < expandedCount
      malformed / out of range         -> append literally, continue one scalar
  return output
```

*Alternatives rejected:*

- **Keep `replacingOccurrences` but sort fragments and break early** — still one whole-text pass per fragment; the defect remains.
- **One regex pass over the text with a replacement closure** — `NSRegularExpression` can scan linearly, but nested fragments still need recursive resolution, a closure runs per token, and every mid-pipeline restore would re-do the work unless cached. The manual scanner gives exact control over malformed-token semantics.
- **Eager expansion inside `protect`** — pays for fragments that later passes drop (for example a link fragment replaced by its label) and adds cost to the hottest path even when no restore follows.
- **A separate expanded-fragments array** — equivalent asymptotically, but duplicates every fragment string. In-place expansion keeps one array; the append-only invariant makes it safe.
- **Two scanners, one for `restore` and one for `source`** — same grammar and same induction; duplication buys nothing and doubles the edge-case surface.

Parsing must preserve current behavior exactly:

- `\u{E000}MD2-00\u{E000}` is **not** fragment 0 (the current code matches the exact canonical spelling); reject leading zeros.
- A token whose index is `≥ expandedCount` stays literal. This also covers forward references, which the old descending loop left literal for the same reason.
- A lone `\u{E000}` or `\u{E000}MD2-x\u{E000}` stays literal.
- An entry (fragment or source) that contains a sentinel as ordinary text expands literally; it is not re-scanned as a new token unless it matches the full grammar.
- A token formed only after a restored escape is emitted literally. The old descending replacement expanded it; the one-pass scanner does not re-read its own output. D4 accepts this as a declared boundary, pinned by a characterization test.
- When two token spellings share a sentinel, the leftmost well-formed token wins. The old per-index replacement gave the higher index priority; D4 accepts the difference, pinned by a characterization test.
- `isLiteral` is unchanged: it only terminates bare-URL matching; it does not suppress restoration in either array.

### 2. Evaluate transforms in the current order, assemble output in source order

The current loop iterates `matches.reversed()` and passes the progressively mutated result to each transform. Some transforms are stateful: `renderImages` calls `assignFigure` (`:1940`), so a forward evaluation order would renumber figures left-to-right instead of the current right-to-left order. Preserve the observable order by buffering the transformed strings in the same descending order, then assembling forward:

```swift
var replacements = [String](repeating: "", count: matches.count)
for (offset, match) in matches.enumerated().reversed() {
    replacements[offset] = transform(match, source)
}

var result = ""
result.reserveCapacity(source.utf8.count)
var cursor = source.startIndex

for (offset, match) in matches.enumerated() {
    guard let range = Range(match.range, in: source),
          range.lowerBound >= cursor else { continue }
    result.append(contentsOf: source[cursor..<range.lowerBound])
    result.append(replacements[offset])
    cursor = range.upperBound
}
result.append(contentsOf: source[cursor...])
```

Match ordering is guaranteed by the producers: `NSRegularExpression.matches` returns ascending, non-overlapping matches, and `MarkdownLinkSyntax.candidateRanges` returns ascending, disjoint candidates (one anchored match each, order preserved by `compactMap`). The `range.lowerBound >= cursor` guard makes overlapping or stale ranges harmless: the skipped match's text is still copied as part of the next literal run. A zero-match input returns `source` unchanged.

**Contract change (internal):** the transform now receives the original `source`, not the progressively mutated result. Most transforms read only their own match and capture groups (audited on the re-baselined base: label stripping `:554`, code spans `:1408`, escapes `:1423`, math `:1441`/`:1468`, entities `:1519`, autolinks `:1527`, raw HTML `:1542`, cross-references `:1722`, emphasis `:1832-1862`, images `:1876`, optional inline `:2085`, bare autolinks `:2099`). Two are not purely local and are called out explicitly: `renderImages` mutates `assignFigure` state (`:1940`), which is why the buffered evaluation keeps descending order; `protectAutolinks` reads the preceding prefix through `isInsideLinkDestination` (`:1530`, `:1487`), which Decision 6 makes linear. `renderReferenceLinks` (`:2027`) rebuilds manually and does not use `replaceMatches`. Add a comment to `replaceMatches` stating that transforms MUST NOT depend on other matches' replacements and that stateful transforms keep their call order. This also removes the need to reason about UTF-16 ranges surviving earlier replacements.

Complexity: O(source length + sum of replacement lengths), versus O(match count × source length) from repeated tail shifting.

*Alternatives rejected:* `NSMutableString.replaceCharacters` (still shifts the tail); collecting `[String]` pieces and `joined()` (extra allocation and copy, no correctness benefit); a reverse-order `String` build (more index bookkeeping, same asymptotics).

### 3. Route every mid-pipeline restore and source lookup through the linear scanner

`renderLinks` and `renderImages` call `restore` on each href/src for the safety check; `protectRawHTML` calls it on each tag before sanitizing; `renderReferenceLinks` calls `source` on the key and label and `restore` on the label; `protectBareAutolinks` calls `source` on each candidate prefix. With the old loops, each of those calls was O(fragment count) even for a 30-byte span, so a paragraph with 2,000 links or bare URLs paid O(matches × fragments) before the final restore. With Decision 1 they are O(span length), and the expansion cache means nested entities are expanded once for the whole inline pass.

The nine call sites on the re-baselined base are: final `restore` (`:1402`), `protectRawHTML` (`:1543`), `renderImages` (`:1884`), `renderLinks` (`:2004`), `renderReferenceLinks` (`source` `:2053-2054`, `restore` `:2058` and `:2066`), and `protectBareAutolinks` (`source` `:2116`). No other placeholder-restore loop exists; the implementation audit must confirm that and must not add one.

### 4. Regression tests: fail-fast ceiling, ratio, and output correctness

Add `Tests/MD2CoreTests/InlineRenderingPerformanceTests.swift` (Swift Testing, `@Suite(.serialized)` to keep timing runs from overlapping each other). Workloads:

| Case | Fragment source | Correctness assertion |
| --- | --- | --- |
| URL autolinks | `<https://example.com/path/N>` | N rendered `<a href="https://example.com/path/` anchors |
| Markdown links | `[link N](https://example.com/path/N)` | N anchors (also exercises `linkCandidates`) |
| Email autolinks | `<mailto:userN@example.com>` | N `mailto:` anchors |
| HTML entities | `&nbsp;` | N literal `&nbsp;` in the body, no `&amp;nbsp;` |
| Bare URLs | `https://example.com/path/N` separated by spaces | N anchors; exercises the autolink match path |
| Bare URLs with entities | `https://example.com/?a=N&amp;b=2` separated by spaces | N anchors; `source(in:)` must expand the protected entity and recover the authored spelling |
| Reference links | `[label N][refN]` with N definitions | N anchors; exercises the reference-link match path |
| Reference links with protected keys | `[label N][ref&amp;N]` with N definitions | N anchors; `source(in:)` must expand the key and match the definition |

The plain bare-URL and reference-link cases take the sentinel-free fast path in `source(in:)`; keep them for match-path coverage, but the entity-bearing variants are the cases that exercise source expansion under scaling, so their recovered output is asserted exactly.

Add a correctness test with two labeled images in one paragraph (`![one](a.png){#fig:one}` and `![two](b.png){#fig:two}`). The current reversed evaluation assigns the second image Figure 1 and the first Figure 2; the buffered builder must preserve that numbering exactly. This test pins the stateful-transform order.

Add characterization tests for the D4 boundary: a token formed only after an escaped hyphen is restored stays literal, and a shared-sentinel overlap resolves by the leftmost well-formed token. These pin the accepted behavior change.

Each case:

1. Warms up with a small render.
2. Builds all fragments **on one line** (one `inlineHTML` pass, one protector, many fragments).
3. Measures N=500 with min-of-3. Asserts an absolute ceiling (tentatively 1 s in the debug `swift test` build). This fails fast on the old implementation instead of running the 2N case for seconds.
4. Measures 2N=1,000 with min-of-3. Asserts `large < small × 3.0` (linear ≈ 2×; quadratic ≈ 4×) and an absolute ceiling (tentatively 2 s).
5. Asserts the rendered output contains all N constructs and no `MD2-`/private-use sentinel.

Add the **one-fragment-per-line paragraph** case (the report's input shape) at 1,000/2,000 for URL autolinks and bare URLs, with the same ratio assertion. On the re-baselined base, `paragraphHTML` renders the whole paragraph in one inline pass, so this case is quadratic before the fix and linear after it; it must be red in task 2.4, not green.

Measurement notes:

- Use `ContinuousClock` (the precedent is `P1RegressionTests.unclosedBracketsHaveBoundedCost`), but take the minimum of 3 runs rather than the mean/median: the minimum is the least contaminated by scheduler noise.
- Thresholds are calibrated on the debug test build, not the release probe. The ratio is the primary guard; the absolute ceilings only bound CI time and fail fast.
- The ratio compares one document render to another, so the fixed ~6 ms document scaffolding (the bundled CSS) is present in both. At these sizes it is negligible and slightly compresses the ratio toward 1, which is conservative for the guard.
- Correctness assertions live in the same test so an "optimization" that drops fragments cannot pass.
- Swift Testing may run other suites concurrently even with `@Suite(.serialized)`; the ratio is the primary guard and min-of-3 reduces load spikes. If CI still flakes, isolate the suite in its own invocation or raise the ceilings, never the ratio.

### 5. Preserve output and security semantics

- Token grammar and the `protect(_:source:literal:)` bookkeeping are unchanged, so author text, nesting, and existing tests see the same output from both resolvers. The byte-identical guarantee covers documents that do not contain private-use sentinel characters; the D4 constructed-token cases are declared and pinned by tests.
- Nested restoration is covered by the existing `P1RegressionTests.encodedActiveURLsAreInert` (`javascript&#58;`, `java&#x73;cript:`, `java&Tab;script:`) and by new mixed cases: a link whose href contains an entity and whose label contains code/emphasis, raw HTML with an entity in an attribute, a bare URL adjacent to code/math tokens, and a reference key containing an entity. `isLiteral` must still terminate bare-URL matching.
- Run the full `swift test` suite (including the conformance corpus) as the broad equivalence guard. No GUI suite is involved.
- Optionally record release before/after numbers from the existing probe layout in the change notes; no committed benchmark documentation is required for acceptance.

### 6. Precompute link-destination ranges for autolink classification

`protectAutolinks` calls `isInsideLinkDestination(source, at:)` (`:1486`) for every angle autolink; the function scans backward to the nearest `](` and then forward with paren depth and escape skipping. With no `](`, the backward search costs O(prefix), so N autolinks are O(N²).

Precompute once per `protectAutolinks` pass:

1. Scan the text left to right for `](` openers.
2. For each opener, scan forward to its matching `)` with the same escape and depth rules; store the destination interval `(opener.upperBound, close)` or an unterminated interval to the end.
3. Keep the openers in ascending order. For an autolink at index, binary-search the nearest opener at or before it, then return true when the index is inside that opener's destination and false when its `)` closed earlier. This keeps the current nearest-opener semantics: an outer destination does not rescue a position after the nearest opener's destination closed.

Complexity: O(text + N log M), or O(text + N) with a two-pointer scan when the autolink positions are processed in ascending order. The buffered transform order in Decision 2 is descending; binary search keeps the lookup independent of order. Tests: no destination, one destination, nested parens, escaped parens, unterminated destination, multiple destinations, and the N=500/1,000 scaling case.

*Alternative rejected:* memoizing `isInsideLinkDestination` per autolink. The first call at each distinct position is still O(prefix), and a position-keyed cache adds state without bounding the first-call cost; the interval pre-scan is simpler and exact.

## Risks / Trade-offs

- **Two arrays, one resolver** → `fragments` and `sources` are appended in lockstep by `protect`, so one `expandedCount` watermark covers both; `isLiteral` only affects bare-URL matching, not restoration. Dedicated tests exercise `restore` and `source` separately and together.
- **Transform contract change** (original source vs mutated result) → Audit every call site. Most transforms read only their own match; `renderImages` mutates `assignFigure` state, so transforms are buffered in the current descending order, and `protectAutolinks` reads the preceding prefix, which Decision 6 makes linear. The conformance suite and a two-figure numbering test pin the output.
- **Link-destination pre-scan semantics** → The pre-scan must match the current nearest-opener rule, escape skipping, nested parens, and unterminated destinations. Dedicated tests cover each case, plus the N=500/1,000 scaling case.
- **D4 compatibility boundary** → Tokens formed only after a restored escape stay literal, and shared sentinels resolve leftmost. This is a deliberate, tested change for adversarial private-use input; the byte-identical claim excludes documents containing private-use sentinel characters.
- **Timing tests flake on loaded CI** → `@Suite(.serialized)`, min-of-3, a 3× ratio threshold that separates 2× from 4× with margin, and generous absolute ceilings. If a slower runner still flakes, raise the ceiling — not the ratio — so the quadratic guard stays meaningful.
- **Scanner edge cases** (leading zeros, lone sentinel, out-of-range index, forward reference, `isLiteral`, constructed token, shared sentinel) → Dedicated unit-style tests alongside the scaling tests; the scanner is also exercised by every existing entity/link/math test.
- **In-place expansion mutating an entry later referenced** → Both arrays are append-only and expansion only replaces tokens with already-expanded lower indices; an expanded entry is token-free, so re-use is idempotent. `expandedCount` never moves backward.
- **Memory / constant factors** → The scanner allocates one output string per call (reserved to the input size). Mid-pipeline restores and source lookups operate on small spans. In-place expansion avoids a second array copy. This is strictly less work than the removed repeated scans.
- **Security regression** → `HTMLSafety.isSafeURL` still receives fully restored text; the P1 entity-obfuscation tests plus the new nested-fragment, reference-key, and bare-URL cases guard it.
- **Re-baselined base** → D1 moved the checkout to `origin/main` `0a75468` and re-baselined the line numbers; D2 added `source(in:)`, the reference-link path, and bare-URL tests; D3 added the link-destination pre-scan; D4 set the private-use-token boundary. The one-per-line case is expected red before the fix, matching the report.

## Migration Plan

No data, schema, or API migration. The change is internal to `MD2Core`, lands as one commit, and rolls back by reverting the shared resolver, the `source(in:)` routing, and `replaceMatches` (the tests document the old failure). The release benchmark can be reproduced with the existing `swiftc -O` probe layout if before/after numbers are wanted.

## Open Questions

- Whether to add a `--fragments` scenario to `Scripts/benchmark_p1.swift` for a committed reproducible release benchmark. Not required for acceptance; the non-GUI regression tests are the guard.
- Final absolute ceilings depend on the slowest supported CI runner; calibrate during implementation while keeping the 3× ratio as the primary quadratic guard.
- The pre-rebase timings in this design are `[measured: pre-rebase 93bde83, re-measure before gate]`; record the re-baselined numbers for the bare-URL and one-per-line cases during task 5.2.

## Eng Review

Target: `openspec/changes/fix-quadratic-inline-rendering` (proposal, design, tasks, spec)
Branch: `main` at local HEAD `93bde83`; `origin/main` at `0a75468` (local is 9 commits behind)
Reviewer: plan-eng-review (Claude, session 40160-1792321451-83636c52)

### Scope Challenge findings

**[SC1] [P1] (confidence: 10/10) - The plan targets a stale checkout; the shipped branch already has the newer pipeline.**
- Receipts: `git rev-list --left-right --count HEAD...origin/main` returns `0 9`. `origin/main` `Sources/MD2Core/MarkdownRenderer.swift` is 3133 lines vs local 2880. `origin/main:993-1012` joins all paragraph lines and calls `inlineHTML` once; local `:967-989` calls it once per line. `origin/main:1377-1398` adds `renderReferenceLinks`, `protectBareAutolinks`, `renderOptionalInline`, and a final newline-to-`<br>` pass. `origin/main:2097` is `protectBareAutolinks`; `origin/main:2963` is `InlineProtector.source(in:)`; `origin/main:2977` is `restore(in:)`.
- Impact: task 2.4 expects the one-fragment-per-line case to be linear "in the current per-line `paragraphHTML` architecture". On `origin/main` it is the quadratic case, because one paragraph is one inline pass with thousands of fragments. The test matrix also has no bare-URL case, which is the exact workload the report measured.

**[SC2] [P1] (confidence: 9/10) - `source(in:)` and its callers are absent from the rewrite and the test matrix.**
- Receipts: `origin/main:2963-2967` loops every entry in `sources` and calls `replacingOccurrences` over the whole text, once per fragment. It is called per bare-URL candidate at `:2116`, twice per reference link at `:2053-2054`, and `restore` is called at `:2058` and `:2066`. The local checkout has only four restore call sites; `origin/main` has nine restore/source call sites.
- Impact: fixing only `restore(in:)` leaves the reported 1.55 s to 6.2 s bare-URL workload quadratic. Decision 3 says every placeholder-restore loop must go through the scanner, but tasks 3.1-3.3 name only `restore(in:)`, and task 1.2's audit is conditional ("if the working revision contains...").

**[SC3] [P2] (confidence: 8/10) - Perf evidence is a single-machine median of three, not an interleaved base/branch table.**
- Receipts: `design.md:27-36` gives machine, engine, N, and median timings, but no p95, no interleaved base/branch runs, no steady-state case, and no "reproduced on main?" marker.
- Tag: the timing numbers are `[measured: design.md, re-measure before gate]`; the 3x ratio in the tests is the real guard.

**[SC4] [P3] (confidence: 8/10) - The `replaceMatches` transform audit list is stale.**
- Receipts: `origin/main` calls `replaceMatches` at `:554` (label stripping), `:1408` (code spans), `:1423` (escapes), `:1441` and `:1468` (math), `:1519` (entities), `:1527` (autolinks), `:1542` (raw HTML), `:1722` (cross-references), `:1832-1862` (emphasis), `:1876` (images), `:2085` (optional inline), `:2099` (bare autolinks). The plan's audit list omits bare autolinks, reference links, and optional inline. All inspected transforms read only their own match, but the audit must say so for the newer call sites.

**[SC5] [P3] (confidence: 7/10) - The design has no ASCII diagram of the token lifecycle.**
- The protect -> token -> watermark expansion -> final scan invariant is the key flow of this change; add a small diagram so the induction is auditable.

**[SC6] [P3] (confidence: 7/10) - `restore` and `source` should share one scanner.**
- `origin/main:2963` and `:2977` are two verified first-party callers of the same nested-token scan. One resolver parameterized by the string array (`fragments` vs `sources`) avoids duplicating roughly 40-60 lines and leaves one correctness surface.

### Premise table

| Premise | Claim | Receipt | Verdict |
|---|---|---|---|
| P1 | `InlineProtector.restore` runs one whole-text `replacingOccurrences` per fragment, descending | local `MarkdownRenderer.swift:2724-2729` | VERIFIED |
| P2 | `replaceMatches` copies the source and `replaceSubrange`s once per match | local `:2609-2632` (loop `:2627-2630`, transform receives `result`) | VERIFIED |
| P3 | Mid-pipeline restores live in `protectRawHTML`, `renderImages`, `renderLinks` | local `:1457`, `:1798`, `:1918` | VERIFIED |
| P4 | `paragraphHTML` calls `inlineHTML` once per source line | local `:967-989` | VERIFIED on local HEAD; FALSE on `origin/main:993-1012` (one call per paragraph) |
| P5 | Token grammar is `\u{E000}MD2-<n>\u{E000}` and `protect` is append-only | local `:2714-2717` | VERIFIED |
| P6 | The report's newer revision has `source`/`restore`/`replaceMatches` at `:2963`/`:2977`/`:2846` and a bare-URL pass | `origin/main:2963`, `:2977`, `:2846`, `:2097` | VERIFIED: that revision is `origin/main`, 9 commits ahead |
| P7 | The suite has 614 tests | `grep -rho "@Test" Tests | wc -l` = 614, re-measured at `62ae388` | VERIFIED as an attribute count, not executed |
| P8 | 336 ms / 1.30 s / 5.31 s and 3.9x-4.1x ratios; report 1.55 s / 6.2 s | `design.md:27-36` only | UNVERIFIED, `[measured: design.md, re-measure before gate]` |
| P9 | `openspec validate --strict` is a valid command | `openspec validate --help`; change validates clean | VERIFIED |
| P10 | Plain `swift test` is the non-GUI entry; no GUI path involved | `CLAUDE.md` Testing section | VERIFIED |
| P11 | No public API or dependency change | `InlineProtector` and `replaceMatches` are private; no Package.swift edit proposed | VERIFIED by inspection |

`unverified=1` (P8).

REALITY: premise-table pass 11 premises, 10 verified, 1 timing row re-measure before gate design.md:27
REALITY: already-done finding origin/main already carries the newer pipeline and source(in:); the fix itself is not present Source/MD2Core/MarkdownRenderer.swift:2963
REALITY: surface-check pass swift test, openspec validate --strict, swiftc -O, and Scripts/benchmark_p1.swift all exist CLAUDE.md:12
REALITY: binding-decisions pass prior decisions require keeping the inline pipeline order; this plan does not reorder it TODOS.md:left-to-right delimiter ownership scan
REALITY: numbers finding timings are not re-derived; the "~240 lines" gap is 253 lines (2880 vs 3133) design.md:27
REALITY: deferred-asks finding the report's bare-URL workload is deferred as a hypothetical although origin/main already ships it design.md:25
REALITY: pr-count pass no .gstack/ship-policy.json; default is one PR, matching the plan's one-commit landing design.md:169
REALITY: units n/a no input unit or accuracy change design.md:49
REALITY: perf-table finding one-machine median-of-3, no p95, no interleaved base/branch, no steady-state case design.md:27

## Decision ledger

### R1: Base revision for the fix
Finding: SC1, P1, confidence 10/10, `Sources/MD2Core/MarkdownRenderer.swift:993` vs local `:967`; reviewer plan-eng-review.
Plan baseline: the plan as written targets local HEAD `93bde83`, with `restore(in:)` as the only restore rewrite and the test matrix in `design.md:124-141`.
Runtime evidence: local HEAD is 9 commits behind `origin/main`; `origin/main` renders a whole paragraph in one inline pass, ships `protectBareAutolinks`, and has a second quadratic restore (`source(in:)`) called per match.
Comparison grid:

| Row | Current (plan) | A) Update base first | B) Keep local HEAD | C) Pause for manual update |
|---|---|---|---|---|
| Base revision | local `93bde83`, 9 behind | `origin/main` `0a75468` | local `93bde83` | undecided |
| `source(in:)` scope (R2) | pending | pending | pending | pending |
| Bare-URL test workload (R2) | pending | pending | pending | pending |
| One-per-line pre-fix expectation | linear (task 2.4) | quadratic (matches the report) | linear (false on the target branch) | pending |
| Line-number references | local | re-baselined | local | pending |

Question D1:
D1 - Re-base this change on origin/main before implementing?
Project/branch/task: Markdown2 (Swift Markdown renderer), branch `main` (local `93bde83`, 9 commits behind `origin/main` `0a75468`); task: make inline fragment restore and match substitution linear.
ELI10: The plan was written against your local checkout, but your remote main already has nine newer commits. Those commits render a whole paragraph in one inline pass and add a bare-URL pass that calls a second quadratic restore, `source(in:)`. So the plan's "one URL per line is linear" expectation is backwards on the code you will actually ship, and the reported slow case has no test.
Stakes if we pick wrong: You could ship a fix that passes on stale code, leaves the bare-URL path quadratic on `origin/main`, and conflicts with nine commits when you pull.
Recommendation: A because the fix must target the code that ships; re-baselining now is cheaper than reconciling after implementation.
Completeness: A=10/10, B=5/10; C is a pause, no score.
Pros / cons:
A) Update the base to origin/main first, then re-baseline the plan (recommended)
  ✅ Covers `protectBareAutolinks`, `renderReferenceLinks`, and `source(in:)`, the actual reported workload.
  ✅ Makes the one-per-line test red before the fix, as the report observed, so the regression guard is real.
  ❌ All line numbers and the 14-stage pipeline table in this design must be refreshed; several task descriptions change.
B) Keep local HEAD and implement the plan as written
  ✅ No re-baselining today; the current line numbers and pipeline table stay valid.
  ✅ The fix still makes `restore` and `replaceMatches` linear on the code you are editing now, a real improvement for that revision.
  ❌ The tests would pass on stale architecture and miss the shipped bare-URL path; merge conflicts with nine commits are likely.
C) Pause this review so you can update the checkout yourself
  ✅ You control the rebase and can preserve any local work before the review continues.
  ✅ Nothing in the working tree is changed by the review while you decide.
  ❌ The review cannot finish until you return; all findings stay unverified against the target branch.
Net: A trades a one-time re-baseline for a fix that covers the code you will ship; B is cheaper today and wrong later.

Header: Base revision
Options:
A) Update the base to origin/main first, then re-baseline the plan (recommended)
Covers `protectBareAutolinks`, `renderReferenceLinks`, and `source(in:)`, the actual reported workload. Makes the one-per-line test red before the fix, as the report observed, so the regression guard is real. Requires refreshing all line numbers and the 14-stage pipeline table in this design; several task descriptions change.
B) Keep local HEAD and implement the plan as written
No re-baselining today; the current line numbers and pipeline table stay valid. The fix still makes `restore` and `replaceMatches` linear on the code you are editing now, a real improvement for that revision. The tests would pass on stale architecture and miss the shipped bare-URL path; merge conflicts with nine commits are likely.
C) Pause this review so you can update the checkout yourself
You control the rebase and can preserve any local work before the review continues. Nothing in the working tree is changed by the review while you decide. The review cannot finish until you return; all findings stay unverified against the target branch.

State: approved
Actual answer: A) Update the base to origin/main first, then re-baseline the plan (D1, user answer 2026-10-18)
Accepted scope: Fast-forward local `main` to `origin/main` and re-baseline `design.md`, `tasks.md`, `proposal.md`, and the spec to the `origin/main` symbols, line numbers, pipeline table, and one-per-line expected red state. R2 (`source(in:)` rewrite scope) remains pending.
History: none

### R2: Include the linear `source(in:)` rewrite in this change
Finding: SC2, P1, confidence 9/10, `Sources/MD2Core/MarkdownRenderer.swift:2963-2967` (now local after the D1 fast-forward); reviewer plan-eng-review.
Plan baseline: Decision 3 says every placeholder-restore loop must go through the scanner, but tasks 3.1-3.3 name only `restore(in:)`, and the test matrix in `design.md:124-141` has no bare-URL or reference-link workload.
Runtime evidence: `source(in:)` loops every entry in `sources` with `replacingOccurrences`. It is called per bare-URL candidate at `:2116`, twice per reference link at `:2053-2054`, and `restore` at `:2058` and `:2066`. The report's 1.55 s / 6.2 s workload is `protectBareAutolinks`.
Comparison grid:

| Row | Current (plan) | A) Include | B) Defer | C) Investigate |
|---|---|---|---|---|
| `source(in:)` rewrite | not tasked | linear scan over `sources` | unchanged, new TODO | pending |
| Bare-URL scaling test | absent | single-line and one-per-line | absent, new TODO | pending |
| Reference-link scaling test | absent | included | absent | pending |
| `restore` / `replaceMatches` rewrite (R1 accepted) | approved | unchanged | unchanged | unchanged |
| `source(in:)` call sites | unchanged | routed through the scanner | unchanged | pending |

Question D2:
D2 - Include the linear `source(in:)` rewrite in this change?
Project/branch/task: Markdown2, `origin/main` `0a75468`; task: make inline fragment restore and match substitution linear without leaving the reported bare-URL path quadratic.
ELI10: The slow case in the report is bare URLs. On the updated base, every bare URL calls `source(in:)`, which rescans every protected fragment to recover the author's spelling. Fixing only `restore` leaves that path quadratic. Including it means one more function on the same scanner and two more test workloads; deferring means "linear inline rendering" is false for the exact input the report measured.
Stakes if we pick wrong: Users pasting a paragraph of bare URLs still wait seconds, and the spec's linearity claim covers only the syntaxes that already existed, not the reported one.
Recommendation: A because Decision 3 already commits to routing every placeholder-restore loop through the scanner, and the two callers share the same code.
Completeness: A=10/10, B=6/10; C is a bounded investigation, no score.
Pros / cons:
A) Include `source(in:)` and its callers in this change (recommended)
  ✅ Fixes the reported 1.55 s / 6.2 s bare-URL workload, not just angle-bracket autolinks.
  ✅ One scanner serves `restore` and `source`, so the second function adds little code and one test surface.
  ❌ Adds bare-URL and reference-link workloads to the test matrix; the suite grows and needs calibration.
B) Defer `source(in:)` to a TODO; fix only `restore` and `replaceMatches`
  ✅ Smaller diff and a faster landing for the two functions already in the plan.
  ✅ The existing local syntaxes (angle autolinks, links, mailto, entities) still get linear behavior.
  ❌ The exact reported workload stays quadratic; the spec's linearity claim would not cover bare URLs.
C) Investigate first with a release probe on `origin/main`
  ✅ Measures the actual bare-URL and reference-link cost before committing scope.
  ✅ Keeps the plan honest about whether the reported numbers reproduce on this machine.
  ❌ Delays the fix; the code reading already shows the loop is per-fragment, so the probe mostly confirms magnitude.
Net: A closes the reported bug and reuses the same scanner; B is a smaller diff that leaves the headline case broken.

Header: source(in:) scope
Options:
A) Include `source(in:)` and its callers in this change (recommended)
Fixes the reported 1.55 s / 6.2 s bare-URL workload, not just angle-bracket autolinks. One scanner serves `restore` and `source`, so the second function adds little code and one test surface. Adds bare-URL and reference-link workloads to the test matrix; the suite grows and needs calibration.
B) Defer `source(in:)` to a TODO; fix only `restore` and `replaceMatches`
Smaller diff and a faster landing for the two functions already in the plan. The existing local syntaxes (angle autolinks, links, mailto, entities) still get linear behavior. The exact reported workload stays quadratic; the spec's linearity claim would not cover bare URLs.
C) Investigate first with a release probe on `origin/main`
Measures the actual bare-URL and reference-link cost before committing scope. Keeps the plan honest about whether the reported numbers reproduce on this machine. Delays the fix; the code reading already shows the loop is per-fragment, so the probe mostly confirms magnitude.

State: approved
Actual answer: A) Include `source(in:)` and its callers in this change (D2, user answer 2026-10-18)
Accepted scope: One linear scanner shared by `restore(in:)` and `source(in:)`; route the final restore and every mid-pipeline restore/source call (`protectRawHTML`, `renderImages`, `renderLinks`, `renderReferenceLinks`, `protectBareAutolinks`) through it; preserve `isLiteral`; add bare-URL (single-line and one-per-line) and reference-link scaling tests.
History: none

### R3: Link-destination scan inside `protectAutolinks`
Finding: Outside voice High, confidence 9/10 (verified by code reading), `Sources/MD2Core/MarkdownRenderer.swift:1530` calls `isInsideLinkDestination`; `:1487` scans backward to the nearest `](` over `text.startIndex..<index`. Reviewer: Codex outside voice (gpt-6-astra).
Plan baseline: the spec requires URL autolinks to scale linearly; the test matrix includes N=500/1,000 `<https://…>` autolinks; the plan's transform audit claims transforms read only their own match.
Runtime evidence: with no `](` in the workload, `range(of:options:.backwards)` scans the whole prefix for every autolink, so N autolinks cost O(N²) even after the restore and substitution rewrites. The audit claim is false for this transform: it reads the preceding prefix.
Comparison grid:

| Row | Current (plan) | A) Apply | B) Keep current | C) Investigate | D) Defer |
|---|---|---|---|---|---|
| Link-destination check | backward scan per autolink | forward pre-scan + O(1) lookup | unchanged | pending | unchanged |
| URL autolink scaling test | required | unchanged | removed or weakened | pending | narrowed |
| Spec linearity claim | includes URL autolinks | unchanged | excludes URL autolinks | pending | narrowed |
| Restore/source/`replaceMatches` rewrites (R1/R2) | approved | unchanged | unchanged | unchanged | unchanged |

Question D3:
D3 - Fix the quadratic link-destination scan in `protectAutolinks` as part of this change?
Project/branch/task: Markdown2, `origin/main` `0a75468`; task: make inline rendering linear for the reported workloads, including angle-bracket URL autolinks.
ELI10: Every angle-bracket autolink asks `isInsideLinkDestination` whether it sits inside a link destination. That check walks backward to the nearest `](`, and when there is none it walks the whole prefix. A paragraph of N autolinks therefore does N prefix walks, which is quadratic even after the restore and substitution fixes. The plan's own URL autolink scaling test would still fail.
Stakes if we pick wrong: You ship the two rewrites, the URL autolink test stays red, and the spec's linearity promise is false for the syntax the report measured first.
Recommendation: A because the test and spec already require linear URL autolinks; one forward pre-scan of `](` destinations makes the check O(1) per autolink.
Completeness: A=10/10, B=5/10; C is a bounded investigation, D=6/10.
Pros / cons:
A) Add a forward link-destination pre-scan (recommended)
  ✅ Makes the URL autolink workload actually linear and keeps the spec and test as written.
  ✅ One O(text) pass replaces N backward scans; the result is a simple interval lookup.
  ❌ Adds a helper and new edge cases (unterminated destinations, nested parens, escapes) to audit and test.
B) Keep the current scan and narrow the URL autolink claim
  ✅ No new helper; the diff stays focused on restore and substitution.
  ✅ The existing correctness tests still guard autolink output.
  ❌ The URL autolink scaling test must be removed or weakened, and the spec's linearity promise would exclude the report's first workload.
C) Investigate the exact cost with a release probe first
  ✅ Confirms the O(N²) magnitude on this machine before adding scope.
  ✅ Gives a measured before/after for the pre-scan.
  ❌ Delays the plan; the backward `range(of:)` per autolink already establishes the cost by code reading.
D) Defer the pre-scan to a TODO and keep the other rewrites
  ✅ Lands the restore and substitution fixes sooner.
  ✅ The TODO names the remaining quadratic path for a follow-up.
  ❌ The shipped renderer still hits the quadratic path on the reported URL-autolink workload; the linearity claim must be narrowed.
Net: A is the only option that keeps the plan's headline workload and its test honest.

Header: Link-destination scan
Options:
A) Add a forward link-destination pre-scan (recommended)
Makes the URL autolink workload actually linear and keeps the spec and test as written. One O(text) pass replaces N backward scans; the result is a simple interval lookup. Adds a helper and new edge cases (unterminated destinations, nested parens, escapes) to audit and test.
B) Keep the current scan and narrow the URL autolink claim
No new helper; the diff stays focused on restore and substitution. The existing correctness tests still guard autolink output. The URL autolink scaling test must be removed or weakened, and the spec's linearity promise would exclude the report's first workload.
C) Investigate the exact cost with a release probe first
Confirms the O(N²) magnitude on this machine before adding scope. Gives a measured before/after for the pre-scan. Delays the plan; the backward `range(of:)` per autolink already establishes the cost by code reading.
D) Defer the pre-scan to a TODO and keep the other rewrites
Lands the restore and substitution fixes sooner. The TODO names the remaining quadratic path for a follow-up. The shipped renderer still hits the quadratic path on the reported URL-autolink workload; the linearity claim must be narrowed.

State: approved
Actual answer: A) Add a forward link-destination pre-scan (D3, user answer 2026-10-18)
Accepted scope: Precompute `](` destinations once per `protectAutolinks` pass so `isInsideLinkDestination` is O(1) per autolink; preserve nearest-opener semantics (unterminated destination, nested parens, escapes); keep the URL autolink scaling case and add edge-case tests for the pre-scan.
History: none

### R4: Compatibility policy for author text that constructs a token
Finding: Outside voice High, confidence 8/10 (verified by code reading), `Sources/MD2Core/MarkdownRenderer.swift:1423` (escaped punctuation becomes a fragment), `:2977` (old descending whole-text replacement). Reviewer: Codex outside voice (gpt-6-astra).
Plan baseline: proposal and design promise "byte-identical" output and "author text containing private-use characters is preserved exactly"; the spec scenario says author text that resembles a token stays literal.
Runtime evidence: with sentinel `S` = U+E000, Markdown `` `x` SMD2\-0S `` creates code fragment 0 and escaped-hyphen fragment 1. The old descending `restore` expands fragment 1 first, forming token 0, then expands it to `<code>x</code>`. The new one-pass scanner parses the authored sentinel before the hyphen, sees a malformed token, emits it literally, later replaces fragment 1, and never re-scans the formed token. Shared-sentinel overlaps (`SMD2-1SMD2-10S`) also resolve by highest index in the old code and leftmost token in the new scanner.
Comparison grid:

| Row | Current (plan) | A) Accept new semantics | B) Preserve old | C) Investigate | D) Defer resolver |
|---|---|---|---|---|---|
| Token formed after escape restoration | old expands; new literal | literal, documented | expanded, byte-identical | pending | old behavior |
| Shared-sentinel overlap | old highest-index priority | leftmost wins, documented | old priority preserved | pending | old behavior |
| Byte-identical claim | all documents | documents without private-use text | all documents | pending | all documents |
| Resolver rewrite (R1/R2) | approved | unchanged | unchanged | unchanged | reverted to old loops |

Question D4:
D4 - Which compatibility policy should the resolver use for author text that constructs a token?
Project/branch/task: Markdown2, `origin/main` `0a75468`; task: replace the per-fragment restore loops with one linear resolver while deciding what happens to adversarial private-use text.
ELI10: The old code replaces tokens one index at a time over the whole text, so an author who types private-use characters plus an escaped hyphen can make a new token appear after the hyphen is restored; the old code then expands it. The new single scan does not re-read its own output, so that constructed token stays literal. The same kind of input can share a sentinel between two tokens, where the old code gives the higher index priority and the new scanner gives the leftmost token priority. These inputs require typed U+E000 characters, but the plan currently promises byte-identical output for all documents.
Stakes if we pick wrong: Either the "byte-identical" claim is false and a conformance test could catch it late, or the resolver grows a re-scan/fallback that reintroduces the quadratic worst case the change exists to remove.
Recommendation: A because the input is adversarial, the old expansion is incidental, and preserving it exactly needs a re-scan that undermines the linear guarantee; document the boundary and pin it with tests.
Completeness: A=10/10, B=9/10; C is an investigation, D=3/10.
Pros / cons:
A) Accept the new literal semantics and document the boundary (recommended)
  ✅ Keeps the one-pass resolver linear and makes the private-use boundary explicit.
  ✅ Matches the spec's "author text that resembles a token stays literal" direction.
  ❌ Changes output for adversarial documents that construct a token via an escape; the byte-identical claim must be narrowed.
B) Preserve the old expansion semantics exactly
  ✅ Keeps byte-identical output for every adversarial input.
  ✅ The common path stays linear; the fallback can reuse the old algorithm.
  ❌ Adds a re-scan or fallback whose worst case is quadratic, plus more code and tests.
C) Investigate the exact differences with a throwaway probe first
  ✅ Enumerates the real differences on adversarial inputs before committing to a policy.
  ✅ Produces concrete inputs for the characterization tests.
  ❌ Delays the resolver implementation; the code reading already shows the difference.
D) Defer the resolver rewrite and keep the old loops
  ✅ Keeps the diff small and avoids the compatibility question today.
  ✅ `replaceMatches` still becomes linear.
  ❌ Leaves `restore` and `source` quadratic, which is the main defect; the plan's headline goal is not met.
Net: A keeps the linear resolver honest and bounds the behavior change to adversarial private-use input; B buys exact compatibility at the cost of the guarantee.

Header: Token compatibility
Options:
A) Accept the new literal semantics and document the boundary (recommended)
Keeps the one-pass resolver linear and makes the private-use boundary explicit. Matches the spec's "author text that resembles a token stays literal" direction. Changes output for adversarial documents that construct a token via an escape; the byte-identical claim must be narrowed.
B) Preserve the old expansion semantics exactly
Keeps byte-identical output for every adversarial input. The common path stays linear; the fallback can reuse the old algorithm. Adds a re-scan or fallback whose worst case is quadratic, plus more code and tests.
C) Investigate the exact differences with a throwaway probe first
Enumerates the real differences on adversarial inputs before committing to a policy. Produces concrete inputs for the characterization tests. Delays the resolver implementation; the code reading already shows the difference.
D) Defer the resolver rewrite and keep the old loops
Keeps the diff small and avoids the compatibility question today. `replaceMatches` still becomes linear. Leaves `restore` and `source` quadratic, which is the main defect; the plan's headline goal is not met.

State: approved
Actual answer: A) Accept the new literal semantics and document the boundary (D4, user answer 2026-10-18)
Accepted scope: The one-pass resolver emits a token formed only after an escape restoration literally, and resolves shared-sentinel overlaps by the leftmost well-formed token; the byte-identical guarantee is narrowed to documents without private-use sentinel characters; characterization tests pin both cases.
History: none

Approval readiness: PASS - R1 (D1 A), R2 (D2 A), R3 (D3 A), R4 (D4 A); all accepted scope is folded into design.md, tasks.md, proposal.md, and spec.md. Re-check at `62ae388`: PASS; no decisions reopened.

## Review Findings

Branch note: re-checked at HEAD `62ae388` (equal to `origin/main`). Since the D1 base `0a75468`, the only commit is `62ae388` (repo owner; MD2App document-open behavior, Docs, README, and one GUI test suite). `Sources/MD2Core/MarkdownRenderer.swift` is unchanged, so every line number in this plan still matches.

### Scope Challenge

- **[SC1] [P1] (confidence: 10/10) - stale base** - resolved by D1. Local HEAD was 9 commits behind `origin/main`; the shipped branch already had the whole-paragraph inline pass, `protectBareAutolinks`, `renderReferenceLinks`, and `source(in:)`. Disposition: accepted, base fast-forwarded and plan re-baselined.
- **[SC2] [P1] (confidence: 9/10) - `source(in:)` missing from scope** - resolved by D2. The bare-URL and reference-link paths stayed quadratic without it. Disposition: accepted, included in the resolver and test matrix.
- **[SC3] [P2] (confidence: 8/10) - perf evidence is pre-rebase single-machine median** - accepted as `[re-measure before gate]`; task 5.2 records interleaved numbers.
- **[SC4] [P3] (confidence: 8/10) - stale transform audit list** - accepted; the audit now names every call site and the two non-local transforms.
- **[SC5] [P3] (confidence: 7/10) - no token-lifecycle diagram** - accepted; a diagram was added to Decision 1.
- **[SC6] [P3] (confidence: 7/10) - duplicate scanners** - accepted; Decision 1 uses one resolver for `fragments` and `sources`.

Scope Challenge result: **scope accepted as-is** with approved additions D2 (source lookup, bare URLs, reference links) and D3 (autolink destination pre-scan). No scope reduction.

### Architecture Review

- **[A1] [P2] (confidence: 9/10)** `Sources/MD2Core/MarkdownRenderer.swift:1940` - `renderImages` calls `assignFigure`, so the current reversed match order is observable in figure numbering. A forward builder would renumber figures. Disposition: accepted; Decision 2 buffers transforms in the current descending order and assembles forward.
- **[A2] [P3] (confidence: 8/10)** `Sources/MD2Core/MarkdownRenderer.swift:1486` - `isInsideLinkDestination` reads the preceding prefix, so the plan's "transforms read only their own match" claim was false. Disposition: accepted; Decision 6 adds the pre-scan and the audit names the prefix reader.

No other architecture issues after the D3/D4 folds.

### Code Quality Review

- **[C1] [P3] (confidence: 8/10)** `Sources/MD2Core/MarkdownRenderer.swift:2949` - the `InlineProtector` class comment still describes one array and one restore. Disposition: accepted; task T8 updates it.
- **[C2] [P3] (confidence: 8/10)** `openspec/changes/fix-quadratic-inline-rendering/design.md:141` - the transform contract sentence claimed all transforms are purely local. Disposition: accepted; the sentence now names `renderImages` and `protectAutolinks`.

No shared-code extraction beyond the approved single resolver; `renderReferenceLinks` stays manual because it is a different control flow.

### Test Review

Coverage diagram:

```
CODE PATHS                                            USER FLOWS
[+] InlineProtector resolver                          [+] Render a URL-heavy paragraph
  ├── [★★★] fast path no sentinel — existing + edge     ├── [★★★] one line, many URL autolinks — new scaling
  ├── [★★★] canonical token scan — scaling + edge      ├── [★★★] one URL per line — new one-per-line
  ├── [★★★] leading zero/malformed/out-of-range        ├── [★★★] bare URLs with entities — new
  ├── [★★★] forward reference/constructed/shared       └── [★★★] reference links with protected keys — new
  └── [★★★] sources expansion — new entity cases      [+] Unsafe URLs stay inert — P1 existing
[+] replaceMatches builder                            [+] Figure numbering
  ├── [★★★] zero matches — existing passes              └── [★★★] two labeled images — new
  ├── [★★★] many matches — new scaling
  ├── [★★★] buffered transform order — new two-figure
  └── [★★★] cursor guard — existing + new edge
[+] isInsideLinkDestination pre-scan
  ├── [★★★] no opener/open/closed — new
  ├── [★★★] nested/escaped parens — new
  └── [★★★] unterminated/multiple — new

Legend: ★★★ behavior + edge + error  |  ★★ happy path  |  ★ smoke check
COVERAGE: 20/20 planned paths tested (100%)  |  GAPS: 0 after the OV4 and D3/D4 folds
```

- **[T1] [P2] (confidence: 8/10)** `design.md:163-168` - plain bare-URL and reference-link cases take the sentinel-free fast path in `source(in:)`; the entity-bearing variants now exercise expansion. Disposition: accepted (OV4).
- **[T2] [P3] (confidence: 7/10)** `design.md:182` - Swift Testing may run other suites concurrently; the ratio is primary and min-of-3 reduces spikes. No further action beyond the documented mitigation.
- **[T3] [P3] (confidence: 6/10)** zero-match identity return has no direct test; many existing passes exercise the no-match path. Disposition: no new test (fails the value bar).

Test framework: Swift Testing via plain `swift test`; GUI suites are not involved.

### Performance Review

- **[P1] [P2] (confidence: 8/10)** `design.md:32-39` - the timing table is pre-rebase, single-machine, median-of-3, with no p95 or interleaved base/branch runs. Disposition: accepted; tagged `[re-measure before gate]`, task 5.2.
- **[P2] [P3] (confidence: 7/10)** `design.md:170-172` - absolute ceilings are tentative debug-build values. Disposition: accepted; calibrate during implementation, keep the 3x ratio primary.
- **[P3] [P3] (confidence: 7/10)** `design.md:124-137` - `reserveCapacity(source.utf8.count)` underestimates replacement-heavy results; reallocation is amortized linear. Disposition: no change.

No N+1 or database paths. Memory is one output string per resolver call plus one replacement array per `replaceMatches` pass.

### Outside Voice

The Codex outside review (gpt-6-astra) completed and returned:

```
- High — Forward evaluation changes figure numbering. The transform audit overlooks shared-state mutations: renderImages calls assignFigure, which increments a counter. Two labeled images in one paragraph currently execute right-to-left; the proposed builder reverses their numbering and subsequent reference mappings. Preserve transform evaluation order by buffering replacements, then assemble forward, or explicitly approve this behavior change.
- High — The autolink workload retains another quadratic scan. Every angle autolink calls isInsideLinkDestination, which searches its entire preceding prefix for `](`. With no opener anywhere, N autolinks scan progressively longer prefixes: O(N²), even after both proposed rewrites. The audit's claim that transforms read only their own match is false.
- High — The resolver is not equivalent to descending replacement. Authored text can contain token spellings, so append-only storage does not establish the claimed token-free induction. A token formed only after an escaped hyphen is restored is expanded by the old descending replacement but left literal by the proposed scanner; tokens sharing a sentinel also resolve differently because index priority becomes leftmost priority.
- Medium — The new source-lookup scaling cases bypass source expansion. Plain bare URLs and `[label N][refN]` contain no protected tokens in the strings passed to source(in:); after the rewrite, every call takes the sentinel-free fast path. Add scaled URLs containing entities and reference keys/labels containing protected content, with exact recovered-output checks.
```

Dispositions:
- **OV1 High (figure numbering)** - verified at `MarkdownRenderer.swift:1940` and `CrossReferenceContext.swift:42`; accepted. Decision 2 buffers transforms in the current descending order and assembles forward; the two-figure test pins the numbering.
- **OV2 High (`isInsideLinkDestination`)** - verified at `:1530` and `:1487`; resolved by D3 (A, forward pre-scan). The URL-autolink scaling case stays as written.
- **OV3 High (token compatibility)** - verified at `:1423` and `:2977`; resolved by D4 (A, new literal semantics for constructed and shared-sentinel tokens; byte-identical claim narrowed and pinned by tests).
- **OV4 Medium (source-expansion test bypass)** - accepted; the scaling matrix now includes entity-bearing bare URLs and reference keys with exact recovered-output checks.

Cross-model tension: none unresolved. The native review and Codex agreed on the quadratic restore and substitution paths; Codex uniquely found OV1, OV2, OV3, and OV4, and all four were verified in the code and folded.

### NOT in scope

- Changing any inline syntax, matching rule, or rendered output for documents without private-use sentinel characters.
- Fixing the pre-existing right-to-left figure numbering; it is pinned, not changed.
- Optimizing `HTMLSafety.decodeEntities` or other linear-scan helpers.
- Preview JavaScript/CSS, PDF/Print/HTML export, GUI-only paths, or committed benchmark documentation.

### What already exists

- `P1RegressionTests.encodedActiveURLsAreInert` covers entity-obfuscated unsafe URLs; `unclosedBracketsHaveBoundedCost` is the timing-test precedent.
- `CommonSyntaxTests.bareLinks`, `autolinksRespectBoundariesAndProtectedContent`, `referenceFormsNormalizationAndFirstDefinition`, and `referencesCannotNestOrActivateUnsafeURLs` cover bare-URL and reference-link correctness.
- The conformance corpus and the 614-test suite are the broad output-equivalence guard.
- `Scripts/benchmark_p1.swift` is the release-probe layout; it needs the fragment workloads added for task 1.1/5.2.

### Failure modes

- **Malformed or out-of-range token**: emitted literally; covered by new edge tests. Users see the author's text, not a crash.
- **Link-destination misclassification**: an autolink rendered as text or a plain angle-bracket URL; the correctness anchor counts and destination edge tests catch it.
- **Figure renumbering**: visible wrong numbers; the two-figure test catches it before merge.
- **D4 constructed token**: declared behavior change; the characterization tests pin it.
- **Silent timing regression on a loaded CI**: the ratio is the guard; if it flakes, the suite is isolated or ceilings rise, never the ratio.

Critical gaps: 0.

### Worktree parallelization strategy

Sequential implementation, no parallelization opportunity. One primary module (`Sources/MD2Core/MarkdownRenderer.swift`) plus one new test file; every task touches the same resolver or its verification.

## Implementation Tasks

Synthesized from this review's findings. Each task derives from a specific finding above. Run with Claude Code or Codex; checkbox as you ship.

- [ ] **T1 (P1, human: ~3h / CC: ~20min)** - MD2Core - implement the shared linear resolver for `restore(in:)` and `source(in:)`
  - Surfaced by: Scope Challenge SC2 and Decision D2 - per-fragment whole-text loops at `:2963` and `:2977`
  - Files: `Sources/MD2Core/MarkdownRenderer.swift`
  - Verify: new resolver edge tests; `swift test --filter InlineRenderingPerformanceTests`
- [ ] **T2 (P1, human: ~2h / CC: ~15min)** - MD2Core - precompute link-destination ranges for autolink classification
  - Surfaced by: Outside Voice OV2 and Decision D3 - backward scan at `:1487`, called per autolink at `:1530`
  - Files: `Sources/MD2Core/MarkdownRenderer.swift`
  - Verify: destination edge tests and the URL-autolink scaling case
- [ ] **T3 (P1, human: ~2h / CC: ~15min)** - MD2Core - buffer `replaceMatches` transforms in the current order and assemble forward
  - Surfaced by: Outside Voice OV1 - `renderImages` `assignFigure` at `:1940`
  - Files: `Sources/MD2Core/MarkdownRenderer.swift`
  - Verify: two-figure numbering test; full `swift test`
- [ ] **T4 (P1, human: ~4h / CC: ~30min)** - MD2CoreTests - add the scaling suite with bare-URL, entity, and reference-key workloads
  - Surfaced by: Test Review T1 and Outside Voice OV4 - scaling coverage for `source(in:)` expansion
  - Files: `Tests/MD2CoreTests/InlineRenderingPerformanceTests.swift`
  - Verify: suite is red before the implementation and green after it
- [ ] **T5 (P2, human: ~3h / CC: ~20min)** - MD2CoreTests - add characterization and edge tests for tokens, figures, and link destinations
  - Surfaced by: Scope Challenge SC5, Outside Voice OV3/OV4 - D4 boundary, figure numbering, classifier edge cases
  - Files: `Tests/MD2CoreTests/InlineRenderingPerformanceTests.swift`
  - Verify: all edge tests pass; D4 boundary is pinned
- [ ] **T6 (P2, human: ~1h / CC: ~10min)** - MD2Core - route every mid-pipeline restore/source call through the resolver
  - Surfaced by: Scope Challenge SC2 - nine call sites
  - Files: `Sources/MD2Core/MarkdownRenderer.swift`
  - Verify: P1, reference-link, bare-URL, and link/image suites
- [ ] **T7 (P3, human: ~1h / CC: ~10min)** - MD2Core - re-measure the release probe on the re-baselined checkout
  - Surfaced by: Performance Review P1/SC3 - pre-rebase timings
  - Files: `Scripts/benchmark_p1.swift`
  - Verify: before/after table for all workloads and the one-per-line cases
- [ ] **T8 (P3, human: ~15min / CC: ~3min)** - MD2Core - update the `InlineProtector` doc comment
  - Surfaced by: Code Quality Review C1 - class comment at `:2949`
  - Files: `Sources/MD2Core/MarkdownRenderer.swift`
  - Verify: comment names the three arrays, the shared resolver, and the D4 boundary

## Unresolved decisions

None. D1-D4 are approved and folded; no choice is pending.

## Completion summary

- Step 0: Scope Challenge - scope accepted as-is, with approved additions D2 (source lookup, bare URLs, reference links) and D3 (autolink destination pre-scan).
- Reality rows: 9/9 applicable rows emitted (premise-table, already-done, surface-check, binding-decisions, numbers, deferred-asks, pr-count, units, perf-table); 1 unverified premise (pre-rebase timings).
- Architecture Review: 2 issues found (stateful transform order; prefix-reading classifier).
- Code Quality Review: 2 issues found.
- Test Review: diagram produced, 1 gap identified (source-expansion coverage), resolved.
- Performance Review: 1 issue found (re-measure interleaved).
- NOT in scope: written.
- What already exists: written.
- TODOS.md updates: 0 items proposed (the existing TODOs are unrelated; D3/D4 close the two new gaps).
- Failure modes: 0 critical gaps flagged.
- Unresolved decisions: 0 in this review.
- Outside voice: Codex (gpt-6-astra), completed; 3 High and 1 Medium, all verified and folded.
- Parallelization: 1 lane, 0 parallel / 1 sequential.
- Lake Score: 4/4 = answers picking a 10/10 option (D1 A=10, D2 A=10, D3 A=10, D4 A=10) / 4 scored.
- Re-check at `62ae388`: renderer unchanged since `0a75468`; 0 new issues; test count corrected from 543 to 614; no decisions reopened.

## Re-review at 62ae388

Trigger: the user reported that main changed after the 2026-10-18 review.

Evidence:
- `git rev-list --left-right --count HEAD...origin/main` = `0 0`; HEAD `62ae388`.
- `git log --oneline 0a75468..HEAD -- Sources/MD2Core/MarkdownRenderer.swift` is empty. The renderer is unchanged.
- `62ae388` touches `Docs/DocumentLifecycle.md`, `README.md`, `README.zh-CN.md`, `Sources/MD2App/MD2AppDelegate.swift`, `Tests/MD2CoreTests/SettingsWindowPresentationGUITests.swift`, and `openspec/specs/document-recovery/spec.md`. None is on the plan's path.
- Key symbols still at the planned lines: `isInsideLinkDestination` `:1486`, `protectAutolinks` `:1526` (call at `:1530`), `replaceMatches` `:2846`, `source(in:)` `:2963`, `restore(in:)` `:2977`, `renderImages` `assignFigure` `:1940`.
- `openspec validate fix-quadratic-inline-rendering --strict` passes.
- Test count re-measured: `grep -rho "@Test" Tests | wc -l` = 614; the plan said 543, the stale pre-fast-forward count. Corrected in the constraint and premise table.
- Sections 1-4: no new findings. The prior A1/A2, C1/C2, T1-T3, and P1-P3 dispositions remain valid.
- Outside voice: reused from the 2026-10-18 Codex run. The plan and renderer are unchanged, so its four findings remain folded; no new outside findings.
- Approval readiness: PASS; no decisions reopened.

Scope Challenge result: **scope accepted as-is**; no scope change and no new decision. The complexity gate stays skipped (2 files, 0 new classes).

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Outside Review | Codex (plan-review) | Independent 2nd opinion | 7 | completed | 3 High, 1 Medium (reused) |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 10 | CLEAN | 0 new; prior 4 folded |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

- **OUTSIDE COVERAGE:** Codex (gpt-6-astra), plan-review, completed on 2026-10-18; reused for this re-check because the plan and renderer are unchanged.
- **CROSS-MODEL:** No new tension. The prior Codex findings (figure numbering, link-destination scan, token boundary, source-expansion tests) remain folded.
- **VERDICT:** ENG CLEARED - re-checked at `62ae388`; 0 new issues, prior 4 folded; ready to implement.

NO UNRESOLVED DECISIONS

