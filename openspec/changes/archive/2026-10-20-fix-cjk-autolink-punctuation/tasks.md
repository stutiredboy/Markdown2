## 1. Plan artifacts (review decisions D1–D6)

- [x] 1.1 Update `proposal.md`, `specs/cjk-autolink-boundaries/spec.md`, and `design.md`: exact normative ranges, literal-only entity scope with both entity exceptions, hostname-vs-path absorption, U+200B as terminator and left boundary, and the estimated-performance wording.
- [x] 1.2 Add the boundary/body asymmetry diagram to `design.md`.
- [x] 1.3 Run `openspec validate fix-cjk-autolink-punctuation --strict` and confirm the change is valid.

## 2. Renderer

- [x] 2.1 Add a module-internal `bareURLBoundaryCharacters` constant (not public API; the sync test reads it through `@testable import`) to `Sources/MD2Core/MarkdownRenderer.swift` containing the normative set from design D2 (CJK/typographic punctuation ranges plus U+200B; no ASCII characters, so it is regex-class safe).
- [x] 2.2 Extend the bare-URL alternative in `protectBareAutolinks` (`:2086`, pre-change): add `\p{sc=Han}` and the full boundary constant to the left-boundary lookbehind, and add `bareURLBodyTerminators` (the constant minus the structural lookalikes `．／＃＠？`) to the URL-body negated class, interpolating both into the pattern.
- [x] 2.3 Confirm the rest of `protectBareAutolinks` is untouched: token cut at the first non-literal placeholder, ASCII trailing cleanup, excess-closing-parenthesis handling, entity recovery, domain validation, and the `www.`/`mailto:` destination assembly.

## 3. Renderer tests

- [x] 3.1 Extend the existing parameterized `bareLinks` table with the trailing-dot row (`www.example.com/a.b.` → `http://www.example.com/a.b` + `.`); do not duplicate assertions already covered by `autolinksRespectBoundariesAndProtectedContent` or `multilineLabelsCodeRunsAndStyledAutolinks`.
- [x] 3.2 Add a parameterized table with one terminator case and one left-boundary case for every normative range, using both endpoints where typo risk exists (`–—`, `‘”`, `、〃`, `〈】`, `〔〟`, `！／`, `：＠`, `［｀`, `｛･`) plus the singletons (`·`, `…`, `〰`, `〽`, `・`, U+200B). Assert the anchor destination/text and the character left outside the anchor. The structural lookalikes `．／＃＠？` are excluded from the terminator table and covered by `structuralLookalikesStayURLContent` instead.
- [x] 3.2b Add `structuralLookalikesStayURLContent`: `https://evil.com<lookalike>trusted.com` stays literal, a lookalike in a path stays in the anchor, and a lookalike before the scheme remains a valid left boundary.
- [x] 3.3 Add assertions for the four reported inputs (`见 https://example.com/docs，然后继续。`, `参考 https://zh.wikipedia.org/wiki/北京。`, `见 https://example.com，然后继续。`, `https://example.com/wiki/北京，更多`) and the `www.` variants (`访问www.example.com`, `www.example.com。`).
- [x] 3.4 Add assertions distinguishing `https://example.com/wiki/北京` (path under `example.com`) from `https://example.com然后继续` and `访问https://example.com然后继续` (absorbed hostname).
- [x] 3.5 Add assertions for the entity exceptions: `https://example.com/a&#xff0c;然后` keeps the decoded `，` in the destination, and `&#xff1a;https://example.com` stays literal.
- [x] 3.6 Add U+200B assertions: `https://example.com\u{200B}tail` ends before the character, and `\u{200B}https://example.com` links.
- [x] 3.7 Add the negative ASCII-boundary assertion for `abchttps://example.com` (and assert `abcwww.example.com` stays literal in `asciiIdentifierBoundariesStillBlock`).
- [x] 3.8 Run `swift test --filter CommonSyntaxTests` and confirm the new cases pass and no existing autolink case regresses.
- [x] 3.9 Add `spoofContinuationsStayLiteral` (invisible/entity/escape/adjacent-HTML masking, IDNA and fullwidth labels, any userinfo `@`, ports, and `％2e`) and the ordinary, path, query and fragment continuation tests.

## 4. Compatibility artifacts

- [x] 4.1 Update the `gfm-autolinks` entry in `Tests/MD2CoreTests/Matrix/compatibility-matrix.json`: `declaredBehavior` states that CJK/typographic punctuation (including full-width forms) and U+200B terminate bare URLs and Han text stays valid inside URL paths; `boundary` states the left-boundary rule and intentional GFM adjustment, URL truncation, hostname absorption (`example.com然后`), the literal-only entity exception, and that email boundaries are unchanged. Keep the tier `Supported` and the `known-incomplete` corpus relationship.
- [x] 4.2 Regenerate `Docs/CompatibilityMatrix.md` with `MD2_REGENERATE_DOCS=1 swift test --filter CrossArtifactConsistencyTests`; do not hand-edit the generated file.
- [x] 4.3 Add a stable-token test in `Tests/MD2CoreTests/CompatibilityMatrixTests.swift` asserting the `gfm-autolinks` entry contains `full-width`, `left boundar`, `intentional`, `gfm`, and `u+200b` (case-insensitive), so the declaration cannot be silently dropped.
- [x] 4.4 Update the autolinks bullet in `Docs/MarkdownSupport.md` to state the boundary set, U+200B, hostname absorption, URL truncation, and the entity exception; add a phrase guard (`full-width`, `U+200B`, `hostname`, `truncat`) in `Tests/MD2CoreTests/CrossArtifactConsistencyTests.swift`.
- [x] 4.5 Run `swift test --filter CompatibilityMatrixTests --filter CrossArtifactConsistencyTests` and confirm the matrix, generated doc, and support doc are consistent.

## 5. Verification

- [x] 5.1 Run the full non-GUI suite with `swift test` and confirm it is green (includes the conformance corpus and cross-artifact consistency tests).
- [x] 5.2 Render the four reported inputs and confirm the emitted HTML matches the spec scenarios: punctuation outside the anchor, Han path preserved, hostname absorption declared, and `https://example.com，…` linked.
- [x] 5.3 Confirm no GUI-gated path is involved: this change touches `MD2Core` rendering only, so `MD2_RUN_GUI_TESTS=1` is not required.
