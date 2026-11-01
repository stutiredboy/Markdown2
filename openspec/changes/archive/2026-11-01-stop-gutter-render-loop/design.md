## Context

The preview gutter (`lineNumberGutterScript`) positions a number beside each top-level block and each multi-line item of a top-level list. Positions go stale when a block changes height after rendering, as math and diagrams do when they settle. A `ResizeObserver` watches the top-level blocks for that, and its callback schedules a render on the next animation frame.

Each render ended by calling `observeGutterBlocks`, which disconnected the observer and observed every block again. Per the Resize Observer spec, observing an element queues a first notification for it. So every render queued notifications, the notifications scheduled a render, and that render observed the blocks again: one render per frame for as long as the numbers were shown.

## Decisions

### Re-observe only when the set of blocks changes

`observeGutterBlocks` keeps the array of blocks it last observed (`observedGutterBlocks`) and compares it with the new one, element by element. When they match, it returns without touching the observer. When they differ, it disconnects and observes the new set, as before.

The blocks change only when the content does: `__md2ApplyContent` replaces `<main>`'s children, and the render it triggers finds new elements. That render observes them, their first notifications schedule one more render, and that render finds the same set and stops. A content update therefore costs two renders instead of an endless series.

*Alternatives considered:*
- Ignore notifications whose sizes have not changed, tracked in a `WeakMap`. This also stops the loop, but it keeps re-observing on every render and adds a size cache, for the same result.
- Observe new blocks and unobserve removed ones one by one. This saves the first notifications of blocks that stay, but content swaps replace every block anyway.

### Run the test page's animation frames on a timer

An offscreen test window, and an on-screen one behind the active app's windows, count as hidden to WebKit. A hidden page gets no animation frames, but it still gets resize notifications (about 30 per second, then about 9). The gutter's first scheduled render therefore never runs, its "scheduled" flag stays set, and every later request is dropped. The loop could not show in the suite: the idle test passed on the broken script, and the growth test failed on both scripts.

`loadPage(timerFrames: true)` installs, at document start, a `requestAnimationFrame` that runs its callback on a 16 ms timer, so the gutter's renders run as in a visible window. It is opt-in, so the other gutter tests keep their current page setup.

## Verification

- **New tests, both scripts:**
  - With the old script, `testIdleGutterIsNotRebuilt` counts 40 renders in 2 s and finds its number elements replaced.
  - With the fix, it counts 0 renders and keeps the elements. `testGrowingABlockMovesTheNumbersBelowIt` passes on both scripts.
- **Mutations:**
  - Observing only once, never again, fails the swapped-content half of the growth test.
  - Never observing fails both halves.
- **Chromium (a visible page, real frames):** the old script renders 120 times in 2 idle seconds and replaces its numbers. The fixed one renders 0 times and keeps them.
- **Suites:** the three non-GUI CI steps, and the `EditorLineNumberGutterGUITests`, `LineNumberGutterGUITests` and `ReadingImprovementsGUITests` GUI suites, pass locally. `testPreviewGutterNumberSelectsItsLineInTheEditor` passed 5 of 5 runs. Those runs carry little weight, because the local test windows were hidden and the loop needs real frames.

## Risks / Trade-offs

- **The swapped-content half of the growth test waits 0.5 s before growing a block.** The old blocks' removal is also reported. Without the wait, that notification's render could land after the growth and move the number in place of the new blocks' own notification, which hid the observe-once mutation on the first try.
