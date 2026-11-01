## Context

`InlineProtector` stores each protected construct (code, math, entities, escapes, links, images, autolinks, raw HTML, footnote and citation markers) as an entry and returns a placeholder token. Later passes see only tokens, and one linear resolver restores them at the end (`fix-quadratic-inline-rendering`, `speed-up-token-restore`, `unify-token-grammar`).

The token spelling was fixed, `\u{E000}MD2-<n>\u{E000}`, so document text could spell one. Under the D4 boundary a typed canonical spelling with an index in range resolved like a real token.

That is the root of both problems in the TODO. Restoration re-inserts the named entry's full fragment, and a typed spelling can name any entry: an earlier one, or one protected later in the same pass, such as a bare-URL anchor.

## Goals / Non-Goals

**Goals:** typed placeholder text is always literal, at every reader of the grammar and inside rebuilt fragments; real tokens behave exactly as before; no measurable cost.

**Non-Goals:** an output-size cap (no longer needed); changing how other private-use text renders.

## Decisions

### A per-protector nonce in every token

Each `InlineProtector` draws three random private-use scalars (U+E001–U+F8FF, never the sentinel; about 38 bits) and spells its tokens as `\u{E000}<nonce><n>\u{E000}`. `token(at:in:)` compares the nonce scalar by scalar before reading the index, so a spelling without this protector's nonce is not a token. Thirty-eight bits is ample here: the nonce guards against deliberate forging, not against secrets. Each attempt costs a typed spelling, a guess is good for one render only, and one hit resolves one fragment once.

The nonce never reaches the output, because every real token is in range and restored, and the differential confirms no output contains one. A document therefore cannot know it, and a new render draws a new one.

The grammar functions become instance methods. Their three outside callers already hold the protector:
- `protectBareAutolinks` (the cut)
- `visibleContinuation` (the guard)
- `cutTailHTML`

*Alternatives considered:*
- **Escape typed U+E000 on input** (protect each typed sentinel as a literal entry). Rejected. The bare-URL code rebuilds an anchor from `decodeEntities(source(in:))`, which brings the raw sentinels back, and the anchor is then protected as a new fragment. Its nested expansion would read a typed spelling inside it as a token again. The nonce makes typed text inert wherever it ends up.
- **Cap total expansion.** Rejected by the product decision. A cap stops the size blow-up but not the repeated link.
- **A hex nonce** (`MD2-<16 hex digits>-<n>`). Measured and rejected. Every token grew by 17 ASCII characters, which every later regex pass then scans. Token-dense workloads slowed by up to 57% (`entities`), 52% (`unterminatedParenMath`) and 35% (`verbatimSpans`). A three-scalar nonce after `MD2-` still cost 4–9% on those. With the nonce alone, tokens are one scalar shorter than the old `MD2-` spelling.

### What becomes literal

Every typed spelling is now plain text:
- canonical and in range (this used to resolve)
- malformed, out of range, or with leading zeros (already literal)
- two spellings that share a sentinel (the leftmost used to resolve)
- a spelling that an escaped hyphen restores into canonical form (already literal)

A typed closing sentinel right before a real token is one literal scalar; the scan steps past it and still finds the real token. That is the case the rewritten bare-URL test pins, now including the canonical spelling.

## Verification

### Differential run

`swiftc -O` probes of `main` (`ef334e1`) and this change rendered the same inputs.

| Corpus | Inputs | Differ |
| --- | ---: | ---: |
| Repository and local Markdown documents, CommonMark and GFM examples | 1,827 | 0 |
| Generated, fuzz | 120,000 | 9,538 |
| Generated, structured | 120,000 | 16,091 |

Every one of the 25,629 differing inputs contains a typed canonical spelling, and every differing output shows that spelling literally. No output, on any corpus, contains a token with a nonce.

On these short inputs, `main`'s output was up to 2.1× the size of this change's. Many outputs grow slightly instead, because the 11-byte typed spelling is longer than a small fragment it used to resolve to, such as `&amp;`.

### Tests

- `typedTokenSpellingsStayLiteral`, `typedTokensCannotAmplifyTheOutput` and `typedTokenCannotRepeatALink` all fail against `main`. The amplification test also takes over a second there.
- `structuralTokenAfterTypedSpellingEndsBareURL` fails against `main` for the canonical spelling. The malformed spellings were already literal.
- The safety tests for typed tokens in destinations and reference definitions, and the discarded-DAG test, still pass: their properties now hold because the spellings are literal.
- The full non-GUI suite passes in CI's three steps.

### Timing

`Scripts/benchmark_inline.sh` (Apple M4, macOS 26.7, 5 samples), 2,000-fragment fastest time:

| Workload | `main` (ms) | This change (ms) |
| --- | ---: | ---: |
| `urlAutolinks` | 32.12 | 30.71 |
| `markdownLinks` | 44.06 | 43.37 |
| `mailtoAutolinks` | 31.16 | 30.08 |
| `entities` | 8.78 | 8.29 |
| `bareURLs` | 35.59 | 35.61 |
| `bareURLsWithEntities` | 48.79 | 49.05 |
| `referenceLinks` | 66.61 | 65.82 |
| `referenceLinksWithProtectedKeys` | 80.19 | 79.86 |
| `verbatimSpans` | 48.06 | 45.82 |
| `unpairedDollars` | 15.49 | 15.40 |
| `unterminatedParenMath` | 10.12 | 9.27 |

Every workload is unchanged or slightly faster, because tokens are one scalar shorter, and every workload still grows about 2× per doubling.

## Risks / Trade-offs

- **Documents that relied on typing a token to repeat a fragment change.** That was undocumented renderer internals, and it is exactly the behavior the product decision removes.
- **Tokens change shape.** They are one scalar shorter than before, and the timing table shows no cost. Leak checks in the tests now look for the sentinel instead of `MD2-`.
- **Randomness in the renderer.** It never affects output, because tokens never reach it. A leaked token would differ between runs and fail tests loudly, instead of naming the wrong fragment silently.
