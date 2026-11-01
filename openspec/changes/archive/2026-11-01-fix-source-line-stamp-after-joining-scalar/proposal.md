## Why

A block whose content starts with a combining mark got its `data-md2-source-line` attribute in the wrong place. `\u{0301}para` rendered `<p>́para</p data-md2-source-line="1">`. That HTML is invalid, and the browser drops an attribute on a closing tag, so the block lost its line mapping. The preview gutter left it unnumbered, and mode-switch anchoring could not use it.

The `unify-token-grammar` differential run (2026-10-31) found it, and it was recorded in `TODOS.md` ("Source-line attribute lands on the closing tag after a leading combining mark").

`taggedWithSourceLines` finds the end of the block's opening tag with `html.firstIndex(of: ">")`, a `Character` search. Any scalar that extends a grapheme (a combining mark, ZWJ, a variation selector, a spacing mark) fuses with that `>`, so the search skipped to the next standalone `>`. Depending on the content, that was the closing tag or an inline tag inside the block: `<br>`, `<a>`, `<code>`, `<span>`, `<em>` or `<img>`.

## What Changes

- **`taggedWithSourceLines` searches the UTF-8 view for `>`.** The `>` byte is never part of a multi-byte sequence, so the first one ends the opening tag however the content clusters.
- **Declare the placement** in the `mode-switch-scroll-anchoring` requirement "Preview blocks expose source-line anchors".
- **Add tests:** a headless test for four joining scalars across four block shapes, and a GUI gutter test that numbers a paragraph starting with a mark. Both fail on `main`.
- **Update `TODOS.md`:** remove the item, and record a related issue the probe found: block markers and link brackets are also read as graphemes.

**Non-goals:**

- **Block markers stay as they are.** `# ` + U+0301 + `x` still renders a paragraph, not a heading: the mark fuses with the space after `#`, and the heading check compares `Character`s. List and task markers behave the same way, and a prepend character before `[` hides the bracket from the link scanner. Those are parser changes with a wider surface, now recorded in `TODOS.md`.
- **The test helper `scanTags`** in `MetadataInvariantTests` also searches `Character`s. The new test does not rely on it, and the corpus invariants it serves are unchanged.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `mode-switch-scroll-anchoring`: source-line metadata sits on the block's own opening tag, including when the content starts with a joining scalar.

## Impact

- `Sources/MD2Core/MarkdownRenderer.swift`: `taggedWithSourceLines`, one line.
- `Tests/MD2CoreTests/MetadataInvariantTests.swift` and `Tests/MD2CoreTests/LineNumberGutterGUITests.swift`: one new test each.
- `TODOS.md`.
- Output changes only for blocks whose content starts with a joining scalar. It is byte-identical on every repository and local Markdown document and every CommonMark/GFM example. No public API, preview JavaScript/CSS or export path changes. The gutter script is unchanged; it now receives the attribute it was missing.
