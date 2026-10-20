# Markdown2 compatibility matrix

> Generated from `Tests/MD2CoreTests/Matrix/compatibility-matrix.json` (schema 1.0). This is the source-of-truth support contract for Markdown2's renderer; it is enforced by the conformance suite. **Do not edit by hand** — regenerate with `MD2_REGENERATE_DOCS=1 swift test --filter CrossArtifactConsistencyTests`.

Support tiers: **Supported** (intentionally interpreted, stable shape), **Best-effort** (useful but with known incomplete edges), **Out-of-scope** (not interpreted; authored text is preserved). Upstream reference match is tracked separately by the conformance dashboard and is not a 100% target.

## CommonMark

| Construct | Tier | Declared behaviour | Boundary |
| --- | --- | --- | --- |
| tabs | Best-effort | A leading tab indents like four spaces for code-block and list detection. | Tab-stop expansion inside content is approximate; some interior-tab cases diverge from the reference. |
| backslash-escapes | Supported | A backslash before an ASCII punctuation character emits that character literally rather than as Markdown syntax. | A backslash before a non-punctuation character is left literal; escapes do not apply inside code spans or math. |
| entity-references | Best-effort | Named and numeric HTML entities are preserved verbatim so the browser resolves them. | Entities are not decoded to their target character during rendering, so some reference outputs that substitute the character diverge. |
| precedence | Supported | Block structure is resolved before inline structure, matching CommonMark precedence. | n/a |
| thematic-breaks | Supported | A line of three or more `-`, `*`, or `_` (optionally spaced) becomes `<hr>`. | Some inline-vs-rule ambiguities (e.g. emphasis runs) diverge at the edges. |
| atx-headings | Supported | `#`–`######` followed by a space become `<h1>`–`<h6>` with an auto-generated slug `id`; trailing `#` are stripped. | More than six `#`, or no space after the `#` run, is not a heading and falls back to a paragraph. |
| setext-headings | Supported | A paragraph line underlined by `=` or `-` becomes `<h1>`/`<h2>`. | Multi-line setext content and some interaction with lists/indentation diverge at the edges. |
| indented-code-blocks | Supported | Lines indented four spaces (or a tab) become `<pre><code>` with the indentation stripped. | The trailing newline inside the code element is not always emitted, so output can diverge by a final `\n`. |
| fenced-code-blocks | Supported | ``` ``` ``` and `~~~` fences become `<pre><code>`; an info string becomes `class="language-…"` and drives syntax highlighting. | An unterminated fence renders to end of document; the trailing newline inside the code element can diverge from the reference. |
| html-blocks | Out-of-scope | Block-level raw HTML passthrough is not implemented; such input is treated as ordinary Markdown text and escaped where unsafe. | Authored angle-bracket text is preserved (escaped); no block-level HTML is emitted verbatim. |
| link-reference-definitions | Supported | Full, collapsed, and shortcut reference links and images resolve document-wide definitions; labels use Unicode case folding and collapsed whitespace, with the first definition winning. | Definitions in code, math, front matter, or paragraph continuations do not register. TOC, citation, footnote, and alert labels are reserved. Complex list-container and entity-name edges remain incomplete. |
| paragraphs | Supported | Runs of non-blank lines become `<p>`; a blank line separates paragraphs. | Soft line breaks within a paragraph render as `<br>` (intentional, editor-style), where the reference joins with a newline. |
| blank-lines | Supported | Blank lines separate blocks and are otherwise ignored. | n/a |
| block-quotes | Supported | `>`-prefixed lines become `<blockquote>` with their content re-rendered as Markdown. | Soft line breaks inside a quote render as `<br>` (intentional); lazy-continuation edge cases diverge. |
| list-items | Supported | `-`/`*`/`+` and `N.`/`N)` markers become `<li>`; indentation drives nesting. | Loose/tight detection, multi-paragraph items, and some indentation edges diverge from the reference. |
| lists | Supported | Consecutive items of one kind become a single `<ul>`/`<ol>`; `<ol>` honours the first start number. | List-tightness and marker-change splitting follow simplified rules that diverge at the edges. |
| inlines | Supported | Inline parsing runs in a fixed precedence: code spans, then escapes, math, entities, autolinks, raw HTML, then emphasis/links/images. | n/a |
| code-spans | Supported | Backtick runs become `<code>` with the content HTML-escaped; the longest matching run delimits the span. | Some backtick-balancing and surrounding-space-trim edges diverge from the reference. |
| emphasis | Supported | `*`/`_` produce `<em>`, doubled produce `<strong>`, triple produce nested strong-emphasis; `~~` produces `<del>`. | Complex flanking/nesting cases from the CommonMark emphasis algorithm are simplified and diverge at the edges. |
| links | Supported | Inline and reference links become `<a href>` with optional titles; unsafe schemes are neutralised. | Complex nested-bracket and inline destination/title edges remain incomplete. |
| images | Supported | Inline and reference images become `<img src alt title>`; inline images additionally support Pandoc size attributes. | Some nested alt-text and inline destination edges remain incomplete; reference images do not consume size attributes. |
| autolinks | Supported | `<scheme:...>` and `<email>` angle-bracket autolinks become `<a href>`. | Some scheme-validation and edge cases diverge. Bare URL/email cases intentionally follow the GFM extension rather than CommonMark (examples 608, 611, 612). |
| raw-html-inline | Best-effort | A safe subset of inline HTML tags passes through; unsafe tags (e.g. `<script>`) are HTML-escaped. | The allowed-tag set is narrower than CommonMark, so disallowed/unknown tags are escaped rather than passed through. |
| hard-line-breaks | Supported | A line ending in two spaces or a backslash becomes `<br>`. | Because soft breaks also render as `<br>`, hard and soft breaks converge on `<br>` (intentional editor behaviour). |
| soft-line-breaks | Supported | A soft line break renders as `<br>` so each authored line stays on its own line. | Intentional divergence from the reference, which renders a soft break as a newline/space. |
| textual-content | Supported | Plain text is emitted with HTML-significant characters escaped. | n/a |

## GFM extensions

| Construct | Tier | Declared behaviour | Boundary |
| --- | --- | --- | --- |
| gfm-tables | Supported | Pipe tables become `<table>` with `<thead>`/`<tbody>`; column alignment is emitted as `style="text-align:…"`. | Alignment uses CSS `style` rather than the GFM `align` attribute (intentional); a delimiter row without leading/trailing pipes is not recognised and falls back to a paragraph. |
| gfm-task-lists | Supported | `- [ ]`/`- [x]` items become `<li>` with a `<input type=checkbox>`; the list carries `class="task-list"`. | Checkboxes are left enabled (not `disabled`) and carry `data-md2-task-line` so a preview click can toggle them — intentional divergence from the reference. |
| gfm-strikethrough | Supported | `~~text~~` becomes `<del>text</del>`. | n/a |
| gfm-autolinks | Supported | Bare http(s), www. and email addresses become links. A bare URL ends at whitespace, `<`, or CJK/typographic punctuation (including full-width forms) and the zero-width space U+200B; trailing ASCII punctuation, excess closing parentheses and trailing entity spellings are excluded. Han text remains valid inside URL paths. | Code, math, images, and existing links are protected. Han characters and full-width/CJK and typographic punctuation are valid left boundaries, and U+200B is both a terminator and a left boundary - an intentional adjustment to GFM's ASCII boundary rule. Han text immediately after the authority is absorbed into the hostname (`example.com然后`), not the path; a URL that itself contains a boundary character is truncated, and entity-encoded punctuation keeps the existing entity-recovery behavior (`&#xff0c;` stays in the destination; `&#xff1a;` before a scheme stays literal). Email autolink boundaries are unchanged. Extended domain validation follows the GFM subset; unusual domain and inline-delimiter combinations may diverge. |
| gfm-disallowed-raw-html | Best-effort | Unsafe HTML tags are HTML-escaped, which is at least as strict as GFM's disallowed-raw-HTML filtering. | Markdown2 escapes a broader set than GFM filters, so output diverges while remaining safe. |

## Markdown2 extensions

| Construct | Tier | Declared behaviour | Boundary |
| --- | --- | --- | --- |
| front-matter | Supported | A leading `---` fenced YAML block is parsed as front matter. | Only a document-leading block is treated as front matter; malformed YAML degrades to visible text. |
| toc | Supported | `[TOC]` expands to a nested table of contents generated from the document headings. | With no headings, `[TOC]` produces an empty list rather than failing. |
| tex-math | Supported | Inline `$…$` / `\(…\)` and display `$$…$$` / `\[…\]` TeX, plus bare `\begin{env}…\end{env}` environments, are typeset offline with bundled KaTeX (incl. mhchem). | Commands outside KaTeX's subset render as an inline KaTeX error rather than blanking; currency `$` and `$` in code stay literal; a `\(…\)` inside a link destination stays a literal-parenthesis escape. A recognized environment is typeset in its starred form, which suppresses the engine's own CSS-counter row numbering so Markdown2 stays the only authority (an explicit `\tag{}` still renders); one label per environment block yields one number, and engine-rejected environments (`multline`, `eqnarray`, `displaymath`, `subequations`) are reported rather than typeset. Numbering and `\ref{}` pre-registration cover top-level blocks: an equation inside a blockquote or list is numbered, but a forward `\ref{}` to it stays unresolved. A closer scan bails at a fenced-code boundary, and `$…$` nested inside `\(…\)` loses its dollar signs to the earlier inline pass. |
| diagrams | Supported | `mermaid`, `flow`, and `sequence` fenced blocks render offline with bundled engines in the Read-mode preview. | Invalid diagram source falls back to showing its raw text instead of blanking the preview. |
| footnotes | Supported | `[^id]` references and `[^id]:` definitions become numbered superscript links plus a footnotes section with back-references. | An undefined reference renders as literal text; definitions are collected regardless of position. |
| image-size-attributes | Supported | Pandoc-style `{width=… height=…}` after an image sets its dimensions. | Invalid attributes are ignored and the image still renders. |
| image-attachments | Supported | Pasted/dropped images are saved into a configurable document-relative folder and linked in place. | A missing local image shows an explicit broken-image placeholder rather than a blank. |
| github-alerts | Supported | NOTE, TIP, IMPORTANT, WARNING and CAUTION quote markers become styled alerts with English or Simplified Chinese titles following the app language; preview and export share the markup. | The marker must occupy the first quoted line by itself; unknown markers remain ordinary quotes. Existing blockquote lazy-continuation limitations apply. |
| optional-inline-styles | Supported | Settings independently enable ==highlight==, ^superscript^ and ~subscript~; all default off and apply to preview, standalone HTML and PDF. | Code, math and link destinations remain literal. Subscript/superscript content cannot contain unescaped whitespace; escaped spaces are supported. Double tildes retain strikethrough. |

Corpus provenance: CommonMark 0.31.2 (CC-BY-SA 4.0); GFM 0.29 (tag 0.29.0.gfm.13) (CC-BY-SA 4.0).
