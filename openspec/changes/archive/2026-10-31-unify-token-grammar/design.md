## Context

`InlineProtector` replaces protected fragments with placeholder tokens, `\u{E000}MD2-<n>\u{E000}`, and resolves them in one linear scan (`fix-quadratic-inline-rendering`, `speed-up-token-restore`). The resolver's grammar is a Unicode-scalar parser: ASCII digits only, canonical decimal (`0` alone, never a leading zero), overflow-safe, closing sentinel required. On a match the scan consumes the token. On anything else it reads the sentinel as one literal scalar and moves on, so a closing sentinel can still open a following token.

Two other readers used `NSRegularExpression` `\u{E000}MD2-(\d+)\u{E000}` instead:

- **The bare-URL cut** (`protectBareAutolinks`) walks the candidate URL's regex matches, converts each index with `Int()`, and cuts the URL at the first token that is not marked `isLiteral`. Literal tokens (escapes, entities) stay part of the URL; structural tokens (code, math, links) end it.
- **The continuation guard** (`visibleContinuation`) walks the text after a URL whose authority ends it, restoring each token it meets so it sees what a browser shows.

The two grammars differ in three ways. ICU's `\d` is any Unicode decimal digit. `Int()` accepts leading zeros. And a regex match always consumes its closing sentinel, even when the cut then skips the match because `Int()` failed.

## Goals / Non-Goals

**Goals:** one token grammar and one token scan, used by every reader; byte-identical output for canonical spellings; the behavior change confined to authored U+E000 text and fully classified.

**Non-Goals:** changing index limits (below), the D4 boundary, or the authored-token amplification TODO; fixing the pre-existing bugs the differential run exposed (recorded in `TODOS.md`).

## Decisions

### `token(at:in:)` is the grammar, `firstToken(in:from:limit:)` is the scan

The private instance method `token(in:from:)` becomes `static token(at:in:)`. It now also checks that `start` is a sentinel, so it is safe to call from outside the resolver. `firstToken` finds the next sentinel, asks the grammar, returns the token if its index is below `limit`, and otherwise steps one scalar. `resolveTokens` and `tokenIndices` become loops over `firstToken`. The resolver's literal runs are still copied as `String(text[run])`; a run may now span sentinels the grammar rejected, which yields the same bytes the old per-sentinel append produced.

*Alternative considered:* add a third reader beside the resolver's loop (the TODO's literal suggestion, `firstToken(in:)` for the cut only). Rejected: it would leave two scan loops that could still drift. With one scan, the cut and the resolver agree by construction.

### The bare-URL cut keeps "no limit"

The resolver passes its entry count as `limit`. The cut passes none, as before: at cut time, an authored canonical spelling with an index at or above the current count is still a token to the cut (and still literal to the resolver). Changing that would change output for canonical spellings, which this refactor does not set out to do. The limit is the resolver's context, not part of the grammar.

The cut consumes a literal token whole and keeps looking, which is what the regex did for well-formed matches and what the resolver does for every token it accepts.

### The continuation guard switches too

The TODO named only the cut, but removing the regex means the guard must read tokens some other way, and any reader other than the grammar would be a third grammar. At a lone sentinel the guard now asks `token(at:in:)`. A spelling the grammar rejects is read character by character as the visible text it is. The `Range(NSRange, in:)` alignment guard goes away, because the grammar returns scalar-aligned bounds by construction.

## Differential results

Two `swiftc -O` probes, built from `main` and from this change, rendered the same inputs and compared the HTML byte for byte.

- **All 1,507 real inputs are byte-identical:** every Markdown document in the checkout, including local agent-skill and OpenSpec documents, plus all 676 CommonMark 0.31.2 and GFM 0.29 extension examples.
- **3,964 of 240,000 generated inputs differ** (two seeds × 60,000 random sequences of Markdown and token-shaped pieces, plus 60,000 structured bare-URL cases each). Every one contains a non-canonical token spelling (leading zeros, non-ASCII digits, or an overflowing index), and inputs without one never differ. About 41,500 inputs contain such a spelling and do not differ, because it sits outside any bare URL.

| Class | Count | What changed |
| --- | ---: | --- |
| The URL extends through a literal spelling | 3,075 | The cut used to end the URL at a leading-zero spelling; now the spelling is URL text, plus any punctuation or entity the old cut had stripped before it. |
| The URL stays literal | 886 | With the spelling now part of the URL, the existing host check rejects it in the host (878). In 8 cases, the continuation guard reads the spelling as characters and its sentinel, fused with a combining mark, fails closed. |
| A following token is found | 3 | A malformed spelling no longer consumes the sentinel it shares with the next token, so that token ends the URL (or is found at all). |

The shared-sentinel class is the one with user-visible damage on `main`: `` `x` https://a.com/p\u{E000}MD2-١\u{E000}MD2-0\u{E000} end `` links the code span's source and drops the code span (`structuralTokenAfterSharedSentinelEndsBareURL`).

## Timing

Release build, best of 7 renders per workload, best of three alternating rounds, Apple M4:

| Workload | `main` | This change |
| --- | ---: | ---: |
| `README.md` | 7.13 ms | 7.02 ms |
| `README.zh-CN.md` | 5.61 ms | 5.75 ms |
| `Examples/Sample.md` | 11.35 ms | 11.42 ms |
| `Docs/MarkdownSupport.md` | 7.27 ms | 7.37 ms |
| `Docs/CompatibilityMatrix.md` | 15.71 ms | 15.86 ms |
| One line, 2,000 code spans | 15.32 ms | 15.52 ms |
| One line, 2,000 bare URLs | 65.29 ms | 65.90 ms |
| One line, 2,000 bare URLs with `&amp;` | 91.82 ms | 91.16 ms |
| One line, 2,000 bare URLs each followed by a code span | 79.03 ms | 77.67 ms |
| One line, 2,000 entities | 11.00 ms | 11.01 ms |
| One line, 2,000 Markdown links | 41.99 ms | 42.28 ms |
| 2,000 prose lines with a code span each | 73.84 ms | 74.09 ms |

Every ratio is between 0.98 and 1.03, within run-to-run noise.

## Risks / Trade-offs

- **[Behavior change on authored U+E000 text]** → Confined to the classes above and declared in the spec. Every class moves the cut and the guard to the resolver's reading, and none links text the old code left literal unless that text is a spelling the resolver itself emits literally.
- **[The resolver's hot loop changed shape]** → Same bytes on every differential input, and the timing table shows no regression. The literal-run copy keeps the ASCII-flag property `speed-up-token-restore` requires.
- **[Pre-existing bugs found on the way]** → Recorded in `TODOS.md` with reproductions; all three reproduce on `main` without private-use text, so they are independent of this change.
