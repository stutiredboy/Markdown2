## 1. Renderer

- [x] 1.1 Add the opt-in `hostPrefixOnly` stop to `appendVisibleContinuation` and `visibleContinuation`: end the walk after the first visible scalar that is neither a host-label character nor a dot. The URL path keeps the default.
- [x] 1.2 Skip whole footnote-reference fragments (numeric body) in `visibleContinuation`, so the marker contributes no visible authority text and what follows is checked as if adjacent.
- [x] 1.3 Add `continuationExtendsEmailDomain` (leading `@`, or a host-shaped-prefix label that starts outside Han/Hiragana/Katakana/Hangul) with `isHostLabelCharacter` and `isCJKProseCharacter` helpers.
- [x] 1.4 Run the guard in the email branch of `protectBareAutolinks`; keep the candidate literal when the walk is exhausted or the rule matches. Leave the email pattern and left boundary unchanged.

## 2. Tests

- [x] 2.1 Add `emailSpoofContinuationsStayLiteral`: IDNA/fullwidth dots, invisible and scalar-attached masks, split and fullwidth final labels, entities, escapes, inline HTML, emphasis, image alt text, protected tokens, later ASCII/non-CJK labels, a following `@`/`＠`, and math.
- [x] 2.2 Add `emailProseContinuationsStillLink`: CJK sentences, Han/kana/Hangul flush against the address, `、`/`，` address lists, a math span after the separator, and ASCII punctuation/emphasis.
- [x] 2.3 Add `asciiLabelAfterEmailFullStopStaysLiteral` pinning the declared trade-off.
- [x] 2.4 Add `footnoteMarkerAfterAutolinkKeepsTheLink`: URL and email before a footnote keep their links; a fused authority after the marker and an authored `<sup>` label still stay literal.
- [x] 2.5 Add `repeatedEmailAutolinksRenderInBoundedTime` to `InlineRenderingPerformanceTests`.

## 3. Compatibility artifacts

- [x] 3.1 Update the `gfm-autolinks` entry in `Tests/MD2CoreTests/Matrix/compatibility-matrix.json` to declare the email guard and the footnote-marker skip; keep the tier `Supported`.
- [x] 3.2 Regenerate `Docs/CompatibilityMatrix.md` with `MD2_REGENERATE_DOCS=1 swift test --filter CrossArtifactConsistencyTests`.
- [x] 3.3 Update the autolinks bullet in `Docs/MarkdownSupport.md`.
- [x] 3.4 Add token/phrase guards for the email guard in `CompatibilityMatrixTests` and `CrossArtifactConsistencyTests`.
- [x] 3.5 Remove the resolved "Mailto autolinks do not use the visible-continuation guard" item from `TODOS.md`.

## 4. Verification

- [x] 4.1 Run `openspec validate guard-email-autolink-continuations --strict`.
- [x] 4.2 Run the full non-GUI suite with `swift test`.
- [x] 4.3 Compare `swiftc -O` probes of `HEAD` and this change on real documents and address-dense workloads; record the numbers in `design.md`.
- [x] 4.4 Confirm no GUI-gated path is involved: the change touches `MD2Core` rendering only, so `MD2_RUN_GUI_TESTS=1` is not required.
