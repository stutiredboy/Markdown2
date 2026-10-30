# Markdown2 Markdown Support

Markdown2 aims for a compact Typora-like writing and reading flow. It does not claim full Typora parity; Typora includes product features and external renderers that are outside this first native implementation.

> **Compatibility contract.** The authoritative, machine-checked support matrix
> lives in [`CompatibilityMatrix.md`](CompatibilityMatrix.md): it classifies every
> CommonMark/GFM construct as **Supported**, **Best-effort**, or **Out-of-scope**,
> and is enforced by the conformance suite against a vendored CommonMark/GFM
> corpus (the dashboard tracks the upstream reference-match rate per construct).
> The list below is the human-friendly summary; where the two ever disagree, the
> matrix wins.

## Verified in Tests

- Headings: ATX (`#`) and Setext (`===`, `---`).
- Paragraphs and horizontal rules.
- Line breaks: every authored line break is preserved as a visible line break (`<br>`) — soft breaks (a newline between lines) and hard breaks (a line ending with two spaces or a backslash) both render on their own line, in paragraphs and inside blockquotes. A blank line still starts a new paragraph.
- Blockquotes, including Markdown rendered inside quote blocks.
- GitHub Alerts: `> [!NOTE]`, `TIP`, `IMPORTANT`, `WARNING`, and `CAUTION` on the first quoted line. Titles follow the app's English/Simplified Chinese language setting; light, dark, HTML, and PDF styles share the same renderer.
- Lists: ordered, unordered, and GFM task lists.
- Tables: GFM pipe tables with left, center, and right alignment.
- Code: fenced code blocks, indented code blocks, and inline code.
- Syntax highlighting: lightweight keyword/type/string/comment/number/function highlighting for Python, Java, Rust, C++, C, shell, Perl, Go, Swift, JavaScript, and TypeScript code fences.
- Inline styles: strong, emphasis, strong-emphasis, strikethrough.
- Optional inline styles: enable **Settings → Markdown Syntax** switches for `==highlight==`, `x^2^`, and `H~2~O`. Each defaults off and is saved independently. Subscript/superscript content may use escaped spaces (`X~long\ text~`); code, math, and link destinations remain protected.
- Links and images, including optional title text and Pandoc-style image size attributes (`![alt](path){width=480}` or `{width=320 height=180}`); invalid attributes are ignored and the image still renders. Image alt text and link titles are plain text: inline code, math, HTML, and autolinks inside them keep their source spelling, while backslash escapes and entities resolve.
- Reference links/images: `[text][id]`, `[id][]`, `[id]`, and `![alt][id]` resolve `[id]: URL "title"` definitions anywhere in the document, including supported quote/list containers. Labels use Unicode case folding and collapsed whitespace; the first definition wins. Definitions do not interrupt paragraphs and are ignored in code, math, and front matter. `[TOC]`, citations, footnotes, and alert markers retain their own syntax.
- Autolinks such as `<https://example.com>`, bare `https://example.com`, `www.example.com`, and email addresses. Bare URLs exclude trailing punctuation and unmatched closing parentheses. The enumerated CJK/typographic boundary set (including the full-width punctuation ranges) and the zero-width space (U+200B) end a bare URL and are valid left boundaries; Han characters and the same set can immediately precede one, and Han text inside a URL path is preserved. The full-width structural lookalikes `．／＃＠？－＿` are valid left boundaries but stay URL content, so `https://evil.com．trusted.com` does not link a shorter host. A continuation that would change the apparent authority stays literal after protected tokens/entities (including image alt text) are restored, inline HTML is stripped, emphasis/strikethrough delimiters are treated as markup, invisible characters (format/control/combining and default-ignorable scalars and blank fillers) are skipped, and fullwidth forms are folded: any `@` before the next delimiter or whitespace, an IDNA dot before a host label (ASCII, fullwidth, or a further-dot non-ASCII label), or a fullwidth percent before `2e`, or a continuation that begins with a host-label character. The guard applies when the authority (host with optional port) ends the URL, so ordinary prose like `https://example.com。然后` still links. Other Unicode punctuation and invisible format characters (for example U+FE10–U+FE6B, U+FEFF, U+00AD) are outside the set; a URL adjacent to one may remain literal. A Han word immediately after the hostname is absorbed into the hostname (`example.com然后`), a URL that itself contains one of these characters is truncated at it, and entity-encoded punctuation keeps the normal entity behavior. Chinese text is the common case. Code, math, and existing links are skipped.
- Backslash escapes and HTML entities.
- Safe inline HTML tags; unsafe tags such as `<script>` are escaped.
- YAML front matter.
- `[TOC]` generated from headings.
- Math: inline TeX `$...$` and `\(...\)`, and display TeX `$$...$$`, `\[...\]`, or a bare LaTeX environment (`\begin{align} ... \end{align}`, `\begin{equation} ... \end{equation}`, and the other display environments KaTeX supports) — single- and multi-line, typeset offline with bundled KaTeX, including the mhchem extension for chemistry expressions such as `\ce{H2SO4}`. Backslash TeX commands inside math (`\,`, `\%`, `\{`, and even `\$`) reach KaTeX verbatim — Markdown backslash escapes do not apply within a math span, and an interior `\$` does not close it. Currency text (`$5`), escaped `\$` outside math, `$` inside code, and `\(...\)` inside a link destination (where it means a literal parenthesis, so `[link](\(foo\))` keeps its `(foo)` destination) are left literal. An equation carrying `\label{...}` is numbered and can be referenced with `\ref{...}`, from before or after it and inside blockquotes, lists, or footnotes. A recognized environment is typeset in its starred form, which stops KaTeX from numbering the environment's own rows, so a display equation never carries two numbers and an explicit `\tag{...}` still renders. Note: KaTeX supports a subset of LaTeX, so commands and environments outside that subset — such as `eqnarray` or `multline` — render as a visible inline error rather than typeset output.
- Diagrams: `mermaid`, `flow` (flowchart.js), and `sequence` (js-sequence-diagrams) fenced code blocks, rendered offline with bundled engine assets in the Read-mode preview. Invalid diagram source falls back to showing its raw text instead of blanking the preview. Other code-fence languages are unaffected.
- CJK text in headings, paragraphs, tables, and inline styles.
- Footnotes: `[^id]` references and `[^id]: definition` blocks, with superscript links, numbered in order of first reference, and a trailing footnotes section with back-reference arrows.
- Image attachments: pasting a screenshot saves it into a configurable, document-relative folder (default `assets/`); dragging or pasting image files links them in place at their existing location. Missing local images show an explicit broken-image placeholder in the preview.

Common syntax smoke test: open [`Examples/CommonSyntax.md`](../Examples/CommonSyntax.md), toggle the three optional styles, switch the app language, and export to PDF. Automated coverage lives in `CommonSyntaxTests`, `CommonSyntaxSettingsTests`, and `CommonSyntaxGUITests` (the last requires `MD2_RUN_GUI_TESTS=1`). Parsing rules are based on [CommonMark reference links](https://spec.commonmark.org/0.31.2/#link-reference-definitions), [GFM extended autolinks](https://github.github.com/gfm/#autolinks-extension-), and [Typora's optional inline syntax](https://support.typora.io/Markdown-Reference/).

## Not Yet Supported

- Semantic syntax analysis, compiler-aware highlighting, and language-server features.
- Typora's remote image upload/hosting and the drag-handle image resize UI. (Markdown2 instead saves pasted/dropped images into a configurable document-relative folder and sizes them with `{width=…}` attributes.)
- Import/export formats such as PDF, DOCX, LaTeX, Epub.
- Focus mode, typewriter mode, auto-pairing, and custom theme management.
- Full CommonMark conformance for every nested/container edge case.
