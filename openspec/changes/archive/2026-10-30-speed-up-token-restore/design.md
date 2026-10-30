## Context

`InlineProtector` swaps every protected inline fragment for a `\u{E000}MD2-<n>\u{E000}` placeholder token, and `resolveTokens` puts the fragments back: once per inline pass through `restore(in:)`, and mid-pipeline through `restore(in:)`, `source(in:)` and `attributeText(in:)` for URL safety checks, reference-link and bare-URL matching, and attribute text. It scans the text's Unicode scalars for the sentinel, appends each well-formed token's entry, and copies the literal runs between tokens.

The literal runs were copied with `result.unicodeScalars.append(contentsOf: scalars[run])`. That path re-encodes each scalar into the result one at a time. A microbenchmark on a token-dense 150 KB string put it at 12.3 ms against 0.56 ms for a bulk copy. Profiling `scan-inline-delimiter-ownership` attributed about 14% of the dense 2,000-line workload to it, and that change deferred the fix here.

## Goals / Non-Goals

**Goals:**

- Copy literal runs in bulk, with output byte-identical to the scalar copy.
- No slower anywhere: neither in the resolver nor in the passes that consume its output.

**Non-Goals:**

- The sentinel search, the token grammar, the D4 boundary, and the authored-token amplification TODO.

## Decisions

### D1: Copy each literal run as `String(text[run])`

The run bounds come from the scalar view, so they are scalar-aligned but may fall inside a grapheme cluster. A combining mark after a closing sentinel starts a run mid-cluster. A prepended concatenation mark such as U+0600 before an opening sentinel ends one mid-cluster. `String`'s range subscript rounds only to scalar boundaries, not to `Character` boundaries, so the slice is exact in both cases. A probe confirmed both, and `combiningMarkAfterSentinelDoesNotHideToken` and the new `prependedMarkBeforeSentinelIsKept` pin them.

Converting the slice to a `String` copies its bytes and rescans them, so a run of ASCII text yields a string flagged ASCII. Appending only ASCII-flagged strings keeps the result flagged ASCII, as the scalar-by-scalar copy did, because it recomputed the flag for every scalar. Short runs fit in a small inline string and allocate nothing.

*Alternatives rejected:*

- **Append the `Substring` directly** (`result.append(contentsOf: text[run])`). The resolver itself is just as fast, but a `Substring` append inherits the flags of its whole base string, and the text being resolved always holds the non-ASCII sentinel. A probe showed the result flagged neither ASCII nor NFC even when every byte was ASCII. The HTML the renderer then assembles, matches with `NSRegularExpression`, and converts with `NSRange(_:in:)`/`Range(_:in:)` no longer qualifies for the ASCII fast path; one range conversion measured about 2.6× slower. End to end, this made the dense workload about 7% slower, a line of 2,000 code spans about 38% slower, and 2,000 paragraphs with links about 12% slower, against the scalar copy it was meant to beat.
- **Append `Substring`s, then re-decode the whole result.** It measured the same as D1 and restores the flags, but it copies the output a second time to undo a side effect the run copy should not cause.
- **Search the sentinel by UTF-8 byte.** It saved about 0.15 ms per 100 KB of resolved text. Its lead byte `0xEE` also starts other scalars, so every hit needs a second check, and the scalar search is not where the time goes.

## Behavior

None. Rendered output is byte-identical:

- All 1,167 repository Markdown documents and CommonMark/GFM examples render byte-identically to `HEAD`.
- All 571,884 generated inputs from the `scan-inline-delimiter-ownership` differential corpora render byte-identically to that change without this one.

## Risks / Trade-offs

- **[The ASCII flag is a standard-library implementation detail]** → If a future toolchain stops recomputing flags on `String(Substring)`, the cost is performance only, never output. The probe workloads below would show it.
- **[Mid-cluster bounds]** → An implementation that slices, searches or appends at `Character` granularity would split or hide a token. Two tests pin it, one for each end of a run. A mutation that searches the sentinel as a `Character` fails `prependedMarkBeforeSentinelIsKept` but not the older start-of-run test.

## Performance

`swiftc -O` probes of this change against `scan-inline-delimiter-ownership` without it. Best of 7 for real documents and best of 5 for synthetic workloads, three alternating rounds, Apple Silicon:

| Workload | Before | This change |
| --- | --- | --- |
| `README.zh-CN.md` | 5.81–5.99 ms | 5.86–6.47 ms |
| `README.md` | 7.13–7.25 ms | 7.05–7.14 ms |
| `Examples/Sample.md` | 11.38–11.61 ms | 11.44–11.69 ms |
| `Docs/MarkdownSupport.md` | 7.43–7.51 ms | 7.39–7.42 ms |
| `Docs/CompatibilityMatrix.md` | 16.14–16.34 ms | 15.87–16.10 ms |
| 2,000 prose lines, no delimiters | 75.3–77.8 ms | 75.7–77.9 ms |
| 2,000 lines, each with a code span, `$…$` and `\(…\)` | 114.4–116.5 ms | 101.1–102.1 ms |
| One line, 2,000 code spans | 16.39–16.53 ms | 15.60–15.91 ms |
| One line, 2,000 `$…$` spans | 19.29–19.71 ms | 17.83–18.18 ms |
| One line, 2,000 `\(…\)` spans | 20.15–20.78 ms | 18.63–19.26 ms |
| One line, 2,000 currency amounts | 16.09–16.34 ms | 16.04–16.47 ms |
| One line, 2,000 unterminated `\(` | 13.76–14.09 ms | 13.32–13.60 ms |
| One line, 2,000 backslash escapes | 22.07–22.27 ms | 21.06–23.27 ms |
| 2,000 paragraphs with links, paren math and `` `](` `` | 165.6–167.0 ms | 163.3–166.1 ms |

Token-dense workloads are 4–12% faster; workloads with few tokens are unchanged. The two 6.47 ms `README.zh-CN.md` readings were machine noise. A focused probe of 60 samples per round, over six rounds in both orders, gave minimums of 5.56–5.84 ms for this change and 5.63–6.05 ms before, and `README.md` moved with it in the slow rounds.

## Migration Plan

Render-only change with no data migration, no asset or dependency change, and no API change. Rollback is reverting `InlineProtector.resolveTokens` and the one test; the delta spec reverts with the change directory. Neither `PDFExporter.swift` nor `DocumentPrinter.swift` is touched, so the GUI-gated suites are not required.
