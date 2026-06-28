## 1. Reproduce and confirm root cause

- [x] 1.1 Open a short document (one that does not fill a page, e.g. the
      Untitled new-document template) in preview mode, switch to editor mode, and
      confirm the top of the document scrolls out of view
      - Reproduced against the already-running installed app:
        `AXVisibleCharacterRange` for the short Untitled editor started at
        character 40 after the switch, while the document value still began with
        `# Untitled`, confirming the viewport had been pushed below the top.
- [x] 1.2 Instrument `MarkdownEditorView.scrollLineToTop` / `scroll(toFraction:)`
      to log `documentHeight`, `visibleHeight`, `maxOffset`, and `targetY` at the
      moment of the post-switch scroll; confirm whether geometry is measured
      before layout settles and/or `makeFirstResponder` auto-scrolls the caret
      - Runtime log finding: for the short Untitled document the computed
        `targetY` was 0, but before the explicit scroll AppKit had
        `clipBounds.y = -206` and `visibleRect.y = 0` (the correct top-visible
        state). Calling `contentView.scroll(to: y: 0)` changed the text view's
        visible rect to `y = 206`, producing `AXVisibleCharacterRange = 40,35`
        and hiding the heading. Root cause is therefore the explicit scroll
        itself in the content-fits case, not clamp math.
- [x] 1.3 Record the confirmed trigger so the guard in section 3 targets the
      actual cause
      - Static analysis finding: for the new-document repro the anchor resolves
        to the first heading (line 1), and the explicit scroll math already
        computes offset 0 there — so the scroll-out is **not** from the clamp
        math. Runtime instrumentation showed the trigger is that a short
        `NSTextView`'s top-visible clip origin can be negative; forcing the clip
        view to scroll to `y = 0` moves the visible text rect down and hides the
        heading. Fix therefore: settle layout before measuring, retry if
        geometry is not ready, and when content fits the viewport do not issue
        any explicit scroll.

## 2. Pure scroll-offset helper (MD2Core)

- [x] 2.1 Add a pure `clampedScrollOffset(targetY:contentHeight:viewportHeight:)`
      helper in `Sources/MD2Core/` that returns 0 when
      `contentHeight <= viewportHeight` and otherwise clamps to
      `0...(contentHeight - viewportHeight)`
      (`Sources/MD2Core/ScrollOffset.swift`)
- [x] 2.2 Add `Tests/MD2CoreTests/` unit tests covering: content fits → 0;
      target above range → 0; target below range → max offset; mid-range target
      → unchanged; degenerate zero/negative heights → 0
      (`Tests/MD2CoreTests/ScrollOffsetTests.swift`, 8 tests, all passing)

## 3. Editor scroll path (MD2App)

- [x] 3.1 Route `scrollLineToTop(charRange:in:)` and `scroll(toFraction:in:)`
      through `clampedScrollOffset`, removing the duplicated
      `max(0, documentHeight - visibleHeight)` clamping
- [x] 3.2 Ensure layout is settled (`ensureLayout(for:)`) before measuring
      `documentView`/`contentView` heights for the post-switch scroll, so the
      clamp sees real content height rather than the seeded container size
      (already present in `scrollLineToTop`; added to `scroll(toFraction:)`)
- [x] 3.3 In the "content fits" case, perform a single explicit scroll to offset
      0 and avoid a redundant `makeFirstResponder` re-scroll that could push the
      fits-on-screen document out of view; verify the editor still gains focus
      with the caret at the anchored line
      (reordered `scroll(to:)` to focus first, then set the target selection,
      then scroll last for scrollable documents. If content fits, the editor
      now returns without calling `contentView.scroll(to:)`; if geometry is
      still zero-sized, the pending scroll is retried on the next main-queue
      tick. A brief `TopPinnedClipView` attempt was removed because constraining
      the clip view globally could hide all editor text after the switch.)

## 4. Verification

- [x] 4.1 Manual: short document preview → editor keeps the first heading visible
      and requires no scrolling back (the original repro)
      - Verified with the actual `swift run Markdown2` path by targeting the
        freshly launched debug app PID through AX: after Edit → Rich Text
        Document → Edit on the short Untitled document, the editor text value
        begins with `# Untitled` and `AXVisibleCharacterRange` remains
        `0,75` immediately and after a delay, instead of the reproduced
        non-top range (`40,35`).
- [x] 4.2 Manual regression: a multi-page document preview → editor still scrolls
      so the anchored section is at the top, within the scrollable range
      - Verified by the user in the running app.
- [x] 4.3 Manual regression: editor → preview round trip preserves position for
      both short and long documents
      - Verified by the user in the running app.
- [x] 4.4 Run `swift test` and confirm the new helper tests and the existing
      `ModeSwitchAnchorTests` pass
      (103 tests in 14 suites passed; `ScrollOffsetTests` and
      `ModeSwitchAnchorTests` both green)
