## Context

Markdown2 is a native macOS Markdown editor (Swift 6, SwiftUI/AppKit, WKWebView preview) with a hand-rolled Markdown→HTML renderer in `MarkdownRenderer.swift`. It already renders math (KaTeX, offline), chemistry (mhchem), diagrams (Mermaid/flow/sequence), and footnotes — all fully offline.

The footnote subsystem established the pattern for document-wide stateful constructs: a `FootnoteContext` reference type is populated by a pre-scan pass, mutated during inline rendering for numbering, and consumed by a trailing section emitter. The inline pipeline is an ordered pass list using a protect/restore (`InlineProtector`) mechanism explicitly designed for extension.

Cross-references and equation numbering were deferred in the original math design (`openspec/changes/archive/2026-06-05-add-math-support/design.md`, Non-Goals). This change picks up those deferred items plus adds citations and bibliography — the remaining pieces needed for formal technical/academic documents.

Pandoc export (DOCX/EPUB) is already wired via `PandocConverter`; Pandoc natively handles BibTeX/CSL citations, so formal citation processing can leverage that path.

## Goals / Non-Goals

**Goals:**
- `[@key]` citation syntax with BibTeX bibliography file loading and a rendered bibliography section in preview.
- Lightweight in-preview citation rendering (author-year or numeric) without requiring a full CSL engine.
- Cross-reference syntax (`\ref{label}`) resolving to figure/table/equation/section numbers.
- Auto-numbering for display equations, figures, and tables with `\label` support.
- KaTeX macro configuration (`\newcommand`/`\def`) for reusable math macros.
- Pandoc/citeproc integration for formal citation processing in DOCX/EPUB/PDF export.

**Non-Goals:**
- Full CSL style engine in the preview — preview uses simplified author-year/numeric formatting; formal CSL output is delegated to Pandoc on export.
- Bibliography management UI (searching, editing BibTeX entries in-app) — the `.bib` file is authored externally.
- Live WYSIWYG citation rendering in Write mode — citations render in Read mode preview only.
- Chapter-based numbering with custom section depth — flat sequential numbering for equations/figures/tables; section numbering deferred.
- Heading/section cross-references — because section numbering is deferred, `\ref{}` targets are limited to figures, tables, and equations this change; a `\ref{}` to a heading slug falls through to literal text.
- Formal cross-reference resolution in Pandoc exports (DOCX/EPUB) via `pandoc-crossref` — cross-reference numbering is scoped to the preview-derived paths (preview, self-contained HTML, PDF). Citations still use Pandoc `--citeproc`.
- Full YAML front-matter parsing — only single-line scalar keys (`bibliography:`, `math-macros:`) are read; nested/multi-line YAML is out of scope.
- Zotero/Mendeley integration or online bibliography APIs.

## Decisions

### Decision 1: Citation context mirrors the footnote pattern

Introduce a `CitationContext` reference type (paralleling `FootnoteContext`) that holds:
- `entries: [String: BibEntry]` — key → parsed BibTeX entry, populated by the bibliography pre-scan.
- `citedKeys: [String]` — keys in first-citation order, for numeric style numbering and bibliography ordering.
- `style: CitationStyle` — `.authorYear` or `.numeric`.

**Phases** (same three-phase pattern as footnotes):
1. **Bibliography pre-scan**: Detect `bibliography:` in YAML front matter (or auto-detect `references.bib` in the document directory). Parse the `.bib` file into `BibEntry` structs (title, author list, year, journal, etc.). A lightweight BibTeX parser in pure Swift — no external dependency.
2. **Inline citation substitution**: A new pass in the inline pipeline (after `applyFootnoteReferences`) matches `[@key]`, `[@key1; @key2]`, `@key`, and `[-@key]` (suppress author). Each match is replaced with rendered citation HTML (e.g. `(Smith, 2023)` or `[1]`) via the protect/restore mechanism. Cited keys are registered in `citedKeys`.
3. **Bibliography section emission**: After the footnotes section (if any), if `citedKeys` is non-empty, emit `<section class="bibliography">` with entries sorted alphabetically (author-year) or by citation order (numeric).

**Why not a single-pass regex**: Citations need document-wide state (which keys are cited, numbering order, bibliography collection). This is the same problem footnotes solved with the context pattern.

**Alternative considered**: Use KaTeX or a JS-based citeproc in the browser. Rejected — adds a large runtime dependency, breaks offline simplicity, and the preview doesn't need full CSL fidelity.

### Decision 2: Pandoc-compatible citation syntax

Adopt Pandoc's `[@key]` syntax:
- `[@key]` → full parenthetical: `(Smith, 2023)` or `[1]`
- `@key` (no brackets, preceded by non-word boundary) → in-text: `Smith (2023)` or `1`
- `[-@key]` → suppress author: `(2023)` or `[1]`
- `[@key1; @key2]` → multiple: `(Smith, 2023; Jones, 2024)` or `[1, 2]`
- `[@key, p. 42]` → with locator: `(Smith, 2023, p. 42)`

**Why**: Pandoc compatibility means documents authored in Markdown2 export cleanly through `PandocConverter` with `--citeproc` for formal CSL-formatted output (DOCX/EPUB/PDF). The preview renders a simplified form; the export uses the full CSL pipeline.

### Decision 3: Cross-reference context with label pre-scan

Introduce a `CrossReferenceContext` reference type that holds:
- `labels: [String: CrossRefTarget]` — label → (type, number), where type is `.figure`, `.table`, or `.equation`. (`.section` is intentionally out of scope — see the Sections bullet and Non-Goals.)
- Counters: `figureCounter`, `tableCounter`, `equationCounter` — incremented during the block walk.

**Label sources** (pre-scan):
- **Equations**: `\label{eq:label}` inside `$$...$$` blocks. Detected during the math block pass. The equation gets `id="eq:label"` and a right-aligned number `(n)`.
- **Figures**: Pandoc-style image attributes `![caption](src){#fig:label}`. The existing image rendering already parses `{width=…}`; extend it to also parse `#fig:label`. Number assigned during inline rendering.
- **Tables**: Pandoc-style table caption `: caption {#tbl:label}` on the line after a pipe table. Detected during the table block pass.
- **Sections**: **Deferred in this change.** Section numbering is a Non-Goal, so `\ref{}` targets are limited to figures, tables, and equations. A `\ref{heading-slug}` therefore finds no registered label and falls through to literal text (the same graceful fallback as any undefined reference). Heading/section cross-references can be added later once section numbering exists; `Slugger` heading IDs are already available to build on.

**Reference resolution**: `\ref{label}` in inline text is matched by a new inline pass (after citations, before `escapeHTML`). It resolves to the target's number: `1`, `3`, etc. If the label is not found, `\ref{label}` remains literal text (graceful fallback, matching the footnote pattern for undefined references).

**Why `\ref{}` over `[^ref:...]`**: LaTeX's `\ref{}` is the universal standard in academic writing. Using it keeps documents portable to LaTeX/Pandoc. The target audience (academic/technical writers) already knows this syntax.

### Decision 4: Equation numbering strategy

Display math `$$...$$` gets numbering when it contains `\label{}`:
- A `$$...$$` block with `\label{eq:foo}` gets `id="eq:foo"` and a right-aligned `(n)` number.
- A `$$...$$` block without `\label{}` is unnumbered by default.
- A configurable setting ("number all display equations") can number every display equation regardless of `\label` presence.
- `\tag{n}` sets a manual number (TeX convention). The bundled KaTeX 0.16.11 supports `\tag` natively (verified present in `katex.min.js`), so it is passed through to KaTeX for typesetting; the renderer also reads the tag value at the Swift level so it can override the auto-number that `CrossReferenceContext` would otherwise assign.
- **KaTeX does not implement `\label` (nor `\ref`/`\eqref`).** Verified: these commands are absent from the bundled `katex.min.js` (0.16.11). Because the math bootstrap calls `katex.render(tex, el, { throwOnError: false })` (`MarkdownRenderer.swift:1521`), a `\label{}` left in the TeX is rendered as a visible error node, not silently consumed. Therefore the renderer **strips** `\label{eq:foo}` from the display-math TeX *before* handing it to KaTeX, and records `eq:foo → number` in `CrossReferenceContext`. `globalGroup` (Decision 5) governs macro persistence only and has no bearing on labels.

**Rendering**: The display math wrapper `<div class="math-display">` gets `id="eq:foo"` and a flexbox layout: equation centered, number right-aligned. CSS-only; no JS needed for the number.

**Alternative considered**: Number every equation unconditionally. Rejected — clutters documents with many unreferenceable equations. Default to numbering only labeled equations, with an opt-in for all.

### Decision 5: KaTeX macro configuration

Enable KaTeX's `globalGroup: true` and `macros: {}` options so that `\newcommand` and `\def` declared in any math block are available globally across all subsequent math in the document. This is a one-line configuration change in the `window.__md2RenderMath` bootstrap.

Additionally, support an optional `math-macros:` field in YAML front matter for predefined macros that apply to all math in the document. Because the bootstrap JS is generated as a Swift string, these macros must reach the renderer as data: they are read via the front-matter field reader (Decision 10), delivered through `RenderConfig.mathMacros` (Decision 9), and serialized into the `macros` object of the `window.__md2RenderMath` bootstrap at initialization.

**Why `globalGroup`**: KaTeX by default scopes macros per-render call. `globalGroup: true` makes them persist across calls, which is necessary when macros are defined in one `$$...$$` block and used in another. This is the documented KaTeX approach for document-wide macros.

**Alternative considered**: Pre-process all math to extract `\newcommand` and inject them into every KaTeX call. Rejected — fragile and duplicates KaTeX's own macro handling.

### Decision 6: BibTeX parser in pure Swift

A lightweight `BibTeXParser` in `MD2Core` that handles the common BibTeX subset:
- `@type{key, field = {value}, field = "value", field = value}`
- Entry types: `article`, `book`, `inproceedings`, `techreport`, `misc`, `phdthesis`, `mastersthesis`, `incollection`
- Fields: `title`, `author`, `year`, `journal`, `booktitle`, `publisher`, `pages`, `volume`, `number`, `url`, `doi`
- Author parsing: `Last, First` and `First Last` formats; `and` separator for multiple authors
- Brace balancing for `{...}` values; `"` quoted values; concatenated values with `#`

**Why not a library**: The project has zero external Swift dependencies. The BibTeX subset needed for preview rendering (author, year, title) is small enough for a focused parser. Full BibTeX edge cases (cross-references, string macros, `@string` definitions) are non-goals — Pandoc handles those on export.

### Decision 7: Inline pipeline insertion points

The current inline pipeline pass list:
```
protectCodeSpans → protectInlineMath → protectBackslashEscapes →
protectHTMLEntities → protectAutolinks → protectRawHTML →
applyFootnoteReferences → escapeHTML → renderEmphasis → renderImages → renderLinks
```

New passes inserted:
```
protectCodeSpans → protectInlineMath → protectBackslashEscapes →
protectHTMLEntities → protectAutolinks → protectRawHTML →
applyFootnoteReferences → applyCitations → applyCrossReferences →
escapeHTML → renderEmphasis → renderImages → renderLinks
```

- `applyCitations`: Matches `[@key]`, `@key`, `[-@key]` on unprotected text. Produces HTML spans that are protected via the `InlineProtector` mechanism (same as footnotes). Must run after `protectInlineMath` so `\$` in math isn't affected, and after `applyFootnoteReferences` so `[^id]` isn't confused with `[@id]`.
- `applyCrossReferences`: Matches `\ref{label}` on unprotected text. Produces protected HTML spans. Must run after `applyCitations` (so `@` in citation keys don't interfere) and before `escapeHTML` (so the produced HTML survives escaping).
- Figure/table label assignment happens in `renderImages` (for `{#fig:...}` attributes) and in the table block detector (for `: caption {#tbl:...}`), not in the inline pipeline.

### Decision 8: Export integration

For `PandocConverter` (DOCX/EPUB):
- Pass `--citeproc` flag when a `.bib` file is associated.
- Pass `--bibliography=<file.bib>` and optionally `--csl=<style.csl>`.
- Pandoc processes `[@key]` natively; no source transformation needed.

For `SelfContainedHTMLBuilder` (HTML export):
- The bibliography section is already in the rendered HTML body (emitted by the renderer).
- Citations are already rendered as text (author-year or numeric).
- No additional processing needed — the HTML export is self-contained.

For `PDFExporter`:
- Uses the WKWebView render (which already has the bibliography section).
- No additional processing needed.

### Decision 9: Renderer configuration and the MD2Core/MD2App boundary

`MarkdownRenderer.render(_ markdown: String) -> RenderedDocument` is today a **pure, `Sendable`, configuration-free** function (`MarkdownRenderer.swift:8`): it takes only the Markdown string and has no access to the document's file URL, directory, or `AppSettings`. Three new inputs must reach it — the parsed bibliography (`[String: BibEntry]`), the citation style and the "number all equations" flag, and the front-matter math macros — and **none can be discovered inside the renderer**:

- **File IO is app-layer.** Auto-detecting `references.bib` or resolving a `bibliography:` path needs the document directory, which exists only in `MD2App` as `DocumentStore.baseURL` (`fileURL?.deletingLastPathComponent()`, `DocumentStore.swift:113`). The pure renderer cannot read files. So the "bibliography pre-scan" of Decision 1 is **not** a renderer-internal pass like the footnote pre-scan — footnotes are entirely in-document and do no file IO, whereas the bibliography pre-scan crosses the filesystem boundary. The `.bib` loading happens in `DocumentStore`; only the already-parsed entries enter the renderer.
- **Settings are app-layer.** `citationStyle` / `numberAllEquations` live in `AppSettings`.

**Decision:** extend the entry point to `render(_ markdown: String, config: RenderConfig = .init()) -> RenderedDocument`, where `RenderConfig` is a `Sendable` value carrying `bibliography: [String: BibEntry]`, `citationStyle`, `numberAllEquations`, and `mathMacros: [String: String]`. The default empty config keeps the renderer pure for the many call sites and tests that need no academic features (preserving the current behavior of `DocumentStore.swift:145` and `:607`). `DocumentStore` builds the `RenderConfig`: it reads front matter (Decision 10), resolves + loads + parses the `.bib` against `baseURL`, reads `AppSettings`, and passes the config to `render`. `BibTeXParser` (Decision 6) stays a pure `MD2Core` value (string → entries) so it is unit-testable without the app.

**Alternative considered:** inject a file-reading closure into the renderer so it can run the pre-scan itself. Rejected — it breaks the renderer's purity/`Sendable` simplicity and spreads filesystem concerns into `MD2Core`.

### Decision 10: Front matter is displayed today, not parsed

`frontMatterBlock` (`MarkdownRenderer.swift:173`) collects the lines between `---` fences and emits them verbatim as `<pre class="front-matter"><code>…</code></pre>`; it does **not** parse key/value pairs, and no YAML/front-matter field parsing exists anywhere in `MD2App` either. The `bibliography:` and `math-macros:` features therefore require a **new minimal front-matter field reader**: a pure `MD2Core` helper mapping front-matter text → `[String: String]`, single-line scalar values only. Full YAML (nested maps, multi-line/block scalars, anchors) is a Non-Goal; complex front matter still renders as today.

Two behaviors are pinned:
- **Visibility:** consumed metadata keys (`bibliography:`, `math-macros:`) **remain** part of the displayed front-matter block — no hidden metadata side-channel, least surprise, minimal change. (Revisit if a dedicated metadata UI lands later.)
- **Robustness:** a document with no front matter, or front matter without these keys, behaves exactly as it does today.

## Risks / Trade-offs

- **[BibTeX parser completeness]** → The parser handles the common subset but not every BibTeX feature. Mitigation: document supported entry types and fields; unsupported entries fall back to showing the key. Pandoc handles full BibTeX on export.
- **[\ref{} ambiguity with inline math]** → `\ref` could appear inside `$...$` math. Mitigation: `protectInlineMath` runs first in the pipeline, so `\ref{}` inside math is protected and never matched by `applyCrossReferences`.
- **[Citation key collision with footnote labels]** → `[@key]` vs `[^id]` are syntactically distinct (`@` vs `^`). No collision.
- **[Bibliography file not found]** → If the `.bib` file doesn't exist or can't be parsed, citations fall back to showing the raw key as text. No crash; graceful degradation.
- **[KaTeX globalGroup state leakage]** → Macros defined in one document could leak to another if the WKWebView isn't fully reset. Mitigation: the `__md2ApplyContent` live-update path re-initializes KaTeX configuration on each render; full page reload (on document switch) starts fresh.
- **[Equation numbering in live-update mode]** → The `__md2ApplyContent` path replaces `<main>` content; equation numbers are in the HTML (not JS-computed), so they update correctly with content replacement.
- **[Table caption detection ambiguity]** → `: caption {#tbl:label}` could be confused with a definition list or a table separator. Mitigation: require the line to immediately follow a pipe table block and match the `^:\s+.+{#tbl:...}` pattern.
- **[KaTeX has no `\label`/`\ref`/`\eqref`]** → Confirmed absent from the bundled KaTeX 0.16.11; with `throwOnError: false` an un-stripped `\label{}` typesets as a visible error node. Mitigation: the renderer strips `\label{}` from display-math TeX before KaTeX and resolves cross-references entirely at the Swift level (Decision 4); `\tag` is genuinely native and is passed through.
- **[Pandoc cross-reference syntax mismatch]** → The preview uses LaTeX `\ref{}` plus Pandoc-style `{#fig:…}` / `: caption {#tbl:…}`. Vanilla Pandoc does **not** resolve `\ref{}` or auto-number these without the external `pandoc-crossref` filter, and Pandoc applies its own figure/table numbering. So cross-reference *numbering* is a **preview / self-contained-HTML / PDF** feature (those paths reuse the Markdown2-rendered HTML), whereas DOCX/EPUB via Pandoc may number differently or leave `\ref{}` literal. Mitigation: scope cross-reference numbering to the preview-derived export paths for this change and document that formal Pandoc cross-referencing (pandoc-crossref) is a separate, later concern. Citations (`[@key]`) are unaffected — they round-trip through `--citeproc`.
- **[Front-matter field reader scope]** → Only single-line scalar keys are read (Decision 10); nested or multi-line YAML is ignored. Mitigation: documented as a Non-Goal; unsupported front matter still renders as a block and does not break the document.
