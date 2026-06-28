## Context

Toggling between Write (editor) and Read (preview) modes preserves the reader's
position by capturing an anchor from the outgoing view and applying it to the
freshly created incoming view. `ContentView.requestMode(_:)` resolves the
anchor and sets `document.jumpLine` / `document.jumpFraction` / `jumpHeadingID`
*before* flipping `mode`, so the destination view knows where to land as it
loads (`ContentView.swift:214-250`).

On Read → Write, the editor receives a `jumpLine` (the section heading line) or
a `jumpFraction` fallback and, in `MarkdownEditorView.updateNSView`, scrolls to
it on the next runloop tick via `scroll(to:)` → `scrollLineToTop(charRange:in:)`
or `scroll(toFraction:in:)` (`MarkdownEditorView.swift:134-167, 169-219`).

These routines already clamp to `maxOffset = max(0, documentHeight -
visibleHeight)`. Mathematically, for a short document anchored at line 1 the
target offset is 0. Yet in practice (per the reported repro and screenshots) a
short, non-page-filling document ends up scrolled so its top — including the
first heading — sits above the viewport, and the user must scroll back up.

The likely trigger is that the geometry is measured against a **freshly created
text view whose TextKit layout has not yet settled**: the scroll runs inside a
`DispatchQueue.main.async` block right after `makeNSView`, the text container
starts at `.greatestFiniteMagnitude` height with `isVerticallyResizable = true`,
and `makeFirstResponder` is invoked from both `makeNSView` and `scroll(to:)`.
Measuring `documentView.bounds.height` / `contentView.bounds.height` or letting
AppKit auto-scroll-to-caret at that instant can yield a non-top resting offset
for content that actually fits the window.

The codebase already isolates the cross-mode anchor math as pure, unit-tested
functions in `MD2Core/ModeSwitchAnchor.swift` (tested in
`ModeSwitchAnchorTests.swift`). This change follows the same pattern for the
scroll-offset clamp so the core decision ("content fits → offset 0") is provable
without driving AppKit.

## Goals / Non-Goals

**Goals:**
- A document that fits within the viewport stays pinned to the top after a
  Read → Write switch; its first heading is never pushed out of view.
- The clamped scroll-offset decision is a pure function in `MD2Core` with unit
  coverage, including the "content fits the viewport" case.
- The editor measures valid geometry (settled layout) before computing the
  post-switch scroll, so the clamp operates on real heights.

**Non-Goals:**
- Changing how anchors are *captured* or which heading/fraction is chosen
  (`ModeSwitchAnchor`, `requestMode`) — only how the resulting offset is applied.
- Changing the preview (Read) scroll path; the reported defect is on the editor
  side. The preview's reflow-pinning (`keepPinned`) stays as-is.
- Reworking the editor's TextKit stack, find/replace, or styling.

## Decisions

### Decision 1: Extract a pure `clampedScrollOffset` helper into MD2Core
Add a pure function (e.g. `clampedScrollOffset(targetY:contentHeight:viewportHeight:)
-> CGFloat`) that returns `0` when `contentHeight <= viewportHeight` (content
fits → no scrollable range) and otherwise clamps `targetY` to
`0...(contentHeight - viewportHeight)`. Route both `scrollLineToTop` and
`scroll(toFraction:)` through it.

- **Why:** Mirrors `ModeSwitchAnchor`'s pure-helper pattern, makes the
  "short document stays at top" rule directly testable in `MD2CoreTests`, and
  removes duplicated `max(0, documentHeight - visibleHeight)` clamping logic.
- **Alternative considered:** Inline guard inside each scroll method. Rejected —
  duplicates the clamp and leaves the key rule untestable without AppKit.

### Decision 2: Guard the no-scroll case explicitly, and order focus before scroll
When the helper reports the content fits (offset 0), skip any work that could
move the viewport and explicitly settle at the top: set the selection/insertion
point to the target line but scroll to offset 0, and avoid a redundant
`makeFirstResponder` re-scroll fighting the explicit position.

- **Why:** Even with a correct clamp, AppKit's auto-scroll-to-selection on
  first-responder change can move a fits-on-screen document. Making "fits →
  top" an explicit, single scroll removes the race.
- **Alternative considered:** Rely on clamp alone. Rejected — does not address
  the first-responder auto-scroll interaction observed on freshly created views.

### Decision 3: Measure geometry only after layout is settled
Before measuring heights for the post-switch scroll, force layout
(`ensureLayout(for:)`, already present in `scrollLineToTop`) and take the
measurement on a tick where `documentView.bounds` reflects the real content
height (e.g. after the existing async hop, re-validated). The clamp then sees
true heights rather than the `.greatestFiniteMagnitude`-seeded container size.

- **Why:** A short document only scrolls out of view when the heights are read
  too early; settling layout first makes the clamp's "fits" branch fire.
- **Alternative considered:** Add fixed delays. Rejected — flaky; prefer
  forcing layout and measuring deterministically.

## Risks / Trade-offs

- **[Root cause is AppKit-timing and not fully reproduced in a unit test]** →
  The pure helper is unit-tested for the offset decision; the end-to-end
  behavior is verified manually with a short document (the repro) and a long
  document (regression check) per the tasks. First implementation task is to
  reproduce and confirm the exact trigger before finalizing the guard.
- **[Over-suppressing scroll could break the long-document case]** → The helper
  only returns 0 when content genuinely fits; long documents still scroll to the
  anchored heading/fraction. A regression check on a multi-page document is
  included in the tasks.
- **[`makeFirstResponder` reordering could affect focus]** → The editor must
  still receive focus on entering Write mode; verify the cursor lands at the
  anchored line and the editor is first responder after the switch.
