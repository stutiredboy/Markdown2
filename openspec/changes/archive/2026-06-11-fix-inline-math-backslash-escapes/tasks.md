# Tasks: Fix Inline Math Backslash Escapes

## 1. Regression tests (red first)

- [x] 1.1 Add `MathRenderingTests` cases for backslash TeX commands in inline math: `$h = I \cdot C_\text{eff} = 0.25\,C_\text{eff}$` keeps `\,` verbatim in the span, `$z_{98\%}=2.05$` keeps `\%`, and rendered HTML never contains `MD2-`
- [x] 1.2 Add test: `$\text{Inv\$} = AIL \cdot C_\text{eff}$` produces a single math span whose TeX source contains `\text{Inv\$}` (interior `\$` does not close the span)
- [x] 1.3 Add false-positive tests: `\$18 125 … \$10 633` on one line produces no math span; `\$5，公式为 $x+1$` renders literal `$5` plus one math span for `x+1`
- [x] 1.4 Run the test suite and confirm the new tests fail against current code (placeholder leak / stripped backslashes)

## 2. Renderer fix

- [x] 2.1 In `inlineHTML` (Sources/MD2Core/MarkdownRenderer.swift), move `protectInlineMath` before `protectBackslashEscapes` and update the pipeline-order doc comment
- [x] 2.2 Update the `protectInlineMath` regex to the backslash-aware pattern `(?<![\$\\])\$(?![\s$])((?:\\.|[^\\$])+?)(?<!\s)\$(?!\$)` and revise its doc comment (escaped `\$` never opens math; interior `\\.` sequences are consumed with their backslash)
- [x] 2.3 Change `InlineProtector.restore` to iterate fragments in descending index order so fragments embedding earlier tokens restore fully; update its doc comment

## 3. Verification

- [x] 3.1 Run the full test suite (`swift test`) — all new and existing tests pass, including `escapedDollarIsLiteral`, `currencyTextIsNotMath`, and the code-precedence math tests
- [x] 3.2 Render the reporting document (案例5-CHS全能五金供应公司库存优化-案例解答.md) in the app preview and confirm formulas like `0.25\,C_\text{eff}`, `z_{98\%}`, `\text{Inv\$}` typeset correctly with no `MD2-` artifacts
- [x] 3.3 Update Docs/MarkdownSupport.md if it documents inline-math escape behavior affected by this change
