## Context

`MarkdownRenderer` recognizes math in two places:

- **Inline** — `protectInlineMath` (one pass in the `inlineHTML` pipeline) matches `$...$` only.
- **Block** — `mathBlockContent` matches a line starting with `$$` or `\[`, returning raw TeX plus the next index.

Block detection is the load-bearing seam. `mathBlockContent` is the *single* entry point shared by four call sites: the render walk, the paragraph-break check, the footnote scan, and the `\label` pre-scan that registers cross-references. Extending it therefore extends equation numbering, `\ref{}` resolution, and footnote-scan safety together, with no changes at those call sites. It also sits *after* the fenced-code check in the render walk, so code-block precedence is inherited rather than re-implemented.

The inline pipeline documents its own contract ("adding a new inline construct means inserting one entry at the right point in this list"). Pass order is load-bearing: `protectInlineMath` deliberately runs **before** `protectBackslashEscapes`. That ordering is why `$h = I \cdot C_\text{eff}$` survives — and it is exactly why `\(x^2\)` does not today: with no pass claiming `\(...\)`, the backslash-escape pass treats `\(` as an escaped paren, drops the backslash, and the reader sees `(x^2)`.

Two facts were **measured against the bundled engine (KaTeX 0.16.11)** rather than assumed, because the design depends on them:

| Probe | Result |
| --- | --- |
| `align`, `align*`, `alignat`, `gather`, `gather*`, `equation`, `equation*`, `aligned`, `split`, `cases`, `array`, matrices | typeset |
| `multline`, `eqnarray`, `displaymath`, `subequations` | `No such environment` error |
| `align` / `equation` **without** `\tag{}` | **no visible number** — the `class="tag"` markup is an empty layout slot, not a number |
| `\tag{3.1}` | renders the visible number `(3.1)` |
| `\label{eq:e}` | `Undefined control sequence: \label` |
| `\begin{align}` … nested `\begin{cases}` … `\end{cases}` … `\end{align}` | typesets; inner close does not end the outer |
| `\begin{matrix}` … nested `\begin{matrix}` … `\end{matrix}` … `\end{matrix}` | typesets — same-name nesting is **valid** KaTeX (outside-voice probe, 2026-09-24) |

Constraints: no new dependencies, no asset changes, and the preview's `__md2RenderMath` selects on the `.math-inline` / `.math-display` classes, so any new syntax must reuse them rather than introduce a parallel DOM contract.

## Goals / Non-Goals

**Goals:**

- Accept `\(...\)` as inline math with the same verbatim-TeX guarantee `$...$` already has.
- Accept a bare `\begin{<env>}...\end{<env>}` block as display math, with no `$$`/`\[` wrapper.
- Keep `\label` / `\tag` numbering and `\ref{}` resolution working identically across every delimiter form.
- Keep `$$...$$` and `\[...\]` behaviour bit-for-bit unchanged.
- Change no JavaScript, no CSS, no bundled asset, and no dependency.

**Non-Goals:**

- `\[...\]` or `$$...$$` appearing **mid-paragraph** (only line-leading forms are display math). Supporting them would require the inline pipeline to emit block-level elements, breaking its "inline pass produces inline output" invariant.
- LaTeX preamble or document-level constructs (`\documentclass`, `\usepackage`, `\input`, `\newcommand` outside math).
- Emulating or rewriting environments the engine does not implement.
- Per-row equation numbering inside `align` (LaTeX numbers each row; this change numbers the block once).
- Export-pipeline changes (Pandoc/DOCX/LaTeX); HTML and PDF inherit through the shared renderer.

## Decisions

### 1. A dedicated inline pass, not an extended `$` pattern

Add `protectInlineParenMath`, inserted immediately after `protectInlineMath`.

The `$` pattern carries guards that exist only for dollar signs — currency (`$5`), the `$$` display exclusion, and the open/close whitespace rules. `\(...\)` needs none of them (spaces inside `\( x \)` are legal) and needs a different escape rule. Folding both into one pattern would couple unrelated guard logic inside the most regression-sensitive regex in the renderer, which the spec pins with currency and escaped-dollar scenarios.

*Alternatives rejected:* a single combined pattern (couples the guards, risks the currency behaviour the spec protects); teaching `protectBackslashEscapes` about spans (the escape pass has no notion of spans and runs after math by design).

### 2. Pass placement is the whole fix

`(` and `)` are members of the backslash-escapable punctuation set, so the pass **must** run before `protectBackslashEscapes`. Reordering instead — or adding the syntax in a later pass — reintroduces the reported bug in a new form.

This also means the paren pattern must not open on an escaped backslash (`\\(`), mirroring the `(?<![$\\])` guard the `$` pattern uses. Covered by a test rather than left to chance.

### 3. Environment detection by name-matched suffix scan, with a same-name depth counter

Extend `mathBlockContent` with a third branch: when the trimmed line starts with `\begin{<env>}` for a recognized `<env>`, scan forward for a line whose trimmed content ends with the matching `\end{<env>}`, then reuse the existing single-line/multi-line split **shape** — with three exceptions that make the shape safe for environments:

- **The returned TeX retains both environment commands.** The `$$`/`\[` branches strip their delimiters because the engine must not see them; environments are the opposite — KaTeX needs `\begin{align}`/`\end{align}` to parse the block, and the stripped form (`a&=b` alone) parse-errors (probe-verified). The single-line form keeps `\begin{env}…\end{env}` intact; the multi-line form keeps the open and close lines.
- **Same-name depth counter.** The close is matched **by name**, so an inner `\end{cases}` can never terminate an `align` block — confirmed by probe. Same-name nesting, however, is *valid* KaTeX (`matrix` inside `matrix` — probe-verified), so the scan counts depth on `\begin{<same>}`/`\end{<same>}` and closes at depth zero. (An earlier draft claimed same-name nesting was invalid LaTeX; that was wrong.)
- **Fence bail.** If the scan hits a fenced-code opener before the closer, return `nil` so the text falls through literally. Real environments never contain fences; without the bail, a prose line starting with `\begin{align}` plus any later fenced sample containing `\end{align}` would swallow both into one broken math block.

The recognized set is a single enumerated constant: the display environments `align`, `align*`, `alignat`, `alignat*`, `gather`, `gather*`, `equation`, `equation*`; the probe-verified standalone inner environments `aligned`, `alignedat`, `split`, `cases`, `array`, and the matrix family (`matrix`, `pmatrix`, `bmatrix`, `Bmatrix`, `vmatrix`, `Vmatrix`, `smallmatrix`); plus the engine-rejected names from Decision 4. The delta spec's "standalone inner environments it accepts" sentence is made normative by this enumeration.

*Alternatives rejected:* a general `\begin{X}`/`\end{X}` pair rule (captures prose *about* LaTeX, e.g. docs discussing `\begin{align}`); a full environment-stack parser (the same-name counter is not a stack — it tracks one name); a display-only allowlist (would contradict the spec's inner-environment promise despite probe evidence).

### 4. Engine-rejected environments are recognized, not ignored

`multline`, `eqnarray`, `displaymath`, and `subequations` are added to the recognized set even though the engine rejects them.

Today those blocks render as mangled prose — `\begin{eqnarray} a &=& b \end{eqnarray}` loses its backslashes to the escape pass and reaches the reader as `begin{eqnarray} a &=& b end{eqnarray}`. That silent corruption is the reported defect. Routing them to the engine produces a visible error carrying the source, which is what the existing "graceful error handling" requirement already asks for.

*Alternative rejected:* leaving them to fall through as text — that is the bug, not a fallback.

### 5. Numbering is reused verbatim, because the engine does not compete

`mathDisplayBlockHTML` and `equationLabelTag` are reused with no new numbering logic. The probe settles the obvious hazard: KaTeX 0.16.11 does **not** auto-number `align` or `equation`, so there is no double-numbering to suppress and no need to rewrite `align` → `align*` or inject `\notag`. The engine renders a number only for an explicit `\tag{}`, which the existing code already treats as the manual-number path.

`\label` stripping is likewise mandatory rather than cosmetic — the engine raises `Undefined control sequence: \label`, and the existing helper already removes it before typesetting while registering it for `\ref{}`.

Scope limit (outside-voice finding): the "extends for free" claim covers **top-level blocks**. The label pre-scan does not traverse blockquotes or dedented list content, so a forward `\ref{}` targeting an equation inside a container may stay unresolved — a pre-existing `$$` asymmetry the env syntax inherits. This change documents the boundary in the matrix text and pins it with a test; fixing the pre-scan's traversal is deferred (TODOS).

### 6. Reuse the existing DOM contract

New forms emit the same `math math-inline` / `math math-display` classes and, when labeled, the same `numbered-equation` wrapper. `__md2RenderMath` and the numbering CSS are untouched.

## Risks / Trade-offs

- **[Prose mentioning LaTeX syntax is captured]** → Recognition requires a matching closer; unterminated or name-mismatched forms stay literal, and a closer that only appears inside a fenced code block never captures (fence bail, Decision 3). Spec'd with scenarios and tested.
- **[Escaped `\\(` opens a span]** → Leading-backslash guard in the pattern, mirroring the `$` pattern, with a dedicated test.
- **[Same-name nested environments close early]** → Handled: the depth counter (Decision 3) closes same-name blocks correctly; nested `matrix` typesets completely.
- **[`align` with a `\label` per row gets a single block number]** → The first `\label` wins, matching the existing one-label-per-block model. LaTeX's per-row numbering would need a different numbering model; declared as a boundary in the matrix text.
- **[Cross-delimiter nesting, e.g. `$x$` inside `\(…\)`]** → The `$` pass runs first and claims the inner span; its protection token restores as nested HTML, so the outer math's `textContent` drops the inner markup — `\text{$x$}` reaches the engine as `\text{x}`. Silent alteration of valid input, probe-verified by the outside voice; declared as a boundary and pinned by a test (task 3.1). The principled fix — one left-to-right delimiter-ownership scan — is deferred to TODOS; it would also clean up the pre-existing code-spans-inside-`$…$` sibling.
- **[Pre-existing spec drift, reconciled here]** → The main `math-rendering` spec never absorbed the backslash-verbatim guarantees from `fix-inline-math-backslash-escapes`, and documents neither the implemented `\[...\]` block form nor those escape rules. The MODIFIED requirement folds them in, since the new delimiter depends on the same ordering guarantee. Flagged so this reads as a deliberate reconciliation rather than silent scope creep.
- **[Silent-failure class]** → This is precisely the failure mode the project's guardrails target: nothing throws, the equation is just wrong. Both delimiter forms and the fallback paths get tests, and the change touches neither `PDFExporter.swift` nor `DocumentPrinter.swift`, so the GUI-gated export suites are not triggered by rule. They are still run as a precaution because the change alters what the preview typesets.

## Migration Plan

Render-only change with no data migration, no asset or dependency change, and no API change. Rollback is reverting `Sources/MD2Core/MarkdownRenderer.swift` together with the matrix entry and the docs bullet; the delta spec reverts with the change directory. Land behind the normal test gate: `swift test`, plus a manual export check of a document using the new syntax, plus the GUI export suites as a precaution.

## Open Questions

- Should `align` gain per-row numbering to match LaTeX? Deferred — it requires a numbering model that can address individual rows, which is a larger change than this one.
- Should the recognized-environment set be user-extensible, or should unknown `\begin{...}` names also be routed to the engine for a visible error? Deferred: the current allowlist keeps prose false-positives bounded.
- Should mid-paragraph `\[...\]` become display math? Deferred pending evidence that real documents need it; it requires an inline-to-block escape hatch in the pipeline.
