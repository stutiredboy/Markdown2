## Context

A document owns one editor text view (`MarkdownEditorSession`), built the first time an editor is shown. `loadTextView` sets the document as the text view's string, so it starts as plain 12 pt text with no paragraph style. `makeNSView` then schedules styling. `MarkdownStylingController.schedule` waits 25 ms to coalesce input, prepares a style plan on a worker actor, and applies it in 8 KB chunks, yielding between chunks.

A mode switch hands the editor a viewport anchor. `applyAnchorUntilSettled` scrolls the anchored line to one container inset below the viewport's top, and re-applies it across run-loop turns until the content height stops changing. That takes a few turns and finishes long before styling arrives.

Each styled chunk changes line heights: body text grows from 12 pt to the editor font with line and paragraph spacing, and headings grow further. The styler restored the scroll offset it had before the chunk. On a new text view, every line above the viewport grew, so the same offset showed text far above the anchored line: line 31 instead of 79.

## Decisions

### Keep the viewport's line, not its offset

Before each chunk, the styler records a `ViewportLine`: the line fragment at the viewport's top in container coordinates, and how far that point sits below the fragment's top. In the text view, that point is one container inset below the viewport's top. After the chunk, it scrolls so the same fragment is at the same place.

The reference point is the inset depth because that is where `scrollLineToTop` puts a jump or mode-switch target. The first version used the fragment at the viewport's top edge. That left the editor 75 pt off: the top edge sat in text above the target, and the text between the top edge and the target grew with styling.

The frame-origin reset before the scroll is kept. A reflow can grow a short text view with a negative frame origin, and the probes and gutter assume the document starts at zero.

*Alternatives considered:*
- **Style a new text view synchronously.** No reflow after the anchor, and no flash of plain text. Rejected: the styler is asynchronous and chunked so that a large document does not block the main thread, and the first mount is when the whole document needs styling.
- **Re-apply the anchor after styling completes.** It fixes only the anchor path. A jump or a gutter selection made right after mounting would still drift, and the editor would visibly jump once styling ended.
- **Keep the caret's line when the caret is on screen.** It also covers a selection made low in the viewport. Rejected for now: a Read-mode gutter click delivers an anchor on the clicked line, so the clicked line is the anchored line. The new test checks that case at several scroll positions. Tying the viewport to the caret would also change how Side by Side follows the preview.

## Verification

- **New tests, old styler:**
  - `testFirstSwitchToWriteLandsOnTheAnchoredLineAfterStyling` finds the anchored line (79) 2,531 pt below the viewport's top instead of 48 pt, with line 31 at the top.
  - `testPreviewNumberLowInReadModeOpensItsLineAtTheTop` finds the clicked line 1,549 pt below the top of a 703 pt viewport.
- **Reference point at the viewport's top edge:** the first test finds the line 123 pt below the top.
- **Fixed:** both tests pass. The click test also passed with the clicked line as low as 24 px above the preview's bottom edge, at three scroll positions, with the monospaced editor font.
- **Suites:**
  - The whole GUI lane (`MD2_RUN_GUI_TESTS=1 swift test --disable-swift-testing`) passes locally: 131 tests, with only the two allowlisted skips.
  - The three non-GUI CI steps pass.

## Risks / Trade-offs

- **Every restyle that changes heights above the viewport now keeps the line**: a typography or zoom change, and an open or reload that restyles the text. Before, those kept the offset and drifted to other text. Typing is unaffected: an edit restores its own offset, and while typing no line above the viewport changes height, so both rules give the same offset.
- **A selection low in the viewport is not held in place on its own.** If something other than an anchor selected a line far below the inset depth right after mounting, styling could still move that line. No current path does that.
- **Plain text still shows briefly** before the first styling arrives, as before.
