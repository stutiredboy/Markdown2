## Context

`MarkdownRenderer.protectBareAutolinks` matches bare URLs and email addresses with one pattern. For URLs whose authority ends the candidate, it walks the visible continuation (`visibleContinuation`) and keeps the candidate literal when that text would change the apparent authority. The email branch only checks that the address ends in a letter or digit.

The email pattern is `(?<![\w.+\-])[-A-Za-z0-9_+.]+@[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+`. Its domain is ASCII-only and always ends the address, so any non-ASCII, invisible, or protected character ends the match and the rest of the line renders as plain text right after the anchor. That gives the same retarget shapes the URL guard blocks: `foo@evil.com。trusted.com`, `foo@evil.co` + U+200B + `m`, `foo@evil.coｍ`, and masked dots (`&#46;`, `\.`, `<span>.trusted.com</span>`).

Unlike a URL, an email address in CJK text is usually followed directly by prose (`联系 foo@example.com。然后继续。`, `foo@example.com으로`, `foo@example.comまで`) or by another address (`foo@example.com、bar@example.com`). The guard must block the retarget shapes without dropping those links.

While checking the walk for reuse, a footnote marker after a URL turned out to drop the link: `see https://example.com[^1].` renders literal because the marker's superscript number reads as host-label digits.

## Goals / Non-Goals

**Goals:**

- An email continuation that reads as more of the domain keeps the candidate literal.
- CJK prose and address lists written flush against an address keep the link.
- The email walk costs no more than the host-shaped prefix it reads.
- Footnote markers do not drop a URL or email link, and do not hide a fused authority after them.
- The guard is declared in the matrix and the support doc, with guards on both.

**Non-Goals:**

- The email match pattern and left boundary, the local part, percent-encoded dots after an address, no-space scripts other than Han/kana/Hangul, and any relaxation of the URL guard's conservative contracts.

## Decisions

### D1: Reuse the visible-continuation walk, stopping at the end of the host-shaped prefix

The email branch calls `visibleContinuation` so every masking form the URL guard handles (tokens, entities, escapes, image alt text, inline HTML, emphasis delimiters, invisible and blank-rendering scalars, IDNA and fullwidth folding, math and cross-reference fail-closed) is handled identically. A new `hostPrefixOnly` option ends the walk at the first visible scalar that is neither a host-label character nor a dot.

Chosen over a separate email scanner because the masking rules are the expensive, review-hardened part; a second scanner would drift. Chosen over the full walk because the email decision needs nothing past the prefix: stopping there keeps a separator, an address list, or a later math span from failing the check closed, and bounds each walk by its prefix. The URL path passes the default and is unchanged.

### D2: An email-specific rule set, not the URL rules

The candidate stays literal when:

1. the continuation begins with `@` (an address straight followed by an at sign is never prose);
2. a label of the host-shaped prefix begins with a host-label character outside the Han, Hiragana, Katakana and Hangul scripts. The first label fuses onto the final domain label (`foo@evil.co` + `m`); each later label follows a dot (`foo@evil.com。trusted.com`, `foo@evil.com然后.trusted.com`);
3. the walk fails closed before the prefix ends.

The URL rules were rejected for email because three of them drop ordinary CJK email links:

- "any `@` before the next delimiter" blocks the first address of `foo@example.com，bar@example.com`;
- "a dot before a non-ASCII label that is followed by another dot" blocks `foo@example.com。我们会尽快回复。谢谢。`;
- "a host-label start followed later by a dot" (after dropping leading punctuation) blocks `foo@example.com、bar@example.com`.

Those rules exist for URL-specific semantics (userinfo, percent-decoding in the host). An email domain has neither, and the email pattern has no trailing punctuation to strip.

### D3: CJK label starts are prose

Han, kana and Hangul attach to the neighbouring word without a space and cannot pass for an ASCII host label, so a label that starts with one does not block the link. Only label starts are checked: `然后用Git` is one label that starts with Han. The scripts are tested with ICU's `\p{sc=…}` through one cached `NSRegularExpression`, matching the existing `\p{sc=Han}` left-boundary rule; Swift has no public script property, and hand-written ranges would be error-prone. Any other script fails closed: a Thai or Latin word flush against an address stays literal.

### D4: Footnote markers are transparent to the walk

A restored fragment that is exactly the `applyFootnoteReferences` shape (`<sup class="footnote-ref"><a …>N</a></sup>` with a numeric body) is skipped. Its only text is a generated note number, which neither extends a label nor forms a separator a reader would trust. Skipping it rather than treating it as a separator is the fail-closed choice: what follows the marker is checked as if adjacent, so `https://evil.com[^1].trusted.com` and `foo@evil.com[^1].trusted.com` stay literal. The numeric-body requirement keeps an authored superscript (`<sup>m</sup>`) visible to the guard. This applies to the URL path too and fixes its footnote link loss.

### D5: Exhaustion fails closed

`hostPrefixOnly` returns as soon as the prefix ends, so `exhausted` means the prefix did not end within the existing visible (1,024) and source (2,048) budgets, or the walk hit a math span, provisional cross-reference, joined sentinel, or unaligned token inside it. The candidate stays literal in every such case.

## Risks / Trade-offs

- **An ASCII word after an address's full stop stays literal** (`foo@example.com。GitHub 上…`). It is structurally identical to `foo@evil.com。trusted`; the URL guard makes the same trade (`https://example.com。GitHub`). Pinned by `asciiLabelAfterEmailFullStopStaysLiteral`.
- **Non-CJK words flush against an address stay literal** (`foo@example.comé`, Thai prose without a space). Rare; the fail-closed direction.
- **A host-shaped CJK run longer than the visible budget stays literal.** A run of over 1,024 Han characters with no punctuation after an address; not a realistic sentence.
- **Footnote detection depends on the footnote HTML shape.** If `applyFootnoteReferences` changes its markup, the skip stops matching and links before footnotes go back to literal (fail-closed); `footnoteMarkerAfterAutolinkKeepsTheLink` fails and flags it.

## Performance

Measured with `swiftc -O` probes of `HEAD` and this change (best of 7, Apple Silicon):

| Workload | Before | After |
| --- | --- | --- |
| `README.zh-CN.md` | 6.2 ms | 6.2–6.4 ms |
| `Examples/Sample.md` | 11.8 ms | 11.8 ms |
| 2,000 CJK paragraphs with one address each | 191 ms | 199 ms |
| 2,000 English lines with two addresses each | 227–232 ms | 229–230 ms |
| One line of 2,000 addresses joined by Han text and `、` | 68–70 ms | 72–73 ms |

Real documents are within run-to-run noise. The synthetic address-dense workloads cost about 2–4 µs per address (the walk over the prefix; the script regex is not measurable). Walks never overlap past the next `@`, so a line of addresses stays linear; `repeatedEmailAutolinksRenderInBoundedTime` pins the scaling.
