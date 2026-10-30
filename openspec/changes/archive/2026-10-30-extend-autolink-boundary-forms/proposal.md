## Why

`fix-cjk-autolink-punctuation` made full-width CJK punctuation end a bare URL, but its enumerated set stops at the U+FF00 block and U+200B. The same silent link loss still happens with the other CJK punctuation encodings and with the invisible characters that pasted text carries:

- `https://example.com﹐tail` (U+FE50 SMALL COMMA) and `https://example.com︒然后` (U+FE12 vertical ideographic full stop) render as plain text: the character is absorbed into the authority and domain validation rejects the candidate. Small and vertical forms come from vertical layouts, Taiwanese CNS 11643 text, and OCR/PDF extraction.
- `https://example.com/path` + U+FEFF puts the invisible character into the link target (percent-encoded by the browser), and U+FEFF, U+2060 or a bidi mark before the scheme (a stray BOM at a line start, a URL wrapped in LRM/RLM or isolates inside Arabic or Hebrew text) keeps the URL from linking at all.

The Red Team review of 2026-10-20 recorded this in `TODOS.md` as residual risk, with an open decision on U+FEFF, U+00AD, U+2060 and the bidi marks.

While checking the visible-continuation guard against the new forms, a second gap turned up: the guard folds full-width forms but not small or vertical ones, so `foo@evil.com﹒trusted.com`, `foo@evil.com︒trusted.com`, `foo@evil.com﹫trusted.com` and `https://evil.com，﹫trusted` link the shorter host today.

## What Changes

- **Extend the normative boundary set** with every assigned character in U+FE10–U+FE19 (vertical forms), U+FE30–U+FE4F (CJK compatibility forms) and U+FE50–U+FE6B (small form variants; the unassigned U+FE53 and U+FE67 are excluded), and with the invisible format characters U+00AD, U+2060, U+FEFF, U+061C, U+200E–U+200F and U+2066–U+2069. Each is a URL terminator and a valid left boundary, as U+200B already is.
- **Keep ZWNJ/ZWJ (U+200C/U+200D), variation selectors, and the bidi embedding/override controls U+202A–U+202E outside the set**, and declare why: the joiners are valid IDNA context characters and part of emoji sequences, and the overrides reorder what a reader sees.
- **Make the structural-lookalike rule explicit.** A boundary character whose compatibility form is `.`, `/`, `#`, `@`, `?`, `-` or `_` stays URL body content rather than terminating it. That adds `︖﹒﹖﹟﹣﹫︳︴﹍﹎﹏` to `．／＃＠？－＿`, so `https://evil.com﹒trusted.com` stays literal like its full-width twin. A test derives the lookalike set from the rule.
- **Fold vertical and small forms in the visible-continuation guard** to their single-scalar compatibility form (`︒` → `。`, `﹒` → `.`, `﹫` → `@`, `﹪` → `%`, `﹣` → `-`), as full-width ASCII already folds. This closes the four spoof continuations above for both the URL and the email guard.
- **Correct the spec's U+200B scenario.** It says `https://example.com\u{200B}tail` links `https://example.com`; since the label-extension rule landed, it stays literal (pinned by `labelExtensionStaysLiteral`). The scenario now uses a URL path, and the same reading is declared for the added invisible characters: `https://example.com` + U+FEFF + `tail` reads as `example.comtail` and stays literal.
- **Declare the change.** Update the `gfm-autolinks` matrix entry, regenerate `Docs/CompatibilityMatrix.md`, update `Docs/MarkdownSupport.md`, extend the token guards, and remove the resolved item from `TODOS.md`.
- **Add regression tests**: the exhaustive boundary table grows to all 156 characters, the lookalike tables to all 18, adjacent-code-point probes cover the new ranges, the unassigned gaps and the excluded format characters, and new rows pin the reported prose cases and every new fold.

**Non-goals** (deliberately out of scope):

- Other Unicode punctuation blocks (General Punctuation beyond the enumerated characters, Supplemental Punctuation, CJK Symbols outside U+3000–U+303F).
- Folding every NFKC compatibility character in the guard (ligatures, superscripts, enclosed alphanumerics).
- Linking `https://example.com` + U+FEFF + `tail`; it reads as one longer host label, the same contract as U+200B.
- The email match pattern and its left boundary.
- Any GUI/PDF/print/export path or public API change.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `cjk-autolink-boundaries`: the normative terminator/left-boundary set gains the vertical, CJK compatibility and small form blocks and the enumerated invisible format characters; the structural-lookalike set is defined by its compatibility-form rule; both continuation guards fold vertical and small forms; the declaration and regression-coverage requirements follow; the U+200B scenario is corrected to the implemented label-extension behavior.

## Impact

- `Sources/MD2Core/MarkdownRenderer.swift`: `bareURLBoundaryCharacters` and `bareURLStructuralLookalikes` grow; new `compatibilityFormRange`/`compatibilityFormFolds`; `normalizeContinuation` applies the fold first.
- `Tests/MD2CoreTests/CommonSyntaxTests.swift`: boundary table, lookalike tables and derivation test, adjacent-code-point probes, spoof/label-extension/email rows, and a reported-cases table.
- `Tests/MD2CoreTests/Matrix/compatibility-matrix.json` and the regenerated `Docs/CompatibilityMatrix.md`; `Docs/MarkdownSupport.md`; token guards in `CompatibilityMatrixTests` and `CrossArtifactConsistencyTests`.
- `TODOS.md`: the "CJK compatibility punctuation and invisible format characters in bare-URL boundaries" item is resolved.
- No public API, dependency, preview JavaScript/CSS, PDF/Print, HTML-export, or GUI-gated path changes. The whole change is covered by plain `swift test`.
