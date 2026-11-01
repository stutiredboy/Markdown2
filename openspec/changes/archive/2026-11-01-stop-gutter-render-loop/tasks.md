## 1. Preview gutter

- [x] 1.1 Make `observeGutterBlocks` observe the blocks again only when their set changes.

## 2. Tests

- [x] 2.1 Add `timerFrames` to the gutter test page, so animation frames run while the page is hidden.
- [x] 2.2 `testIdleGutterIsNotRebuilt`: an idle gutter does not render again and keeps its number elements.
- [x] 2.3 `testGrowingABlockMovesTheNumbersBelowIt`: a grown block moves the numbers below it, for the first and for swapped content.
- [x] 2.4 Confirm the idle test fails on the old script, and the growth test fails when the blocks are observed only once or never.

## 3. Verification

- [x] 3.1 Run `openspec validate stop-gutter-render-loop --strict`.
- [x] 3.2 Run the non-GUI suite in CI's three steps.
- [x] 3.3 Run the gutter and reading GUI suites locally.
- [x] 3.4 Count idle renders in Chromium with the old and the fixed script.
