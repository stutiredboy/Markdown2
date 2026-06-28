## Why

Markdown2 already renders math, chemistry, diagrams, and footnotes, but cannot produce formal technical or academic documents: there is no way to cite sources, generate a bibliography, number equations/figures/tables, or cross-reference them. Cross-references and equation numbering were explicitly deferred during the math feature's original design. Adding citations and cross-references bridges the gap from "renders technical content" to "completes a formal technical/academic document."

## What Changes

- Add `[@key]` citation syntax with BibTeX bibliography loading and a rendered bibliography section
- Add lightweight in-preview citation rendering (author-year or numeric) without requiring a full CSL engine
- Add `\ref{label}` cross-reference syntax for figures, tables, and equations with auto-numbering (heading/section references deferred — section numbering is a Non-Goal)
- Add equation auto-numbering for display math (`$$...$$`) with `\label{}`/`\ref{}` support
- Add figure and table auto-numbering driven by a caption syntax
- Add KaTeX macro configuration (`\newcommand`/`\def` support) and configurable numbering strategy (chapter vs. sequential)
- Leverage existing Pandoc export path for formal citation processing (citeproc) in DOCX/EPUB/PDF exports

## Capabilities

### New Capabilities
- `citation-rendering`: `[@key]` citation syntax, BibTeX file parsing, in-preview citation rendering (author-year/numeric), bibliography section generation, integration with Pandoc/citeproc for formal export
- `cross-reference`: `\ref{label}` cross-reference syntax for figures/tables/equations, auto-numbering counters for figures/tables/equations, and `\label` registration plus `\ref` resolution (KaTeX macro configuration belongs to the modified `math-rendering` capability below)

### Modified Capabilities
- `math-rendering`: Add equation auto-numbering and `\label`/`\ref` support for display math; add configurable KaTeX macros (`\newcommand`/`\def`)

## Impact

- **MD2Core/MarkdownRenderer.swift**: New inline pipeline pass for citations (`[@key]`) and cross-references; new pre-scan for `\label` definitions and figure/table captions (mirrors the footnote pre-scan pattern); `render(_:)` gains a `config:` parameter (citation style, equation-numbering flag, pre-loaded bibliography, math macros); strip `\label{}` from display-math TeX before KaTeX (KaTeX 0.16 has no `\label`)
- **MD2Core**: New `CitationContext`, `CrossReferenceContext` types (paralleling `FootnoteContext`); new `BibTeXParser`; new minimal front-matter field reader (front-matter text → key/value scalars) — front matter is currently displayed, not parsed
- **MD2Core/MathAssets.swift**: KaTeX macro configuration injection
- **MD2App/DocumentStore.swift**: Resolves the bibliography path (front-matter `bibliography:` or auto-detected `references.bib`) against the document's `baseURL`, loads + parses the `.bib`, and builds the `RenderConfig` passed into `render(_:config:)` (file IO is app-layer; the renderer stays pure)
- **MD2App/SelfContainedHTMLBuilder.swift**: Inline bibliography in HTML export
- **MD2App/PandocConverter.swift**: Pass `--citeproc` and `.bib`/`.csl` flags for formal export
- **MD2App/AppSettings.swift**: Citation style and equation numbering preferences
- **Tests/MD2CoreTests/**: New `CitationRenderingTests.swift`, `CrossReferenceTests.swift`
