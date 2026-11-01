## Why

Markdown's block markers are ASCII, and CommonMark reads them by code point. The block parser read them as `Character`s (grapheme clusters). A joining scalar right after a marker (a combining mark, ZWJ, a variation selector or a spacing mark) fuses with the marker's last character, so `hasPrefix`, `first ==` and `prefix { }` stopped seeing the marker:
- `# ` + U+0301 + `word` rendered as a paragraph instead of a heading.
- `- ` + U+0301 rendered as a paragraph instead of a list item.
- `- [ ] ` + U+0301 rendered as a list item without a checkbox.
- `>` + U+0301, a fence with U+0301 in its info string, indented code, nested items and list continuations failed the same way.

Link-reference definitions and reference links had the same flaw: their parser and bracket pairing also stepped by `Character`.

This closes the `TODOS.md` item "Block markers and link brackets are read as graphemes", found while fixing the source-line stamp (2026-11-01). One correction to that item: its inline-link example (`[` + U+0600 + `[x](/y)]`) is not a grapheme bug. `[a[x](/y)]` misparses the same way, because the inline-link pass does not handle nested links, a known-incomplete area of the conformance baseline. The reference-link pass is where link brackets were read as graphemes, and this change fixes it.

## What Changes

- **Two scalar helpers** on `String`: `hasScalarPrefix(_:)` and `droppingScalars(_:)`.
- **Scalar comparisons** in the block parser for:
  - ATX headings (`MarkdownLine.heading`, shared with the outline)
  - code fences, including the info string and the closing fence
  - indented code
  - blockquote detection and stripping (now `MarkdownLine.isBlockquote` and `MarkdownLine.blockquoteContent`, replacing two copies)
  - bullet and task markers, and list content indentation
  - display-math openers
  - continuation-indent detection and stripping
- **`MarkdownIndentation.width`** counts leading spaces and tabs by scalar. The editor's list commands share it.
- **`LinkReference`'s cursor** steps by scalar.
- **`renderReferenceLinks`** pairs and walks brackets by scalar.
- **Declare the behavior** in a new `markdown-block-markers` capability.
- **Add `BlockMarkerScalarTests`**, and remove the TODO.

**Non-goals:**

- Nested inline links (`[a[x](/y)]`), a separate, pre-existing conformance gap.
- Ordered-list digits: the marker regex's `\d` also matches non-ASCII digits, which is pre-existing and unrelated to joiners.
- Constructs the scoping run found unaffected: setext underlines, thematic breaks, tables, footnote definitions, and inline emphasis, code, links and images. Each either already reads by code point (UTF-16 regexes, scalar scanners) or a joiner there changes the CommonMark result as well.

## Capabilities

### New Capabilities

- `markdown-block-markers`: block markers and link-reference syntax are recognized by Unicode code point, so a joining scalar after a marker neither hides it nor is dropped with it.

### Modified Capabilities

None.

## Impact

- Sources (all in `Sources/MD2Core/`):
  - `String+Markdown.swift`, `MarkdownLine.swift`, `OutlineBuilder.swift`, `LinkReference.swift`
  - `MarkdownEditing.swift` (`MarkdownIndentation.width`)
  - `MarkdownRenderer.swift`
- `Tests/MD2CoreTests/BlockMarkerScalarTests.swift`, and `TODOS.md`.
- Output changes only where a joining scalar or a prepended mark sits at a block marker or in reference-link syntax. It is byte-identical on every repository and local Markdown document, every CommonMark/GFM example, and 6,000 generated documents without joiners. Timing is unchanged. No public API, preview, export or GUI path changes.
