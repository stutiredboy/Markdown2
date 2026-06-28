# Fix Inline Math Backslash Escapes

## Why

Inline math containing backslash-punctuation TeX commands (`\,`, `\%`, `\$`, `\;`, `\{`, …) renders corrupted: `$h = I \cdot C_\text{eff} = 0.25\,C_\text{eff}$` shows up as `h = I \cdot C_\text{eff} = 0.25MD2-0C_\text{eff}` — an internal protection placeholder leaks into the visible output and the TeX command is destroyed. Real academic documents (e.g. inventory-management case answers full of `0.25\,C_\text{eff}`, `z_{98\%}`, `\text{Inv\$}`) are unreadable in preview.

Two defects in `MarkdownRenderer.inlineHTML` combine to cause this:

1. **Pipeline order**: `protectBackslashEscapes` runs *before* `protectInlineMath`, so a TeX command like `\,` inside `$...$` is consumed as a Markdown backslash escape — the backslash is dropped and the punctuation is swapped for a placeholder token before the math pass ever sees the span.
2. **Nested-placeholder restore**: `InlineProtector.restore` replaces tokens in ascending index order. The math span (higher index) embeds the escape's token (lower index) in its body, so by the time the math fragment is inserted, the pass that would have restored the inner token has already run — `MD2-0` leaks verbatim into the DOM.

## What Changes

- Reorder the inline pipeline so `protectInlineMath` runs before `protectBackslashEscapes`, preserving TeX backslash commands verbatim inside math spans.
- Make the inline-math pattern backslash-aware so the reorder does not regress escape handling:
  - an escaped `\$` never opens a math span (existing behavior, currently guaranteed by the old pass order);
  - `\$` *inside* a math span is passed through to KaTeX verbatim instead of terminating the span (e.g. `$\text{Inv\$}$`).
- Fix `InlineProtector.restore` to restore fragments in descending index order so any fragment embedding an earlier token (e.g. an inline-code token inside a math span) is fully restored — placeholder tokens never reach the DOM.
- Add regression tests covering TeX spacing/punctuation commands in inline math, escaped dollars inside and outside math, and the placeholder-leak case.

No breaking changes — display math (`$$...$$`) is handled at block level and is unaffected.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `math-rendering`: The "Inline math rendering" requirement gains explicit guarantees that backslash TeX commands (`\,`, `\%`, `\{`, `\$`, …) inside `$...$` reach the math engine verbatim, and that internal protection placeholders never appear in rendered output. The "Avoid false-positive math detection" requirement gains a scenario distinguishing `\$` outside math (literal, never a delimiter) from `\$` inside math (part of the TeX source).

## Impact

- `Sources/MD2Core/MarkdownRenderer.swift`: `inlineHTML` pipeline order, `protectInlineMath` regex, `InlineProtector.restore`.
- `Tests/MD2CoreTests/MathRenderingTests.swift`: new regression tests.
- `openspec/specs/math-rendering/spec.md`: requirement deltas (via this change's delta spec).
- No API, dependency, or asset changes; KaTeX pipeline downstream is untouched.
