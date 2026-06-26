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
- Lists: ordered, unordered, and GFM task lists.
- Tables: GFM pipe tables with left, center, and right alignment.
- Code: fenced code blocks, indented code blocks, and inline code.
- Syntax highlighting: lightweight keyword/type/string/comment/number/function highlighting for Python, Java, Rust, C++, C, shell, Perl, Go, Swift, JavaScript, and TypeScript code fences.
- Inline styles: strong, emphasis, strong-emphasis, strikethrough.
- Links and images, including optional title text and Pandoc-style image size attributes (`![alt](path){width=480}` or `{width=320 height=180}`); invalid attributes are ignored and the image still renders.
- Autolinks such as `<https://example.com>`.
- Backslash escapes and HTML entities.
- Safe inline HTML tags; unsafe tags such as `<script>` are escaped.
- YAML front matter.
- `[TOC]` generated from headings.
- Math: inline TeX `$...$` and display TeX `$$...$$` (single- and multi-line), typeset offline with bundled KaTeX, including the mhchem extension for chemistry expressions such as `\ce{H2SO4}`. Backslash TeX commands inside math (`\,`, `\%`, `\{`, and even `\$`) reach KaTeX verbatim — Markdown backslash escapes do not apply within a math span, and an interior `\$` does not close it. Currency text (`$5`), escaped `\$` outside math, and `$` inside code are left literal. Note: KaTeX supports a subset of LaTeX, so commands outside that subset render as an inline error rather than typeset output.
- Diagrams: `mermaid`, `flow` (flowchart.js), and `sequence` (js-sequence-diagrams) fenced code blocks, rendered offline with bundled engine assets in the Read-mode preview. Invalid diagram source falls back to showing its raw text instead of blanking the preview. Other code-fence languages are unaffected.
- CJK text in headings, paragraphs, tables, and inline styles.
- Footnotes: `[^id]` references and `[^id]: definition` blocks, with superscript links, numbered in order of first reference, and a trailing footnotes section with back-reference arrows.
- Image attachments: pasting a screenshot saves it into a configurable, document-relative folder (default `assets/`); dragging or pasting image files links them in place at their existing location. Missing local images show an explicit broken-image placeholder in the preview.

## Not Yet Supported

- Semantic syntax analysis, compiler-aware highlighting, and language-server features.
- Typora's remote image upload/hosting and the drag-handle image resize UI. (Markdown2 instead saves pasted/dropped images into a configurable document-relative folder and sizes them with `{width=…}` attributes.)
- Import/export formats such as PDF, DOCX, LaTeX, Epub.
- Focus mode, typewriter mode, auto-pairing, and custom theme management.
- Full CommonMark conformance for every nested/container edge case.
