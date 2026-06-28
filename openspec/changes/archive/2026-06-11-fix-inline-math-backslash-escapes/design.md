# Design: Fix Inline Math Backslash Escapes

## Context

`MarkdownRenderer.inlineHTML` (Sources/MD2Core/MarkdownRenderer.swift:755) renders inline Markdown through an ordered pipeline of protection passes. Fragments that must survive HTML-escaping (code spans, math, entities, …) are swapped for private-use-area placeholder tokens (`\u{E000}MD2-<n>\u{E000}`) by a shared `InlineProtector`, and restored in one final step.

The current order is:

1. `protectCodeSpans`
2. `protectBackslashEscapes` — protects `\<punct>` as the literal punctuation (backslash dropped)
3. `protectInlineMath` — protects `$...$` content as a KaTeX span
4. … (entities, autolinks, raw HTML, footnotes, escape, emphasis, images, links)

Two defects:

- **Order**: TeX commands made of backslash + punctuation (`\,`, `\%`, `\{`, `\$`, `\;`, `\_`, …) inside `$...$` are consumed by pass 2 before pass 3 sees the span. The backslash is dropped and a placeholder token is embedded in what later becomes the math span's body.
- **Restore**: `InlineProtector.restore` (line 1539) replaces tokens in *ascending* index order. A math fragment (created later, higher index) embeds the escape's token (lower index). When the math fragment is inserted into the result, index 0 has already been processed, so the inner token is never replaced — the U+E000 sentinels are invisible and `MD2-0` leaks verbatim into the DOM.

The existing pass order is load-bearing in one respect: running escapes before math is what currently stops `\$` from acting as a math delimiter (`Price: \$x` must stay literal — covered by `MathRenderingTests.escapedDollarIsLiteral`).

Display math (`$$...$$`) is detected at block level (`mathDisplayHTML`, line 262) before the inline pipeline runs, so it is unaffected.

## Goals / Non-Goals

**Goals:**

- Backslash TeX commands inside `$...$` reach KaTeX verbatim (`0.25\,C_\text{eff}` typesets as written).
- `\$` inside a math span is part of the TeX source and does not terminate the span (`$\text{Inv\$}$`).
- `\$` outside math still never opens or closes a math span (no regression of currency/escape behavior).
- Protection placeholder tokens never appear in rendered output, even when fragments nest (e.g. a code-span token inside a math span body).

**Non-Goals:**

- No change to display-math (`$$`) block detection.
- No change to the KaTeX asset pipeline or the JS-side typesetting.
- Not adding new math delimiters (`\(...\)`, `\[...\]`).
- Not handling the pathological `\\` + `$x$` adjacency (literal backslash immediately followed by math, e.g. `\\$x$`) — see Risks.

## Decisions

### D1: Reorder — run `protectInlineMath` before `protectBackslashEscapes`

The math pass must see the raw source so it can capture TeX backslash sequences before Markdown escape processing destroys them. Code spans stay first (code has precedence over math per the existing spec).

**Alternative considered**: keep the order and make `protectBackslashEscapes` skip regions inside `$...$`. Rejected — it duplicates math-span detection in a second pass, and the two regexes would have to be kept in lockstep.

### D2: Make the inline-math regex backslash-aware

The old order was what kept `\$` from acting as a delimiter; after the reorder the regex itself must guarantee it. New pattern:

```
(?<![\$\\])\$(?![\s$])((?:\\.|[^\\$])+?)(?<!\s)\$(?!\$)
```

- `(?<![\$\\])` — opening `$` is neither part of `$$` nor escaped (`\$` never opens math).
- `(?:\\.|[^\\$])+?` — content consumes any backslash *with* its following character (`\,`, `\$`, `\{`, `\c` of `\cdot`, …), so an interior `\$` cannot be mistaken for the closing delimiter, and a trailing lone backslash cannot dangle before the close.
- `(?![\s$])`, `(?<!\s)`, `(?!\$)` — unchanged whitespace/`$$` guards.

The captured content is HTML-escaped and emitted verbatim into the KaTeX span, exactly as today.

**Alternative considered**: two-stage escape protection (protect only `\\` and `\$` before math, the rest after). Rejected — protecting `\$` before math would put a placeholder token *inside* the math body again for `$\text{Inv\$}$`, recreating the corruption it is meant to fix.

### D3: Restore fragments in descending index order

Nesting is strictly one-directional: a fragment can only embed tokens *created before it* (lower index). Restoring from the highest index down inserts outer fragments first, then resolves their embedded inner tokens in later iterations. One-line change in `InlineProtector.restore`; fixes the leak for every nesting combination (math-over-escape today, math-over-code-span, and any future pass), not just the reported one.

**Alternative considered**: loop ascending until a fixed point. Rejected — same result, more code, unbounded iterations in theory.

### D4: Test against the real-world corpus shapes

Regression tests use the exact shapes from the reporting document: `$h = I \cdot C_\text{eff} = 0.25\,C_\text{eff}$`, `$z_{98\%}=2.05$`, `$\text{Inv\$} = AIL \cdot C_\text{eff}$`, plus a guard that `MD2-` never appears in rendered HTML and that the existing escaped-dollar/currency behaviors still hold.

## Risks / Trade-offs

- [`\$` followed later by another `$` on the same line, outside math] → The opening lookbehind rejects escaped dollars, and the content class excludes bare `$`, so `\$5 … \$10` still cannot pair up; covered by keeping `currencyTextIsNotMath` and `escapedDollarIsLiteral` green.
- [Literal `\\` immediately before math: `\\$x$`] → The single-character lookbehind cannot distinguish `\$` (escaped dollar) from `\\` + `$` (escaped backslash then math), so math is not recognized there. This is a pre-existing limitation made explicit, pathological in practice, and strictly safer than the inverse error; documented as a non-goal.
- [Regex performance] → The content alternation is linear with non-greedy matching over short spans (inline math within a single line); no catastrophic backtracking states exist since the two branches are disjoint on `\`.
- [Behavior drift between spec and code] → The delta spec adds scenarios for every behavior changed here; tests mirror the scenarios one-to-one.
