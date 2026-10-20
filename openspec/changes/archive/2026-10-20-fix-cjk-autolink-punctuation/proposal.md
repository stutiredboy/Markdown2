## Why

Bare-URL autolinking currently follows GFM's ASCII boundary rule literally: a URL ends only at whitespace or `<`, trailing cleanup removes only ASCII punctuation, and the left boundary accepts only whitespace or `*`, `_`, `~`, `(`. In Chinese writing a URL is routinely written flush against full-width punctuation (`，。、；：？！（）《》【】「」`), so three failures show up in ordinary documents:

- `见 https://example.com/docs，然后继续。` links the whole tail `…/docs，然后继续。` as the URL.
- `参考 https://zh.wikipedia.org/wiki/北京。` leaves the full-width `。` inside the link.
- `见 https://example.com，然后继续。` is not linked at all, because the swallowed `，` fails the domain validation and the candidate falls back to literal text.

URLs preceded by Han characters or full-width punctuation (`访问https://…`, `链接：https://…`, `（https://…）`) are also never recognized. The same failure shape appears with the zero-width space (U+200B) common in text copied from the web: `\u{200B}https://…` stays literal, and `https://…\u{200B}tail` swallows the invisible character and the following text, then fails domain validation. This makes everyday Chinese Markdown render visibly wrong while ASCII documents behave correctly.

## What Changes

- **Terminate bare URLs at literal CJK/typographic punctuation and U+200B.** The bare-URL body will stop at the normative set: U+00B7, U+2013–U+2014, U+2018–U+201D, U+2026, U+3001–U+3003, U+3008–U+3011, U+3014–U+301F, U+3030, U+303D, U+30FB, U+FF01–U+FF0F, U+FF1A–U+FF20, U+FF3B–U+FF40, U+FF5B–U+FF65, and U+200B. Full-width letters and digits stay content and are not terminators.
- **Accept CJK left boundaries.** Han characters, the same punctuation set, and U+200B become valid left-boundary characters in addition to whitespace and `*`, `_`, `~`, `(`. ASCII identifier boundaries stay unchanged: `abcwww.example.com` and `abchttps://…` remain unlinked.
- **Keep Han characters inside URL paths, but name hostname absorption correctly.** Han text after a path separator stays in the path (`https://zh.wikipedia.org/wiki/北京`), while Han text immediately after the authority is absorbed into the hostname (`https://example.com然后继续` links to host `example.com然后继续`). Both are declared trade-offs, documented and tested; preventing absorption is out of scope.
- **Scope the rule to literal source characters.** Authored HTML entity spellings keep the existing entity-recovery behavior: `https://example.com/a&#xff0c;然后` keeps the decoded comma in the destination, and `&#xff1a;https://example.com` stays literal. Entity-aware punctuation detection is out of scope.
- **Leave all other autolink behavior intact.** Trailing ASCII punctuation cleanup, excess-closing-parenthesis handling, trailing entity spellings, domain validation, protection of code/math/links, and angle-bracket autolinks are unchanged. Email autolinks are out of scope.
- **Declare the divergence and its trade-offs.** Update the `gfm-autolinks` entry in the machine-checked compatibility matrix (`Tests/MD2CoreTests/Matrix/compatibility-matrix.json`) and its generated human-readable form (`Docs/CompatibilityMatrix.md`) to record the boundary rule as an intentional adjustment to the GFM specification, including URL truncation, hostname absorption, and the entity exception; update `Docs/MarkdownSupport.md` to match and add a phrase guard so the doc cannot silently lose the sentence.
- **Add regression tests** covering the reported cases, one terminator and one left-boundary character from each normative range (endpoints where a range has typo risk), `www.` variants, hostname-vs-path absorption, the entity exceptions, and U+200B.

**Non-goals** (deliberately out of scope):

- Email autolink boundary behavior (a Han character before `foo@example.com` still blocks the email autolink).
- Kana/Hangul left boundaries. Only Han characters are added, matching the reported Chinese-writing case.
- ASCII punctuation mid-URL (`https://example.com/docs,然后` keeps `,然后` in the URL; GFM also only strips ASCII punctuation at the tail).
- IDN/percent-encoding changes, URL normalization, preview click handling, and preventing hostname absorption.
- Entity-aware punctuation detection; authored entity spellings keep their existing behavior.
- Angle-bracket autolinks (`<https://…>`), Markdown link destinations, and reference definitions.
- Any GUI/PDF/print/export path or public API change.

## Capabilities

### New Capabilities

- `cjk-autolink-boundaries`: bare-URL termination at literal CJK/typographic punctuation and U+200B, acceptance of Han characters and the same set as left boundaries, preservation of Han text inside URL paths with hostname absorption declared, literal-only entity semantics, and the compatibility-matrix declaration of this intentional GFM divergence and its trade-offs.

### Modified Capabilities

None. The `markdown-compatibility-matrix` requirements already require an intentional divergence to be declared and visible; this change supplies the matrix data that satisfies that requirement rather than changing the requirement text.

## Impact

- `Sources/MD2Core/MarkdownRenderer.swift`: the bare-URL alternative in `protectBareAutolinks` (`:2085-2134`, pre-change) — a shared boundary-character constant interpolated into the left-boundary lookbehind and the URL body class; the trailing-cleanup and domain-validation steps stay as they are.
- `Tests/MD2CoreTests/CommonSyntaxTests.swift`: extend the parameterized `bareLinks` table and add focused assertions for the reported cases, per-range endpoints, `www.` variants, hostname-vs-path absorption, entity exceptions, and U+200B.
- `Tests/MD2CoreTests/Matrix/compatibility-matrix.json`: `gfm-autolinks` declared behavior and boundary text; `Docs/CompatibilityMatrix.md` regenerated from it (never hand-edited).
- `Tests/MD2CoreTests/CompatibilityMatrixTests.swift`: stable-token assertion that the matrix entry keeps the declaration.
- `Tests/MD2CoreTests/CrossArtifactConsistencyTests.swift`: phrase guard for the support-doc sentence.
- `Docs/MarkdownSupport.md`: the autolinks bullet gains the boundary behavior and its trade-offs.
- No public API, dependency, preview JavaScript/CSS, PDF/Print, HTML-export, or GUI-gated path changes. The whole change is covered by plain `swift test`.
