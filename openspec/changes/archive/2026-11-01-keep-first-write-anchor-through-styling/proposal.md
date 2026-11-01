## Why

The first switch from Read to Write in a window can land far from the anchored line: in a measured case, the editor was anchored at line 79 and showed line 31 at the top. That happens whenever the editor is shown for the first time in that window, which is the usual case for a document opened in Read mode. A preview line number clicked in Read mode is delivered the same way and missed the same way: the clicked line ended up 1,549 pt below the top of an editor viewport 703 pt tall.

The editor's text view is built with the document as plain 12 pt text, and its syntax styling arrives asynchronously, about 25 ms later. The mode-switch anchor settles within a few run-loop turns, against the plain layout. Styling then changes every line's height, and the styler kept the scroll offset in points, so the viewport ended up showing different text.

This was found while numbering list items (2026-11-01, `number-multiline-list-items`, recorded in its design as out of scope). That change's anchoring test opens the document in Write mode first, to avoid this.

## What Changes

- **The styler keeps the viewport on the same line.** Before each styled chunk, `MarkdownStylingController` records the line fragment one container inset below the viewport's top, where a jump or a mode switch puts its target line, and its offset within that fragment. After the chunk, it scrolls so that fragment is at the same place. Before, it restored the old offset in points.
- **Tests (`ReadingImprovementsGUITests`):**
  - The first switch to the editor, from a document opened in Read mode, lands on the anchored line once the text is styled.
  - A preview number low in the viewport, clicked in Read mode, opens an editor shown for the first time with that line at the top, once styled.

**Non-goals:**

- The plain text still shows for a moment before styling arrives. Styling a new text view synchronously would block the main thread on large documents, which the chunked, asynchronous styler exists to avoid.
- No change to typing: an edit still restores its own scroll offset, and no line above the viewport changes height while typing, so both rules give the same offset.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `mode-switch-scroll-anchoring`: the destination still shows the anchored line once the editor has styled its text.
- `line-number-display`: a preview number clicked in Read mode keeps its line at the top once the editor has styled its text.

## Impact

- `Sources/MD2App/MarkdownTextStyler.swift`: `MarkdownStylingController.schedule` and a new private `ViewportLine`.
- `Tests/MD2CoreTests/ReadingImprovementsGUITests.swift`.
- Restyles that change line heights above the viewport now keep the viewport's line instead of its offset. That covers a typography or zoom change, and an open or reload that restyles the text.
- No change to rendered HTML or exports.
