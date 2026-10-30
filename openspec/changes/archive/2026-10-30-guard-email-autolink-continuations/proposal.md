## Why

The bare-URL guard from `fix-cjk-autolink-punctuation` stops a visible continuation from retargeting a link to a shorter host, but the email alternative in `protectBareAutolinks` never runs it. The email pattern's domain is ASCII-only, so the match ends at the first non-ASCII or invisible character and the rest of the line renders as plain text right after the anchor:

- `foo@evil.com。trusted.com` links `mailto:foo@evil.com` while the text reads as an address at `evil.com.trusted.com` (IDNA folds `。` into a dot).
- `foo@evil.co` + U+200B + `m`, or `foo@evil.coｍ` (fullwidth `m`), links `mailto:foo@evil.co` while the text reads `foo@evil.com`.
- `foo@evil.com` + U+200B + `.trusted.com`, `&#46;`, an escaped dot, or `<span>.trusted.com</span>` hide the same fused domain.

The Red Team review of 2026-10-20 reproduced this and recorded it in `TODOS.md` as residual risk because that change declared email boundaries unchanged.

Reviewing the walk for reuse surfaced a second defect in the same guard: a footnote marker after a bare URL (`see https://example.com[^1].`) leaves the URL literal, because the walk reads the marker's generated superscript number as digits that extend the final host label. Reusing the walk unchanged for email would spread that silent link loss to `foo@example.com[^1]`.

## What Changes

- **Guard email autolinks with the visible-continuation walk.** After the existing trailing-character check, the email branch walks the visible continuation and keeps the candidate literal when it reads as more of the domain: an `@` straight after the address, or a host-shaped prefix (host-label characters and dots) with a label that starts with a host-label character outside the Han, Hiragana, Katakana and Hangul scripts. A walk that fails closed before the prefix ends also keeps the candidate literal.
- **Read only the host-shaped prefix for email.** The walk gains an opt-in mode that ends at the first visible character that cannot continue a host name. The email decision needs nothing past that point, so CJK punctuation (`、`, `，`), an address list, or a math span after the separator do not affect it, and each walk is bounded by the prefix it reads.
- **Keep CJK prose linked.** Han, kana and Hangul attach to the neighbouring word without a space and cannot pass for an ASCII host label, so `联系 foo@example.com。然后继续。`, `邮箱：foo@example.com获取`, `foo@example.comまでご連絡ください`, `foo@example.com으로 보내주세요`, and `foo@example.com、bar@example.com` keep their links.
- **Skip footnote markers in the walk.** A whole footnote-reference fragment (a generated note number) contributes no visible authority text. What follows the marker is still checked as if adjacent, so `https://example.com[^1].` and `foo@example.com[^1]` link while `https://evil.com[^1].trusted.com` stays literal.
- **Declare the guard.** Update the `gfm-autolinks` matrix entry, regenerate `Docs/CompatibilityMatrix.md`, update `Docs/MarkdownSupport.md`, and extend the token/phrase guards. Remove the resolved item from `TODOS.md`.
- **Add regression tests** for the spoof continuations, CJK prose and address lists, the declared ASCII-sentence trade-off, footnote markers, and a linear-time workload of separator-joined addresses.

**Non-goals** (deliberately out of scope):

- The email match pattern and its left boundary (`(?<![\w.+\-])`): Han before an address still blocks the link.
- The local part. Text before an address cannot change its domain.
- Percent-encoded dots after an address (`％2e`). A displayed address does not decode them; the URL guard keeps its own rule.
- No-space scripts other than Han, kana and Hangul (for example Thai) written flush against an address; they stay literal under the fail-closed rule.
- Relaxing the URL guard's conservative contracts (`https://example.com。然后继续。` stays literal).
- Any GUI/PDF/print/export path or public API change.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `cjk-autolink-boundaries`: email autolinks gain a visible-continuation guard (new requirement); the bare-URL guard skips footnote reference markers; the preserved-behavior requirement narrows "email autolinks are unchanged" to the email match pattern and left boundary.

## Impact

- `Sources/MD2Core/MarkdownRenderer.swift`: `appendVisibleContinuation` and `visibleContinuation` gain the opt-in host-prefix stop; `visibleContinuation` skips footnote-reference fragments; new `continuationExtendsEmailDomain` with `isHostLabelCharacter`/`isCJKProseCharacter` helpers; the email branch of `protectBareAutolinks` runs the guard.
- `Tests/MD2CoreTests/CommonSyntaxTests.swift`: email spoof table, CJK prose/list table, ASCII-sentence trade-off, footnote marker test.
- `Tests/MD2CoreTests/InlineRenderingPerformanceTests.swift`: bounded-time workload for separator-joined addresses.
- `Tests/MD2CoreTests/Matrix/compatibility-matrix.json` and the regenerated `Docs/CompatibilityMatrix.md`; `Docs/MarkdownSupport.md`; token/phrase guards in `CompatibilityMatrixTests` and `CrossArtifactConsistencyTests`.
- `TODOS.md`: the "Mailto autolinks do not use the visible-continuation guard" item is resolved.
- No public API, dependency, preview JavaScript/CSS, PDF/Print, HTML-export, or GUI-gated path changes. The whole change is covered by plain `swift test`.
