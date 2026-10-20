## Context

Bare-URL autolinking is implemented in `MarkdownRenderer.protectBareAutolinks` (`Sources/MD2Core/MarkdownRenderer.swift:2085-2134`; line numbers below are pre-change). It runs late in the inline pipeline (stage 15 of 18), after code/math/entity/angle-autolink protection and after explicit links/images/reference links, matches candidates with one cached `NSRegularExpression` (`MarkdownRegex.expression`), then post-processes each match:

- **Match pattern** (`:2086`, pre-change): `(?<![^\s*_~(])(?:https?://|www\.)[^\s<>]+|...email...`. The URL alternative is (a) a left-boundary lookbehind that permits only start-of-text, whitespace, `*`, `_`, `~`, `(` and (b) a body that consumes everything up to whitespace or `<`/`>`.
- **Token cut** (`:2088-2101`): the candidate is truncated at the first non-literal placeholder token; literal tokens (entities) are skipped.
- **Trailing cleanup** (`:2105-2121`): strips ASCII `?!.,:*_~`, unmatched `)` (via an excess-closer count), and trailing entity spellings.
- **Domain validation** (`:2122-2128`): the host must be dot-separated letters/digits/`-`/`_`; failure returns the candidate unchanged (literal text).
- **Destination assembly** (`:2130-2132`): `www.` gains `http://`, email gains `mailto:`, and the destination/text are entity-decoded and escaped.

This is the literal GFM extension rule: boundaries and terminators are ASCII-only. In Chinese prose, URLs are written flush against full-width punctuation, producing three distinct failures:

1. **Swallowed punctuation.** `https://example.com/docs，然后继续。` matches with the whole tail in the body; the trailing cleanup only knows ASCII, so the anchor text and destination contain `，然后继续。`.
2. **Lost link.** `https://example.com，然后继续。` swallows the same tail, the domain becomes `example.com，然后继续。`, domain validation rejects it, and the candidate is emitted as plain text.
3. **Missing left boundary.** Han characters or full-width punctuation before the scheme (`访问https://…`, `链接：https://…`, `（https://…）`) fail the lookbehind, so those URLs are never candidates.

The report adds two adjacent cases the review requires this change to handle or declare:

- **Zero-width space (U+200B)** is not `\s`, not Han, and not punctuation. `\u{200B}https://…` stays literal; `https://…\u{200B}tail` swallows the character and `tail`, then fails domain validation. U+200B is common in text copied from the web.
- **Entity-encoded punctuation** is protected as a literal token at stage 5, before this pass. `https://example.com/a&#xff0c;然后` keeps the decoded `，` inside the destination; `&#xff1a;https://example.com` has a token before the scheme and stays literal. These are the existing entity-recovery semantics, not literal-character boundaries.

The rendered output for ASCII documents is correct today, and the GFM corpus (`gfm-0.29.extensions.spec.json`, `Autolinks (extension)`, examples 621-631) is ASCII-only, so the fix must leave all of it unchanged.

The support contract is the machine-checked matrix at `Tests/MD2CoreTests/Matrix/compatibility-matrix.json`; `Docs/CompatibilityMatrix.md` is generated from it by `CompatibilityMatrixDoc` and pinned by `CrossArtifactConsistencyTests.generatedMatrixDocIsCommittedAndCurrent`. `Docs/MarkdownSupport.md` is hand-maintained prose with no phrase guard today. The `gfm-autolinks` entry currently declares trailing-punctuation cleanup and a `known-incomplete` corpus relationship (GFM#628/GFM#631 diverge because `ftp://` is not autolinked).

## Goals / Non-Goals

**Goals:**

- Terminate bare URLs before literal CJK/typographic punctuation and U+200B, leaving those characters outside the anchor.
- Accept Han characters, the same boundary set, and U+200B as valid left boundaries.
- Keep Han text inside URL paths; declare hostname absorption accurately where there is no path separator.
- Scope the rule to literal source characters and pin the entity-spelling exceptions.
- Declare the rule and its trade-offs in the compatibility matrix, its generated doc, and `Docs/MarkdownSupport.md`, with guards on the matrix entry and the support doc.
- Pin every normative range endpoint and the reported cases with default-suite tests.

**Non-Goals:**

- Email autolink boundaries. The email alternative keeps `(?<![\w.+\-])`; since `\w` includes Han, `联系foo@example.com` still does not link.
- Kana/Hangul left boundaries. Only Han is added; the same mechanism extends later.
- Preventing hostname absorption. It is a declared trade-off; restricting the authority to ASCII/IDN is a separate behavior change.
- Entity-aware punctuation detection. Entity spellings keep existing recovery semantics.
- ASCII punctuation mid-URL, IDN/percent-encoding normalization, preview click handling.
- Angle-bracket autolinks, Markdown link destinations, reference definitions.
- Any GUI/PDF/print/export path or public API change.

## Decisions

### D1: Extend the existing regex instead of adding a post-match pass

Add the boundary set to the body's negated character class and the Han/punctuation/U+200B characters to the left-boundary lookbehind. Chosen over "match broadly, then trim and re-check" because the lost-link case fails inside domain validation after the body has already consumed the text; a trim pass would have to reimplement the domain check and coordinate with the token cut and entity recovery. One regex keeps candidate selection, termination, and boundary in one place and preserves the existing post-processing unchanged.

### D2: One canonical boundary-character definition used by both rules

Define a single module-internal constant, `bareURLBoundaryCharacters` (renamed from the earlier `cjkURLPunctuation` because it now includes U+200B; module-internal rather than file-private so `boundaryConstantMatchesSampleTable` can compare it through `@testable import`, not public API). The left-boundary lookbehind uses the full constant; the URL body uses `bareURLBodyTerminators`, the constant minus the structural lookalikes `．／＃＠？`, which remain valid left boundaries so a lookalike cannot retarget a shorter host. Interpolate both into the raw-string pattern with `\#(...)`. The normative content:

- U+00B7 `·`
- U+2013–U+2014 `–—`
- U+2018–U+201D `‘’‚‛“”`
- U+2026 `…`
- U+3001–U+3003 `、。〃`
- U+3008–U+3011 `〈〉《》「」『』【】`
- U+3014–U+301F `〔〕〖〗〘〙〚〛〜〝〞〟`
- U+3030 `〰`, U+303D `〽`, U+30FB `・`
- U+FF01–U+FF0F `！＂＃＄％＆＇（）＊＋，－．／`
- U+FF1A–U+FF20 `：；＜＝＞？＠`
- U+FF3B–U+FF40 `［＼］＾＿｀`
- U+FF5B–U+FF65 `｛｜｝～｟｠｡｢｣､･`
- U+200B ZERO WIDTH SPACE

Full-width letters and digits (U+FF10–U+FF19, U+FF21–U+FF3A, U+FF41–U+FF5A) are content, not punctuation, and are not in the set. The set contains no ASCII characters, so it is safe inside a regex character class; the existing `bareLinks` tests fail if a future edit breaks the pattern (a nil regex makes `replaceMatches` return the source unchanged and all bare links disappear). Two literal classes were rejected because drift between them shows up only in edge cases.

### D3: Keep the complement-lookbehind shape; add Han via `\p{sc=Han}`

The left boundary stays `(?<![^<allowed>])` — a fixed-width, one-character negative lookbehind over the complement of the allowed set. Add `\p{sc=Han}` and the boundary constant to `<allowed>`. Chosen over a positive `(?<=^|[...])` lookbehind because ICU lookbehind is fixed-length; the complement form is what the code already uses and was verified under `NSRegularExpression`.

Resulting URL alternative (conceptually, with `B` the boundary constant):

```
(?<![^\s*_~(\p{sc=Han}B)])(?:https?://|www\.)[^\s<>B]+
```

`\p{sc=Han}` covers Han ideographs only, not the whole Unicode letter category, so ASCII letters before a scheme still block the match (`abchttps://…` stays literal) and full-width Latin letters do not create a link.

### D4: Exclude the boundary set from the URL body, not all non-ASCII

The body class excludes whitespace, `<`, `>`, and `B`; it does not exclude Han or other non-punctuation characters. This keeps `https://zh.wikipedia.org/wiki/北京` linked while cutting at `。`. "Terminate at any non-ASCII character" was rejected because it breaks the Wikipedia case.

### D5: Literal-only contract; entity spellings keep existing semantics

The terminator and left-boundary rules apply to literal source characters. Entities are protected before this pass; the token cut skips literal tokens and `source(in:)` recovers the authored spelling, so an entity-encoded terminator stays in the destination and an entity-encoded left boundary keeps the URL literal. Entity-aware detection was rejected: it would require decoding or mirroring the token grammar in the boundary check and risks the token cut, domain validation, and entity recovery. The spec pins both entity cases so the exception is explicit.

### D6: Name hostname absorption correctly

`https://example.com然后继续` has no `/`, `?`, or `#` after the authority, so the domain validator accepts `example.com然后继续` as the host. The link targets that absorbed hostname, not a path under `example.com`. `https://example.com/wiki/北京` is the path case and stays a path under `example.com`. Preventing absorption was rejected as a separate behavior change; this change corrects the documentation and pins both cases. The new Han left boundary makes the hostname case reachable in more prose (`访问https://example.com然后继续`), so it must be tested, not just described.

### D7: U+200B is both a terminator and a left boundary

Add U+200B to the same shared set. `https://example.com\u{200B}tail` ends before the character; `\u{200B}https://example.com` links; the authored character stays outside the anchor and is not deleted or normalized. Normalizing U+200B to whitespace was rejected because it mutates authored text; terminator-only was rejected because it fixes half the case.

### D8: Email autolinks are untouched

The email alternative has a different left-boundary rule and consumes only domain characters, so CJK punctuation does not leak into an email link the way it does into a URL. Widening its left boundary would change a second contract; it is recorded as a non-goal.

### D9: Declare the divergence in matrix text; do not reclassify the section

Edit `Tests/MD2CoreTests/Matrix/compatibility-matrix.json`:
- `declaredBehavior` gains: bare URLs end at CJK/typographic punctuation (including full-width forms) and U+200B; Han text remains valid inside URL paths.
- `boundary` gains: Han characters and the boundary set are valid left boundaries, an intentional adjustment to GFM; URL truncation, hostname absorption (`example.com然后`), and the literal-only entity exception; email boundaries unchanged.

Keep `tier: "Supported"` and `baselineRelationship: "known-incomplete"`. The vendored GFM examples are ASCII, so the divergence has no corpus example to pin; flipping the section to `intentional-divergence` would relabel the genuinely incomplete `ftp://` example (GFM#628) and contradict the baseline semantics. The matrix spec's "intentional divergence is visible" requirement is satisfied by the declared text, and a stable-token test (`full-width`, `left boundar`, `intentional`, `gfm`, `u+200b`) asserts it cannot be silently dropped.

Regenerate `Docs/CompatibilityMatrix.md` with `MD2_REGENERATE_DOCS=1 swift test --filter CrossArtifactConsistencyTests` after editing the JSON. Update the autolinks bullet in `Docs/MarkdownSupport.md` by hand and add a phrase guard (`full-width`, `U+200B`, `hostname`) to `CrossArtifactConsistencyTests`.

### D10: Test placement and range coverage

Extend the parameterized `bareLinks` table in `Tests/MD2CoreTests/CommonSyntaxTests.swift` (trailing-dot row) and add focused tests for:

- the four reported inputs;
- one terminator and one left-boundary character per normative range, using both endpoints where a range has typo risk (`–—`, `‘”`, `、〃`, `〈】`, `〔〟`, `！／`, `：＠`, `［｀`, `｛･`) plus the singletons (`·`, `…`, `〰`, `〽`, `・`, U+200B);
- `www.` variants;
- hostname vs path absorption;
- entity exceptions;
- negative ASCII boundaries (`abchttps`, `abcwww` is asserted in `asciiIdentifierBoundariesStillBlock`).

Do not duplicate assertions already covered by `autolinksRespectBoundariesAndProtectedContent` (`:110-129`) or `multilineLabelsCodeRunsAndStyledAutolinks` (`:172-184`). Keep the suite in the default `swift test` path; this is shared `MD2Core` code with no GUI flag.

### D11: Performance wording is an estimate, not a measurement

The pass remains one cached regex plus the same post-processing; the character class grows by ~75 code points and U+200B. No new scan, allocation loop, or unbounded structure is added, so the asymptotic cost is unchanged. This is an estimate; no benchmark is added. The design and matrix text must not claim a measured "no performance impact."

### D12: Lookalike continuations stay literal

A candidate whose visible continuation would change the apparent authority is left literal. The guard applies when the authority (host with optional port) ends the URL (no path, query, or fragment). It normalizes the visible continuation first: protected tokens/entities/escapes are restored, inline HTML is stripped, invisible format characters are skipped, and IDNA/fullwidth forms are folded. It then blocks any ASCII `@` before the next delimiter/whitespace, an IDNA dot before an ASCII or fullwidth host label, or a fullwidth percent before `2e`. Ordinary prose continuations (`https://example.com。然后`, `https://example.com：然后`, `https://example.com％然后`, `https://example.com\u{200B}tail`, `https://example.com<em>end</em>`) stay linked. Chosen over normalizing the whole URL: the guard is local, keeps the reported prose cases, and blocks the retargeting class.

## Boundary / body asymmetry

```text
source text
  │
  ├─ code spans, math, entities, angle autolinks, raw HTML → placeholder tokens
  ├─ explicit links, images, reference links → protected
  ├─ escapeHTML
  └─ protectBareAutolinks
        │
        ├─ left boundary: start | \s | * _ ~ ( | \p{sc=Han} | B
        ├─ scheme:        https?:// | www.
        ├─ body:          [^\s<>B]+          ← B terminates here
        ├─ token cut:     first non-literal placeholder token (literal entities skipped)
        ├─ cleanup:       ASCII ?!.,:*_~ | excess ')' | trailing entity
        ├─ domain check:  dot-separated letters/digits/-/_
        └─ anchor (<a href>) or literal candidate

B = U+00B7, U+2013–U+2014, U+2018–U+201D, U+2026,
    U+3001–U+3003, U+3008–U+3011, U+3014–U+301F, U+3030, U+303D, U+30FB,
    U+FF01–U+FF0F, U+FF1A–U+FF20, U+FF3B–U+FF40, U+FF5B–U+FF65,
    U+200B
```

## Risks / Trade-offs

- **Legitimate URL truncation.** A URL that really contains `·`, an en/em dash, a curly quote, full-width punctuation, or U+200B now ends there. Declared intentional divergence; per-range endpoint tests pin it.
- **Hostname absorption.** `https://example.com然后继续` links to host `example.com然后继续`; `访问https://example.com然后继续` becomes such a link. Declared, documented, and pinned; prevention is a separate change.
- **Entity spellings differ from literal characters.** `&#xff0c;` stays inside the destination and `&#xff1a;` before a scheme stays literal. Declared exception, pinned by tests.
- **Script coverage is narrower than "CJK".** Han is covered; kana/Hangul before a scheme still block the link. Recorded as a non-goal.
- **Regex character-class construction.** The constant is embedded in a class; an ASCII metacharacter would change it. The set is entirely full-width/non-ASCII plus U+200B, and tests exercise every range endpoint.
- **Matrix/support text can drift from code.** Mitigation: stable-token matrix test, support-doc phrase guard, and the generated-doc consistency test.
- **Performance is an estimate.** The regex is cached and the pass stays linear; no benchmark is added.

## Migration Plan

No data, API, or dependency migration. The behavior change ships with the renderer; the JSON edit, regenerated `Docs/CompatibilityMatrix.md`, and `Docs/MarkdownSupport.md` update must land in the same commit so the consistency tests stay green. Rollback is reverting the commit; there is no persisted state.

## Open Questions

None. Hostname-absorption prevention, entity-aware detection, kana/Hangul left boundaries, and email-address boundaries are explicitly deferred, not unresolved.
