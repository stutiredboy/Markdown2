## Context

`MarkdownRenderer.protectBareAutolinks` builds its bare-URL pattern from `bareURLBoundaryCharacters`: the full set is the left-boundary lookbehind class, and the set minus `bareURLStructuralLookalikes` (`bareURLBodyTerminators`) ends the URL body. When the authority ends the URL, `visibleContinuation` reads what a browser would show after it, and `normalizeContinuation` folds IDNA dots and full-width ASCII before the retarget rules run. The email branch reuses the same walk with `hostPrefixOnly`.

The set today is the CJK/typographic punctuation in U+00B7–U+30FB, the full-width punctuation in U+FF01–U+FF65, and U+200B. Two kinds of character still get absorbed into a URL:

1. **Vertical and small CJK forms.** U+FE10–U+FE19, U+FE30–U+FE4F and U+FE50–U+FE6B are compatibility variants of punctuation the set already has (`﹐` is a small `，`, `︒` a vertical `。`). They appear in vertical layouts, CNS 11643 (Taiwanese) text, and OCR/PDF extraction. `https://example.com﹐tail` matches through `﹐tail`, the host becomes `example.com﹐tail`, domain validation rejects it, and the URL renders as plain text: the same silent loss `fix-cjk-autolink-punctuation` fixed for U+FF0C.
2. **Invisible format characters.** U+FEFF (a stray BOM), U+2060, U+00AD, and the bidi marks and isolates used to wrap URLs inside right-to-left text are not `\s`. After a path they end up in the link target (percent-encoded by the browser); before a scheme they fail the lookbehind, so `\u{200F}https://example.com\u{200F}` never links.

The guard has a related gap. `normalizeContinuation` folds full-width forms only, so a small or vertical form in the continuation is read as an opaque symbol: `foo@evil.com﹒trusted.com`, `foo@evil.com︒trusted.com` and `foo@evil.com﹫trusted.com` link `mailto:foo@evil.com`, and `https://evil.com，﹫trusted` links `https://evil.com`, although each reads as a longer address or a userinfo form.

The spec's "Zero-width space terminates a URL" scenario also no longer matches the code: it expects `https://example.com\u{200B}tail` to link `https://example.com`, but the label-extension rule keeps it literal (`labelExtensionStaysLiteral` pins that), because the text reads as `example.comtail`.

## Goals / Non-Goals

**Goals:**

- Every assigned character in the three compatibility blocks ends a bare URL and is a valid left boundary, unless it is a structural lookalike.
- A principled decision on the invisible format characters the TODO named, with each exclusion explained.
- One written rule for structural lookalikes, enforced by a test rather than by a hand-kept list.
- The continuation guard reads small and vertical forms the way it reads full-width forms, in both the URL and the email path.
- No measurable cost on existing documents or existing URL shapes.

**Non-Goals:**

- Other punctuation blocks, folding every NFKC compatibility character, linking a URL followed by an invisible character and a host label, the email match pattern, and any GUI/export path.

## Decisions

### D1: Add the three blocks exhaustively, minus the unassigned gaps

All 62 assigned characters in U+FE10–U+FE19, U+FE30–U+FE4F and U+FE50–U+FE6B join the set. They are punctuation (Po/Ps/Pe/Pd/Pc, plus four Sm and one Sc in the small forms), the same kind of character as the full-width block. U+FE53 and U+FE67 are unassigned and excluded, so a future Unicode assignment cannot silently widen the contract. Adjacent code points (U+FE0F, U+FE1A, U+FE2F, U+FE6C, U+FE70) and both gaps are pinned as URL content.

The constant stays a literal enumeration (with per-block comments) rather than a computed Unicode property query. The normative set must not change with the OS's Unicode tables, and the test table enumerates the ranges independently, with `boundaryConstantMatchesSampleTable` keeping the two in sync.

### D2: Structural lookalikes are the boundary characters whose compatibility form is URL-structural

The existing set `．／＃＠？－＿` is exactly the full-width forms of `. / # @ ? - _`. The same rule applied to the new blocks adds `︖` (U+FE16), `﹒` (U+FE52), `﹖` (U+FE56), `﹟` (U+FE5F), `﹣` (U+FE63), `﹫` (U+FE6B) and the low lines `︳︴﹍﹎﹏` (U+FE33, U+FE34, U+FE4D–U+FE4F): eighteen in total. They stay URL body content, so `https://evil.com﹒trusted.com` fails domain validation and stays literal instead of linking `evil.com`, as its full-width twin does.

`structuralLookalikesAreTheStructuralCompatibilityForms` derives the set from NFKC and compares it with the constant, so a future boundary addition cannot quietly join the wrong side. Unicode's normalization stability policy freezes decomposition mappings of assigned characters, so the derivation does not drift across OS versions.

Characters that fold to `:`, `%`, `\` or `&` (`︓﹕﹪﹨﹠`) stay terminators, like their full-width forms: the guard handles the userinfo (`:` … `@`) and encoded-dot (`%2e`) cases.

### D3: Invisible format characters: in for those that never belong in a URL, out for those that can

| Character | Decision | Reason |
| --- | --- | --- |
| U+200B ZWSP | in (already) | — |
| U+FEFF ZWNBSP/BOM, U+2060 WJ | in | Zero-width and invisible; a browser drops them from a host and percent-encodes them in a path, so they never form part of a working URL. A BOM at a line start is the common paste artifact. |
| U+00AD SOFT HYPHEN | in | Invisible unless at a line break; arrives inside words pasted from hyphenated text. In a path it produced a broken target either way; ending the URL makes the anchor text match the target. |
| U+061C ALM, U+200E LRM, U+200F RLM, U+2066–U+2069 isolates | in | The standard way to wrap an LTR URL in RTL text. A browser rejects them in a host. |
| U+200C ZWNJ, U+200D ZWJ | out | Valid IDNA characters in context (CONTEXTJ) and part of emoji ZWJ sequences, which do occur in URL paths. |
| Variation selectors, tag characters | out | Grapheme extenders that belong to emoji in paths. |
| U+202A–U+202E embeddings/overrides | out | Legacy controls that Unicode recommends replacing with isolates; the overrides reorder strong text ("Trojan Source"). A URL next to one keeps today's behavior. |

All the added characters are grapheme-cluster Controls, so each is its own `Character`: the match range stays `Character`-aligned and the guard's Swift-side inspection works unchanged. None is `\s` in ICU. U+200E/U+200F are Pattern_White_Space, which only matters in ICU free-spacing mode; the pattern does not use it, and the exhaustive table checks both characters in both positions.

Every added character is already skipped as invisible by the guard, so the label-extension rule covers them: `https://example.com` + U+FEFF + `tail` reads as `example.comtail` and stays literal, as `https://example.com` + U+200B + `tail` already does. The TODO's motivating example therefore keeps its literal result by design. What changes is everywhere else: a URL followed by one of these characters and then whitespace, punctuation, or CJK prose links; a path ends before it, with no invisible character in the target; and a BOM- or bidi-wrapped URL links at all.

### D4: The guard folds vertical and small forms to their single-scalar compatibility form

`normalizeContinuation` first maps a scalar in U+FE10–U+FE6B through `compatibilityFormFolds`, then applies the existing IDNA-dot and full-width folds. So `︒` → `。` → `.`, `﹒` → `.`, `﹫` → `@`, `﹪` → `%`, `﹣` → `-`, `﹡` → `*`. The table is built once from the boundary characters in that range, keeping only single-scalar NFKC results; `︙`, `︰` and the overlines map to several scalars and stay as written, as `…` does today.

This is the same visible-text model the guard already uses for full-width forms, extended to the forms this change adds. It closes five shapes that link the shorter host on `HEAD`: `foo@evil.com﹒trusted.com`, `foo@evil.com︒trusted.com`, `foo@evil.com﹫trusted.com`, `https://evil.com，﹫trusted`, and `https://evil.co` + U+200B + `﹣m`. It also stops the new terminators from opening two more: `https://evil.com︒ｔｒｕｓｔｅｄ` and `https://evil.com﹪2e中国`, which are literal on `HEAD` only because the whole line fails domain validation. Every one of these rows fails when the fold is disabled (checked by mutation). The folds that become Markdown delimiters (`﹡`, `﹦`, the low lines → `_`) are then skipped as markup, as `＊`/`＿` already are; that only makes the guard see more fused text, which is the fail-closed direction.

Rejected: folding every NFKC compatibility character. That would also fold ligatures, superscripts, enclosed alphanumerics and more, changing the guard far beyond the characters this change adds.

### D5: Correct the U+200B scenario instead of changing behavior

The scenario now uses a path (`https://example.com/a\u{200B}tail` links `/a`), and new scenarios state the label-extension reading for the added characters. The behavior has been pinned by tests since the label-extension rule landed; only the spec text lagged.

## Risks / Trade-offs

- **A URL that contains one of the added characters is truncated at it** (`https://example.com/inter\u{00AD}national` links `/inter`). The same declared trade-off as every other terminator. Before, the link target carried the invisible character and was broken anyway.
- **`﹖` and `︖` stay in the URL body**, as `？` does, so a question that ends in a URL with a small or vertical question mark keeps it in the target. This follows the existing full-width rule instead of reopening it.
- **A URL next to a bidi embedding or override control stays literal** as today.
- **The fold table depends on Foundation's NFKC at first use.** It covers only the listed characters, and their decompositions are frozen by Unicode's stability policy.

## Performance

Measured with `swiftc -O` probes of `HEAD` and this change (best of 7 for real documents, best of 5 for synthetic, Apple Silicon, two rounds):

| Workload | Before | After |
| --- | --- | --- |
| `README.zh-CN.md` | 6.1–6.8 ms | 6.1–6.2 ms |
| `Examples/Sample.md` | 11.7–11.8 ms | 11.7–11.8 ms |
| 2,000 CJK paragraphs, URL path + `，` | 196–199 ms | 198–200 ms |
| 2,000 English lines, two URLs each | 186 ms | 185–187 ms |
| 2,000 authority-only URLs, guard walks over 450 Han scalars | 1,342–1,371 ms | 1,335–1,362 ms |
| 2,000 authority-only URLs + `，`…`、` (full-width) | 2,485 ms | 2,509 ms |
| 2,000 authority-only URLs + `﹐`…`﹑` (small forms) | 2,088–2,164 ms | 2,493–2,539 ms |
| 2,000 URLs + `﹐` | 139–141 ms | 196–199 ms |
| 2,000 RLM-wrapped URLs | 120–121 ms | 184–185 ms |
| One line, 1,000 / 2,000 / 4,000 × `www.a﹐` | 4.5 / 9.0 / 18 ms | 138 / 281 / 567 ms |
| One line, 2,000 × `www.a。` (existing hostile shape) | 281–288 ms | 253–275 ms |

Existing documents and URL shapes are within run-to-run noise. The fold adds one range comparison per continuation scalar, which does not show up even in the 900,000-scalar guard-walk workload. The rows that got slower are inputs whose links `HEAD` dropped: one oversized candidate failed domain validation cheaply. They now do the same work as their full-width equivalents (the small-form row matches the full-width row at about 2.5 s; the `﹐` and RLM rows match the `，` row at about 198 ms). The hostile small-form line scales linearly (×2.0 per doubling) and lands in the same class as the `www.a。` line that `repeatedTerminatedBareURLsRenderInBoundedTime` already bounds; it goes through the same walk and budgets.
