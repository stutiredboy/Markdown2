## Why

The inline pipeline claims code spans, `$...$` math and `\(...\)` math in three independent passes, in a fixed order (code, then `$`, then `\(`). Sequential passes cannot establish delimiter ownership by position: whichever pass runs first claims its span even when that span sits inside another construct, and its placeholder token later restores as nested HTML. The math engine reads the outer span's text content, so the nested markup silently drops characters from valid input:

- `\(\text{$x$}\)` reaches KaTeX as `\text{x}`: the `$` pass claims `$x$` first and restores it as a nested `<span class="math">`, so the dollar signs vanish.
- `` $a `b` c$ `` restores the code span as a nested `<code>`, so the TeX loses its backticks.
- `\(a$b\) and \(c$d\)` merges into one span: the `$` pass claims `$b\) and \(c$` across both, and the outer `\(` pass wraps it.

The Codex outside voice demonstrated the first case against the bundled KaTeX during the `add-latex-math-compat` eng review (2026-09-24). That change declared it as a boundary, pinned the nested-span behavior with a test as the before-state proof, and recorded the principled fix in `TODOS.md` ("Left-to-right delimiter ownership scan"). Nothing throws; the equation is just wrong, which is the silent-failure class this project's guardrails target.

The same machinery is also quadratic on one input shape: every unterminated `\(` makes the regex read to the end of the line, so a line of 1,000 such openers renders in 62 ms and 2,000 in 246 ms.

## What Changes

- **One reading-order scan replaces the three passes.** `protectVerbatimSpans` asks `VerbatimSpanScanner` for the code spans and inline math spans of the inline text in one left-to-right walk over Unicode scalars. The earliest opener with a valid closer owns its span, and its content reaches the renderer verbatim.
- **Code spans bind tighter than math**, as the former pass order made them. A math span may contain a whole code span, whose backticks are then TeX source, but it never closes inside one. That keeps `` The plan costs $20/month. Set `$API_KEY` first. `` intact; pure reading order (Pandoc's rule) would typeset `20/month. Set `` as math.
- **Between the two math forms, reading order decides**, and the other form's delimiters inside an owned span are plain TeX.
- **Every delimiter keeps its guards exactly**: the `$` currency, whitespace and `$$` rules, the escaped-opener rules, the backslash pairing inside math, and the link-destination exclusion for `\(`. A probe confirmed that ICU's `.` and `\s` match the scalar sets the scan uses. Five of these guards had no test; each gets one.
- **Destination classification for `\(` uses the same nearest-opener rule, tracked as the scan goes.** A claimed span reads as one opaque unit, as its placeholder token does for every later pass, so link syntax inside inline code or math cannot open a destination. A `\(` rejected inside a destination no longer hides a later opener outside it.
- **One destination rule, two consumers.** `LinkDestinationTracker` holds the rule; `LinkDestinationIndex` (autolinks) replays it for random-access lookups. This replaces the index's global-balance close bookkeeping; a fuzz run confirmed the two give the same answers on 4.5 million positions. Both now read Unicode scalars, the unit the link patterns match, so a combining mark right after a parenthesis no longer hides it.
- **Linear time.** Backtick runs are paired once up front. A failed `\(` attempt records where it stopped, and later openers before that point fail without rereading the line.
- **Declare the change.** Update the `tex-math` and `inlines` matrix entries, regenerate `Docs/CompatibilityMatrix.md`, add the rule to the math bullet in `Docs/MarkdownSupport.md`, and remove the resolved items from `TODOS.md`.
- **Add regression tests** for nesting, code precedence, crossings between the math forms, the carried-over guards, destination tracking, the scalar unit, and three new scaling workloads.

**Non-goals** (deliberately out of scope):

- A backslash before a backtick outside math still lets a code span open (`` \`x` ``), a pre-existing CommonMark divergence of the code-span grammar.
- Display math, block parsing, and every inline pass after the verbatim spans (escapes, entities, autolinks, raw HTML, links, emphasis).
- Authored placeholder tokens: the D4 boundary and the output-amplification TODO are unchanged.
- The `InlineProtector` resolver's scalar-view appends, which profiling showed to be slow; the separate `speed-up-token-restore` change fixes them.
- Any GUI, preview JavaScript/CSS, PDF/print, HTML-export, or public API change.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `math-rendering`: adds the reading-order delimiter-ownership requirement: nesting, code precedence, crossings between the math forms, the carried-over guards, destination tracking, and linear time.
- `inline-render-performance`: destination classification is one scalar-based nearest-opener rule, shared by the autolink index and the scan's incremental tracking. The scaling suite covers verbatim spans, unpaired dollars, and unterminated `\(` openers.

## Impact

- `Sources/MD2Core/MarkdownRenderer.swift`: `protectVerbatimSpans` and `protectedFragment` replace `protectCodeSpans`, `protectInlineMath` and `protectInlineParenMath`. New `VerbatimSpan`, `VerbatimSpanScanner` and `LinkDestinationTracker`; `LinkDestinationIndex` is rebuilt on the tracker.
- `Tests/MD2CoreTests/MathRenderingTests.swift`: the pinned nested-span boundary test becomes the ownership tests, plus guard and destination tests.
- `Tests/MD2CoreTests/InlineRenderingPerformanceTests.swift`: a scalar-unit destination test and three scaling workloads.
- `Tests/MD2CoreTests/Matrix/compatibility-matrix.json` and the regenerated `Docs/CompatibilityMatrix.md`; `Docs/MarkdownSupport.md`; `TODOS.md`.
- No public API, dependency, preview JavaScript/CSS, PDF/print, HTML-export, or GUI-gated path changes. The whole change is covered by plain `swift test`.
