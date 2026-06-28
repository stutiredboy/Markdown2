## 0. Renderer configuration and front matter (foundation)

- [x] 0.1 Add a `Sendable` `RenderConfig` type to MD2Core: `bibliography: [String: BibEntry]`, `citationStyle`, `numberAllEquations`, `mathMacros: [String: String]`
- [x] 0.2 Change `MarkdownRenderer.render(_:)` to `render(_:config:)` with a default empty config; update existing call sites (`DocumentStore.swift:145`, `:607`) and tests — the default preserves current behavior
- [x] 0.3 Add a minimal front-matter field reader in MD2Core (front-matter text → `[String: String]`, single-line scalar values only); keep consumed keys visible in the rendered front-matter block
- [x] 0.4 In `DocumentStore`, build `RenderConfig`: read front matter, resolve the bibliography path (front-matter `bibliography:` or auto-detected `references.bib`) against `baseURL`, load + parse via `BibTeXParser`, read citation/equation settings from `AppSettings`, and pass into `render(_:config:)`

## 1. BibTeX Parser

- [x] 1.1 Create `BibTeXParser.swift` in MD2Core with `BibEntry` struct (key, type, fields dict)
- [x] 1.2 Implement entry detection: `@type{key, ...}` with brace/quote-delimited field values
- [x] 1.3 Implement field value parsing: `{...}`, `"..."`, bare numbers, `#` concatenation
- [x] 1.4 Implement author parsing: `Last, First` and `First Last` formats, `and` separator for multiple authors
- [x] 1.5 Support common entry types: article, book, inproceedings, techreport, misc, phdthesis, mastersthesis, incollection
- [x] 1.6 Handle malformed entries gracefully (skip without crashing)

## 2. Citation Context and Loading

- [x] 2.1 Create `CitationContext.swift` reference type with `entries`, `citedKeys`, `style` properties
- [x] 2.2 Create `CitationStyle` enum (`.authorYear`, `.numeric`)
- [x] 2.3 Populate `CitationContext.entries` from `RenderConfig.bibliography` (path resolution + file loading is task 0.4; this task covers only the in-renderer wiring)
- [x] 2.4 Wire `CitationContext` into `MarkdownRenderer.render(_:config:)` alongside `FootnoteContext`, seeded from `config`
- [x] 2.5 Implement `BibEntry` → citation text rendering: author-year format `(Author, Year)` and numeric format `[N]`
- [x] 2.6 Implement author name shortening: "Smith" for single author, "Smith & Jones" for two, "Smith et al." for 3+

## 3. Inline Citation Pass

- [x] 3.1 Add `applyCitations` pass to inline pipeline after `applyFootnoteReferences`
- [x] 3.2 Match `[@key]` parenthetical citation syntax and render via CitationContext
- [x] 3.3 Match `@key` in-text citation syntax (preceded by non-word boundary or start of line)
- [x] 3.4 Match `[-@key]` suppress-author syntax
- [x] 3.5 Match `[@key1; @key2]` multiple citation syntax
- [x] 3.6 Match `[@key, p. 42]` citation with locator syntax
- [x] 3.7 Register cited keys in `citedKeys` during substitution (first-citation order)
- [x] 3.8 Use `InlineProtector` to protect rendered citation HTML from escaping
- [x] 3.9 Handle unknown keys: render raw key as text, do not register in citedKeys

## 4. Bibliography Section Emission

- [x] 4.1 Implement `bibliographySectionHTML(context:)` in MarkdownRenderer
- [x] 4.2 Sort entries alphabetically by first author surname (author-year style)
- [x] 4.3 Sort entries by first-citation order (numeric style)
- [x] 4.4 Render each entry: author(s), year, title, and other available fields
- [x] 4.5 Emit `<section class="bibliography">` after footnotes section if present
- [x] 4.6 Skip section when no citations or no bibliography loaded

## 5. Cross-Reference Context

- [x] 5.1 Create `CrossReferenceContext.swift` reference type with `labels`, figure/table/equation counters
- [x] 5.2 Create `CrossRefTarget` struct (type: figure/table/equation/section, number: Int, id: String)
- [x] 5.3 Wire `CrossReferenceContext` into `MarkdownRenderer.render(_:)`
- [x] 5.4 Implement label registration: add label → target mapping during block walk

## 6. Equation Numbering and Labels

- [x] 6.1 Extract `\label{key}` from display math content during math block detection
- [x] 6.2 Assign sequential equation number when `\label` is present
- [x] 6.3 Add `id="eq:label"` attribute to display math wrapper div
- [x] 6.4 Render right-aligned equation number `(n)` in the math-display wrapper (flexbox CSS)
- [x] 6.5 Support `\tag{n}` manual numbering (override auto-number)
- [x] 6.6 Register equation labels in `CrossReferenceContext`
- [x] 6.7 Add "number all display equations" setting check (number even without `\label`)
- [x] 6.8 Strip `\label{...}` from the display-math TeX before KaTeX typesetting (KaTeX 0.16 has no `\label` and would render it as an error node); pass `\tag{...}` through to KaTeX and also read it at the Swift level to override the auto-number

## 7. Figure Auto-Numbering

- [x] 7.1 Extend image attribute parsing to detect `{#fig:label}` alongside existing `{width=...}`
- [x] 7.2 Assign sequential figure number when `{#fig:label}` is present
- [x] 7.3 Render caption "Figure N: caption" below the image
- [x] 7.4 Register figure labels in `CrossReferenceContext`
- [x] 7.5 Handle figures without labels: no numbering, no caption prefix

## 8. Table Auto-Numbering

- [x] 8.1 Detect table caption line `: caption {#tbl:label}` immediately following a pipe table
- [x] 8.2 Assign sequential table number when `{#tbl:label}` is present
- [x] 8.3 Render caption "Table N: caption" below the table
- [x] 8.4 Register table labels in `CrossReferenceContext`
- [x] 8.5 Consume the caption line from body flow (do not render as paragraph)

## 9. Cross-Reference Inline Pass

- [x] 9.1 Add `applyCrossReferences` pass to inline pipeline after `applyCitations`
- [x] 9.2 Match `\ref{label}` in unprotected text
- [x] 9.3 Resolve label via `CrossReferenceContext` to target number
- [x] 9.4 Render resolved number as protected HTML span
- [x] 9.5 Handle undefined labels: leave `\ref{label}` as literal text
- [x] 9.6 Ensure `\ref{}` inside inline math and code is not matched (protected earlier in pipeline)

## 10. KaTeX Macro Configuration

- [x] 10.1 Enable `globalGroup: true` in KaTeX render configuration in `window.__md2RenderMath`
- [x] 10.2 Add `macros: {}` option to KaTeX render calls for global macro storage
- [x] 10.3 Read the optional `math-macros:` front-matter field via the field reader (task 0.3) and carry it as `RenderConfig.mathMacros` (task 0.1)
- [x] 10.4 Serialize `RenderConfig.mathMacros` into the KaTeX `macros` option in the `__md2RenderMath` bootstrap at initialization
- [x] 10.5 Update `__md2ApplyContent` live-update path to re-inject macro configuration

## 11. CSS Styling

- [x] 11.1 Add `.bibliography` section styles (top border, smaller font, spacing)
- [x] 11.2 Add `.math-display` flexbox layout for equation numbering (equation centered, number right-aligned)
- [x] 11.3 Add figure caption styles (`.fig-caption` or equivalent)
- [x] 11.4 Add table caption styles (`.tbl-caption` or equivalent)
- [x] 11.5 Add `.cross-ref` link styling (inherit link color)
- [x] 11.6 Ensure all new styles use `currentColor`/CSS variables for light/dark mode

## 12. Export Integration

- [x] 12.1 Pass `--citeproc` and `--bibliography=<file.bib>` to PandocConverter when a `.bib` file is associated
- [x] 12.2 Pass `--csl=<style.csl>` to PandocConverter if a CSL file is specified
- [x] 12.3 Verify SelfContainedHTMLBuilder includes pre-rendered bibliography section (no changes needed if in body)
- [x] 12.4 Verify PDFExporter includes equation numbers and captions in paginated output
- [x] 12.5 Document that cross-reference numbering is scoped to preview/self-contained-HTML/PDF; vanilla Pandoc (DOCX/EPUB) does not resolve `\ref{}` or auto-number figures/tables without `pandoc-crossref` (out of scope)

## 13. Settings and Preferences

- [x] 13.1 Add `citationStyle` setting to AppSettings (author-year vs numeric)
- [x] 13.2 Add `numberAllEquations` setting to AppSettings (bool, default false)
- [x] 13.3 Add citation/equation settings to the settings UI
- [x] 13.4 Wire settings to MarkdownRenderer configuration

## 14. Tests

- [x] 14.1 Create `BibTeXParserTests.swift`: entry parsing, field types, author formats, malformed entries
- [x] 14.2 Create `CitationRenderingTests.swift`: all citation syntax variants, styles, edge cases, code precedence, and false-positive guards (email local part, `@` followed by space, unknown bare `@key`)
- [x] 14.3 Create `CrossReferenceTests.swift`: equation/figure/table refs, undefined labels, code/math precedence
- [x] 14.4 Add equation numbering tests to `MathRenderingTests.swift`: labeled/unlabeled numbering, tag, number-all setting
- [x] 14.5 Add KaTeX macro tests to `MathRenderingTests.swift`: newcommand global scope, front matter macros
- [x] 14.6 Add bibliography section tests: ordering by style, no-section cases, missing bibliography fallback
- [x] 14.7 Add table caption detection tests: caption after table, no caption, non-table followed by caption-like line
- [x] 14.8 Add figure numbering tests: sequential numbering, unlabeled figures, cross-ref resolution
- [x] 14.9 Add `MetadataInvariantTests.swift` entry: verify `data-md2-source-line` attributes on bibliography section and figure/table caption blocks

## 15. Sample Document

- [x] 15.1 Add citation examples to `Examples/Sample.md`: `[@key]` parenthetical, `@key` in-text, `[-@key]` suppress-author, `[@key1; @key2]` multiple, `[@key, p. 42]` with locator
- [x] 15.2 Add a bibliography section example with front matter `bibliography:` field and a sample `references.bib` in `Examples/`
- [x] 15.3 Add cross-reference examples: `\ref{eq:...}` for equations, `\ref{fig:...}` for figures, `\ref{tbl:...}` for tables
- [x] 15.4 Add labeled equation examples with `\label{eq:...}` and `\tag{n}` to the Math section
- [x] 15.5 Add figure auto-numbering example: `![caption](src){#fig:label}` to the Links & Images section
- [x] 15.6 Add table caption example: `: caption {#tbl:label}` after a pipe table in the Tables section
- [x] 15.7 Add KaTeX macro example: `\newcommand` in one equation used in another, and `math-macros:` front matter
