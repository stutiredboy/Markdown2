## Why

While preview line numbers are shown, the gutter renders again on every animation frame, even when nothing on the page changes: 120 passes in 2 s on an idle page in Chromium. Every pass removes the number elements and creates new ones. That costs work on every frame for as long as the numbers are on. It also loses clicks: a click whose mouse-down and mouse-up land on two different passes hits a number element that is no longer in the page, and nothing is selected. That is why `testPreviewGutterNumberSelectsItsLineInTheEditor` failed intermittently.

The cause is in `observeGutterBlocks`. Each pass disconnects the `ResizeObserver` and observes every block again. Observing an element delivers a first notification, and that notification schedules the next pass.

This was found while numbering list items (2026-11-01, `number-multiline-list-items`, recorded in its design as out of scope).

## What Changes

- **Observe only a changed set of blocks.** `observeGutterBlocks` remembers the blocks it observes and returns early when a pass finds the same blocks in the same order. A content swap brings new blocks, which are observed as before, so a block that changes height after rendering (math, diagrams) still moves the numbers below it.
- **Tests (`LineNumberGutterGUITests`):**
  - An idle gutter does not render again and keeps its number elements.
  - A block that grows moves the numbers below it, for the first content and for swapped content.
  - The test page can run animation frames on a timer (`timerFrames`). A test window counts as hidden, and WebKit runs no animation frames for a hidden page, so without this the loop never showed in the suite.

**Non-goals:**

- List items stay unobserved. Their numbers move when their list's box changes, which covers an item that grows. Two items in one list that change by equal and opposite amounts would leave stale numbers below them; that case already applied to the list's blocks before this change and is not addressed here.
- No change to when the gutter renders after a content update or a window resize.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `line-number-display`: the preview gutter follows blocks that change height and leaves the numbers alone while nothing changes.

## Impact

- `Sources/MD2App/MarkdownPreviewView.swift`: `lineNumberGutterScript` (`observeGutterBlocks`).
- `Tests/MD2CoreTests/LineNumberGutterGUITests.swift`.
- No change to rendered HTML or exports.
