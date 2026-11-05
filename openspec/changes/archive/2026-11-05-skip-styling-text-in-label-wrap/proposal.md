## Why

`wrapLongLabels` is meant to change node labels only, but its `id(label)` pattern matches any long `word(...)` in the source. A long `url(...)` in styling or config text gets `<br/>` inserted, which the `diagram-rendering` spec forbids. It came up while testing Mermaid's security in #35: the broken `url(...)` values made the first network results misleading (`Docs/Mermaid-Label-Findings-2026-11-04.md`, item 4). This is a correctness bug, not a security one.

Confirmed on `main` with the bundled Mermaid 10.9.8:

| Source | Before | After |
| --- | --- | --- |
| `url(...)` in a `%%{init}%%` directive or front matter (`themeCSS`, `fontFamily`) | Renders, value silently lost | Value reaches the SVG |
| `url(...)` in `style` (`block-beta`, class diagram) or `classDef` (`block-beta`, state diagram) | Value broken | Value reaches the SVG |
| A link with parentheses in `click` | Link broken | Link intact |
| `url(...)` in a flowchart `style`, `classDef` or `linkStyle` | Parse error, fallback text holds `<br/>` | **Still a parse error**, fallback text is as written |

The last row matters: Mermaid's flowchart grammar rejects `url()` in those statements at any length, even `url(short)`, wrapped or not. This change does not make those diagrams render. A label containing one of the `FORBIDDEN` characters, such as `_`, escaped all of this by accident.

## What Changes

- **The wrap skips text that cannot hold a node label.** Front matter, `%%{...}%%` directives, `%%` comments, and `style`, `linkStyle`, `classDef`, `class` and `click` statements pass through unchanged. Only the text between them is wrapped.
- **Multi-line directives are covered.** A check of each line's start would see only a directive's first line, and the value is usually on a later one.
- **A statement after a `;` is covered,** as in `graph TD; A[x]; click A href "...";`.
- **Tests:** `MermaidOffscreenRenderingTests` renders each form Mermaid accepts and checks the value reaches the SVG, compares the wrap's output with its input for the rest, and checks that labels beside this text still wrap.

**Non-goals:**

- Flowchart `style`, `classDef` and `linkStyle` values with `url()` stay parse errors, see `design.md`.
- Other text the wrap reaches is unchanged, see "What this does not cover" in `design.md`.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `diagram-rendering`: the wrap leaves styling statements, `%%` comments and directives, and front matter exactly as written.

## Impact

- `Sources/MD2Core/MarkdownRenderer.swift`: `wrapLongLabels` in the diagram bootstrap.
- `Tests/MD2CoreTests/MermaidOffscreenRenderingTests.swift`: the new cases.
- No change to how long plain node labels wrap, to the export path, or to the Mermaid bundle.
