## Context

`MarkdownRenderer.inlineHTML` runs an ordered pipeline of inline passes. Its first three passes claimed the verbatim constructs, each with its own regular expression over the whole inline text:

1. `protectCodeSpans` — `` (?<!`)(`+)(?!`)([\s\S]*?)(?<!`)\1(?!`) ``
2. `protectInlineMath` — `(?<![$\\])\$(?![\s$])((?:\\.|[^\\$])+?)(?<!\s)\$(?!\$)`
3. `protectInlineParenMath` — `(?<!\\)\\\(((?:\\.|[^\\])+?)\\\)`, with each match filtered through `LinkDestinationIndex` so a `\(` inside `](…)` stays a CommonMark escape.

Each pass swapped its matches for `\u{E000}MD2-<n>\u{E000}` placeholder tokens, so a later pass saw an earlier pass's spans as opaque runs and could wrap them. When a later pass's span contained a token, restoration produced nested HTML. Nested HTML is harmless for emphasis, but the preview hands a math span's `textContent` to KaTeX, so the inner markup's delimiters disappear: `\(\text{$x$}\)` typesets `\text{x}`. The pass order also decided every crossing: the `$` pass always won, so `\(a$b\) and \(c$d\)` became one outer span wrapped around `$b\) and \(c$`.

The `add-latex-math-compat` change declared this as a boundary, pinned the nested-span output with `dollarMathNestedInParenDelimitedMathDoesNotBreakTheDocument`, and recorded the fix in `TODOS.md`: one left-to-right scan that establishes ownership by position.

## Goals / Non-Goals

**Goals:**

- Every nesting of code spans and the two inline math forms reaches its renderer verbatim.
- One scanner replaces three passes whose relative order was only a comment.
- Behavior outside the nesting and crossing cases is unchanged, and that claim is measured rather than argued.
- No slower than the regex passes on real documents, and linear on every input shape.

**Non-Goals:**

- Changing the code-span grammar (it still ignores a backslash before a backtick), display math, block parsing, or any later inline pass.
- Authored placeholder tokens: the D4 boundary and the amplification TODO are unchanged.
- The `InlineProtector` resolver's own append path, measured as slow while profiling this change (see Performance); the separate `speed-up-token-restore` change fixes it.

## Decisions

### D1: One scan; the earliest opener with a valid closer owns its span

`VerbatimSpanScanner` walks the inline text's Unicode scalars once. At each position it asks whether a code span, a `$` span, or a `\(` span opens there and has a valid closer; the first position that succeeds claims the span, and the walk resumes after it. The openers start with different scalars, so two kinds can never tie at one position. `protectVerbatimSpans` then protects each span exactly as the old passes did (same fragment, same authored `source`), in reading order.

A failed attempt does not consume anything: the walk moves one scalar on and keeps looking, the way a regular-expression search tries every start position. That is also why a `\(` rejected inside a link destination no longer hides a later opener (D5).

### D2: Code spans bind tighter than math

Pure reading order (Pandoc's rule, and markdown-it-katex's) would regress real text. In `` The plan costs $20/month. Set `$API_KEY` first. ``, the `$` before `20` finds a valid closer inside the code span, so the sentence would typeset `20/month. Set `` and break the code span. The old pass order protected this sentence by accident, and the math spec already states "inline code … precedence over math detection".

So inside math content a code span is atomic. When the content scan reaches the opening run of a code span, it skips to the end of that span, and a `$` or `\)` inside it cannot close the math. A math span may therefore contain a whole code span, whose backticks are TeX source, but never closes inside one. CommonMark applies the same rule to links: link text may contain a code span but cannot cut through one.

The code spans are the ones the left-to-right pairing yields: a maximal run opens, and the next run of exactly the same length closes it. That is the old regex's grammar, computed once up front. A backslash right before a code span's opening run stands alone instead of pairing with the backtick, so the code span stays the next item. In the old passes the backslash paired with the token's first sentinel, which skipped the code span the same way. The scan therefore finds exactly the closers the old passes found; only the restored content changes.

*Alternative rejected:* pure reading order, for the regression above.

### D3: Between the two math forms, reading order decides

Inside an owned `\(…\)` span, `$` is plain TeX; inside an owned `$…$` span, `\(` and `\)` are already TeX pairs, as before. `\(a$b\) and \(c$d\)` becomes two spans, and `\( a $b \) c$` becomes the paren span ` a $b ` followed by a literal ` c$`.

*Alternative rejected:* keeping `$` spans atomic inside paren content, which preserves the old crossing results exactly. That still merges `\(a$b\) and \(c$d\)` into one span (now with verbatim content), and it keeps an ordering rule that exists only because of the old pass order. A crossing pair of delimiters is invalid TeX either way; reading order at least confines KaTeX's visible error to the span that holds it.

### D4: Each delimiter's guards are carried over exactly

The scan reimplements the regular expressions' guards over scalars:

| Guard | Former pattern | Scan |
| --- | --- | --- |
| `$` opens | `(?<![$\\])\$(?![\s$])` | previous scalar is not `$` or `\`; next is not whitespace or `$` |
| `$` closes | `(?<!\s)\$(?!\$)`, content `(?:\\.\|[^\\$])+?` | the first `$` reached closes when not after whitespace and not before `$`, otherwise the attempt fails |
| `\(` opens | `(?<!\\)\\\(` + destination filter | previous scalar is not `\`; not inside a destination (D5) |
| `\(` closes | lazy `(?:\\.\|[^\\])+?` then `\\\)` | the first `\)` after at least one content item |
| backslash in math | `\\.` | pairs with the next scalar unless it is a line terminator or the end, which fails the attempt |

Two character classes had to match exactly. An exhaustive probe of every Unicode scalar against `NSRegularExpression` confirmed that ICU's `\s` is the Unicode `White_Space` property (`Unicode.Scalar.Properties.isWhitespace`) and that its `.` excludes exactly U+000A–U+000D, U+0085, U+2028 and U+2029. A mutation pass then found that five of these guards had no test: `$` before whitespace, `$` after `$` or `\`, a closer before `$`, a backslash before a line terminator inside a line, and `\(` after a backslash. Each now has one (`carriedOverGuardsKeepTextLiteral`).

### D5: Destination classification is one scalar rule, shared and incremental

The nearest-opener rule now lives in `LinkDestinationTracker`, fed one unit at a time. A `(` right after `]` (escaped or not) opens a destination; the first unescaped `)` that brings the paren balance back below that `(` closes it; a position is inside when the most recent opener before it is still open. Only the most recent opener matters. If an older opener's close came after the next opener, every position it could affect is already governed by the newer opener, so the tracker keeps just the global balance and the open opener's level.

- `LinkDestinationIndex` (autolinks) replays the tracker over the text, recording each opener's start and close for binary-searched lookups. This replaces the per-level close lists and their search (`closesByBalance`/`firstClose`). Against the previous implementation, 300,000 random strings over `\ ( ) [ ] a` gave identical `contains` results at all 4,502,916 positions.
- The scan feeds the tracker its own output prefix: plain scalars as it passes them, and one opaque unit for each claimed span, which is what the span's placeholder token is to every later pass. Link syntax inside inline code or math therefore cannot open a destination. The old paren pass already saw code and `$` spans as tokens, but it read earlier paren spans raw, so `\(](\) then \(y\)` left `\(y\)` literal.
- The unit is the Unicode scalar, the unit the link and autolink patterns match. The old index read grapheme clusters, so `)` followed by a combining mark did not count as a paren, while the link pattern still closed the link there. For example, `[a](b)́ <https://e.com>` rendered the link but left the autolink literal; both readers now agree.
- When the tracker is not needed (no `](` byte pair in the text), the scan skips it entirely.

### D6: Linear time

- Backtick runs are collected once, and each run's same-length successor is found in one right-to-left sweep, so pairing never rescans the text. The old regex rescanned to the end of the text for every unmatched run.
- A failed `$` attempt stops at the first `$` it reaches outside a code span. No later `$` opener lies before that point (any `$` in between is escaped or inside a code span), so failed `$` attempts read disjoint stretches.
- A failed `\(` attempt records where it stopped (the end, or a backslash before a line terminator). A later opener before that point is a backslash-pair boundary in the failed attempt's own pairing (its preceding scalar is not `\`, and it is not inside a code span, since the walk claims those first). From its content start it therefore reads the same items, finds the same lack of a closer, and fails without reading. This turns N unterminated openers from O(N·L) into O(L).
- The fast paths are byte walks. A probe showed the generic `utf8.contains(_:)` subsequence search to be about 160× slower than a byte loop, and `String.contains("](")` about 18× slower, so neither is used on these per-paragraph paths. Output is assembled by appending `Substring` slices; appending through `unicodeScalars` measured about 100× slower. A `Substring` append inherits its base string's flags, but this output always holds placeholder tokens and is never ASCII, so nothing is lost here; the resolver, whose output can be ASCII, needs a different copy (`speed-up-token-restore`).

## Behavior Changes

Measured with `swiftc -O` probes of `HEAD` and this change, rendering the same inputs:

- **Real documents and conformance examples: no change.** All 266 Markdown documents in this repository (READMEs, `Docs/`, `Examples/`, every OpenSpec spec and change) and all 676 CommonMark/GFM examples render byte-identically.
- **Fuzzing: every difference falls in a declared class.** Of 570,000 generated inputs (random delimiter-heavy strings and structured combinations over two seeds, plus an autolink-focused set), 42,111 (7.4%) render differently, each in one of these classes:
  1. *Nested markup inside math* (about 37,000): a code span or the other math form inside a math span now reaches KaTeX as TeX source instead of nested `<code>`/`<span>`. This is the fix.
  2. *Crossing math forms* (about 4,000): the earliest opener now owns its span; previously `$` always won.
  3. *Destination edges* (under 100): link syntax inside a claimed span no longer opens a destination, and a rejected `\(` no longer hides a later one.
  4. *Combining mark after a paren* (a few hundred, autolink set included): scalar units, as described in D5.

  Apart from class 4, no input without `\(` changed except through class 1, and no new output contains nested markup inside a math span.

## Risks / Trade-offs

- **[The most regression-sensitive inline machinery]** → Guarded by the differential run above, the full suite, and mutation checks: removing code-span atomicity, the `\(` failure frontier, opaque claimed spans, or any carried-over guard each fails at least one test.
- **[KaTeX now sees characters it used to lose]** → Backticks inside math and crossing delimiters now reach the engine. Invalid TeX shows KaTeX's visible error in place of silently wrong output, which is the behavior the math spec asks for.
- **[Scalar units change autolink classification after a combining mark]** → Only when a combining mark directly follows `(`, `)`, `]` or `\`. The new reading agrees with the link pattern, and `combiningMarkAfterClosingParenStillClosesTheDestination` pins it.
- **[Spec drift]** → `inline-render-performance` named `protectInlineParenMath` and a precomputed index for paren math; the modified requirement describes the shared tracker and adds the new scaling workloads.

## Performance

Best of 7 for real documents and best of 5 for synthetic workloads, three alternating rounds, Apple Silicon:

| Workload | HEAD | This change |
| --- | --- | --- |
| `README.zh-CN.md` | 6.12–6.39 ms | 5.81–6.62 ms |
| `README.md` | 7.47–7.57 ms | 7.04–7.91 ms |
| `Examples/Sample.md` | 11.7–12.0 ms | 11.3–11.6 ms |
| `Docs/MarkdownSupport.md` | 7.84–8.02 ms | 7.42–7.61 ms |
| `Docs/CompatibilityMatrix.md` | 17.8–17.9 ms | 16.1–16.2 ms |
| 2,000 prose lines, no delimiters | 80.7–82.8 ms | 77.2–77.7 ms |
| 2,000 lines, each with a code span, `$…$` and `\(…\)` | 121.1–122.5 ms | 114.9–115.8 ms |
| One line, 2,000 code spans | 17.7–18.0 ms | 16.4–16.6 ms |
| One line, 2,000 `$…$` spans | 21.5–21.8 ms | 19.6–19.9 ms |
| One line, 2,000 `\(…\)` spans | 21.5–22.1 ms | 20.1–21.1 ms |
| One line, 2,000 currency amounts | 18.5–18.7 ms | 16.3–16.4 ms |
| One line, 1,000 / 2,000 unterminated `\(` | 62.2–63.6 / 242.0–250.6 ms | 6.77–6.93 / 13.9–14.0 ms |
| One line, 1,000 unmatched backtick runs | 7.95–8.23 ms | 7.66–7.81 ms |
| One line, 2,000 backslash escapes | 23.5–24.1 ms | 22.0–22.1 ms |
| 2,000 paragraphs with links, paren math and `` `](` `` | 176.1–179.3 ms | 164.4–165.0 ms |

Real documents are within run-to-run noise or slightly faster, and every synthetic workload is faster. The quadratic unterminated-opener line is now linear (×2.0 per doubling, against ×3.9 before). Profiling also showed that `InlineProtector.resolveTokens` appends through `unicodeScalars`, the same slow path avoided above; at about 14% of the dense 2,000-line workload it gets its own change, `speed-up-token-restore`.

## Migration Plan

Render-only change with no data migration, no asset or dependency change, and no API change. Rollback is reverting `Sources/MD2Core/MarkdownRenderer.swift` together with the tests, the matrix entries, the regenerated matrix doc, and the docs bullet; the delta specs revert with the change directory. The change touches neither `PDFExporter.swift` nor `DocumentPrinter.swift`, so the GUI-gated suites are not required.

## Open Questions

- Should a backslash before a backtick stop a code span from opening outside math, as CommonMark specifies? Deferred: it changes the code-span grammar for every document, which is a separate conformance decision.
