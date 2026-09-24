## Why

Documents authored in LaTeX-flavored Markdown — converted papers, course notes, and LLM-generated math — routinely use `\(...\)` for inline math and bare `\begin{align}` / `\begin{equation}` environments with no `$$` wrapper. Markdown2 recognizes only `$...$` inline and `$$` / `\[` at block level, so these forms fail quietly rather than loudly: `\(x^2\)` renders as the literal text `(x^2)` because Markdown escape handling eats the backslash, and a bare `\begin{align}` block renders as mangled prose (`begin{align} a &= b end{align}`) instead of an equation. Nothing errors and nothing blanks — the equation is simply wrong — which is the silent-failure class the project's maths and export guardrails exist to catch.

## What Changes

- **Inline `\(...\)` delimiters.** Detect `\(...\)` within a line and render it as inline math alongside the existing `$...$`. A new inline pass runs *before* backslash-escape handling, so TeX commands inside the span (`\,`, `\%`, `\{`) reach the math engine verbatim — the same guarantee `$...$` already carries, for the same reason.
- **Native math environments without `$$`.** Recognize a block that opens with `\begin{<env>}` and closes with the matching `\end{<env>}` as display math. The recognized set is enumerated: the engine-supported display environments (`align`, `align*`, `alignat`, `alignat*`, `gather`, `gather*`, `equation`, `equation*`) plus the probe-verified standalone inner environments (`aligned`, `alignedat`, `split`, `cases`, `array`, and the matrix family). The closer scan matches by name with same-name depth counting, never crosses a fenced-code boundary, and the TeX handed to the engine retains the environment commands. Environments the engine rejects (`multline`, `eqnarray`, `displaymath`, `subequations`) are recognized too, so they surface a visible engine error instead of having their source mangled into prose.
- **Numbering and cross-references extend unchanged.** `\label{}` is stripped before the engine (it cannot typeset it) and registered for `\ref{}`; `\tag{}` is left in place for the engine; Markdown2 assigns the `(n)`. Measured rather than assumed: bundled KaTeX 0.16.11 does **not** auto-number `align` / `equation`, so the engine's numbering and Markdown2's cannot collide.
- **`$$...$$` and `\[...\]` behaviour is unchanged.** Block-level `\[...\]` support already exists in `mathBlockContent`; this change adds regression coverage and documentation for it, not new parsing.
- **Declared behaviour is reconciled.** The compatibility-matrix `tex-math` entry and `Docs/MarkdownSupport.md` are updated so the statement of support matches what the renderer actually accepts.

**Non-goals** (deliberately out of scope for this change):

- `\[...\]` appearing *mid-paragraph* rather than at the start of a line stays literal, as does mid-paragraph `$$...$$` (existing behaviour, unchanged).
- LaTeX preamble or document-level constructs — `\documentclass`, `\usepackage`, `\input`, `\newcommand` outside math — are not interpreted.
- Environments the engine does not implement are not emulated or rewritten; they are reported, not typeset.
- Export pipelines (Pandoc, DOCX, LaTeX) are not touched.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `math-rendering`: the "Inline math rendering" requirement gains `\(...\)` as a recognized delimiter; the "Block (display) math rendering" requirement gains bare `\begin{env}...\end{env}` recognition; the "Avoid false-positive math detection" and "Code content is never treated as math" requirements gain the boundaries these new forms introduce.

## Impact

- `Sources/MD2Core/MarkdownRenderer.swift` — one new inline pass in the `inlineHTML` pipeline (inserted before `protectBackslashEscapes`), and an environment branch in `mathBlockContent`. Because `mathBlockContent` is the single entry point already shared by the render walk, the paragraph-break check, the footnote scan, and the `\label` pre-scan, numbering and cross-reference resolution extend to the new syntax **for top-level blocks** without touching those call sites; the `\label` pre-scan does not traverse blockquotes or list content (pre-existing asymmetry), so the guarantee does not cover container content — documented as a boundary and deferred (TODOS).
- `Tests/MD2CoreTests/MathRenderingTests.swift` — new cases for the added delimiters and environments.
- `Tests/MD2CoreTests/DeclaredBoundaryTests.swift` — probes declaring the new boundaries (precedence, fallback, source-line metadata).
- `Tests/MD2CoreTests/Matrix/compatibility-matrix.json` — `tex-math` `declaredBehavior` and `boundary` text.
- `Docs/MarkdownSupport.md` — the math bullet in the user-facing support list.

Not affected: the preview render script (`__md2RenderMath` selects on `.math-inline` / `.math-display`, which the new forms reuse verbatim, so no JavaScript changes), the bundled KaTeX assets and version, package dependencies, and the HTML/PDF export paths, which consume the shared renderer output and therefore inherit the new syntax with no separate work.
