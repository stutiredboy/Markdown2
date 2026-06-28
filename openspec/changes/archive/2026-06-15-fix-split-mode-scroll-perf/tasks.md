## 1. Responsive typing — debounce the preview-feeding render (issue 3 / D3)

- [x] 1.1 In `DocumentStore`, stop rendering synchronously on every keystroke:
      coalesce the `renderer.render(text)` triggered from `text.didSet` behind a
      short debounce (~120ms) so a burst of typing recomputes `rendered` once when
      the user pauses.
- [x] 1.2 Keep non-typing paths immediate: `setDocumentText` (open/load) renders
      synchronously as today; ensure `save`/stats see up-to-date content (flush the
      pending render before a save if a debounced render is in flight).
- [x] 1.3 Verify the editor's own text + caret path stays immediate (typed
      characters appear without waiting on the render) and that `isDirty` /
      autosave still fire correctly after the debounced render.
- [x] 1.4 Measure typing latency in Side by Side on a ~600-line document
      (e.g. `/Users/tiredboy/Downloads/matrix-cli-security.md`) before/after and
      confirm the editor keeps up with sustained typing.

## 2. Edits must not move the editor pane (issue 2 / D2)

- [x] 2.1 Ensure a live re-render caused by an edit cannot drive
      `document.editorJumpAnchor`: mark the editor as the sync driver on text
      change (re-arming `splitSyncSource`/`splitSyncToken`) so `syncPreviewToEditor`
      ignores the post-swap `anchorChange`, OR stop `applyLiveContent`'s settle
      from emitting an `anchorChange` at all.
- [x] 2.2 Confirm `syncPreviewToEditor` only runs for genuine user scrolls of the
      preview, never as a consequence of the live-content swap re-affirming the
      preview's own position.
- [x] 2.3 Reproduce the original bug: open the example file in Side by Side,
      scroll the editor to the middle, press Enter after the `---` above
      `## P2 - 高危漏洞(2 周内修复)`, and verify the editor stays put (no jump to
      the bottom).
- [x] 2.4 Regression-check that a deliberate preview scroll after the user stops
      typing still drives the editor (the driver cooldown is short enough).

## 3. Smooth follow-scrolling (issue 1 / D1, D4)

- [x] 3.1 In `MarkdownPreviewView`, add a lightweight "follow to position" JS hook
      that scrolls directly (no `keepPinned`: no 2.6s suppression, no multi-second
      rAF re-settle loop), reusing `sourceLineTargetY` + intra-block `offset` so
      the target advances continuously within a block instead of snapping to the
      block top. Keep `__md2ScrollToViewportAnchor`/`keepPinned` for mode switches
      only.
- [x] 3.2 In `ContentView.syncEditorToPreview`, route continuous follow through the
      new lightweight hook (carry intra-block progress / `scrollFraction`), not
      `document.previewJumpAnchor`. Drop or shorten the heavy per-tick path.
- [x] 3.3 In `MarkdownEditorView`, provide a continuous follow entry point for
      `syncPreviewToEditor` that scrolls the clip view directly to a proportional
      Y (does not snap to a line's block top) and stays suppressed from anchor
      reporting (`isProgrammaticScroll`) only briefly around the scroll.
- [x] 3.4 Preserve the oscillation guard: the follower's brief programmatic-scroll
      suppression must still prevent its own follow scroll from reporting back and
      bouncing the driver (per D4).
- [x] 3.5 Verify: dragging the editor scrollbar continuously down makes the preview
      track smoothly with no discrete-step jumping or per-tick refresh/flash, and
      the panes are aligned when the drag stops. Check the reverse direction
      (dragging the preview) too.

## 3b. Preview follows the editing position (issue 4 / follow-up)

- [x] 3b.1 In `MarkdownEditorView.textDidChange`, compute the caret's 1-based
      source line and report it through `onTextEdit(caretLine)` (add
      `lineNumber(forCharacterIndex:in:)`, mirroring `topVisibleLine`'s numbering).
- [x] 3b.2 In `MarkdownPreviewView`, add a `__md2FollowEditLine(line)` JS hook +
      `PreviewViewportReader.setPendingEditFollow` (stored on the coordinator).
      The hook scrolls the caret line into the lower-middle of the viewport ONLY
      when it is off-screen, leaving the preview untouched when already visible.
      `applyLiveContent` consumes the pending line and, after swapping content,
      runs the follow INSTEAD of the `keepPinned` re-affirm — so no pin loop
      competes with it and the follow runs against the freshly swapped DOM.
- [x] 3b.3 In `ContentView.markEditorEditInSplit(caretLine:)`, mark the pending
      edit-follow line. Editor stays the sync driver so the follow can never
      bounce the editor pane.
- [x] 3b.4 Gate editor→preview scroll sync on genuine user scrolls: thread
      `isUserScroll` through `MarkdownEditorView.onAnchorLineChange` (true only for
      wheel/drag events) and only call `syncEditorToPreview` when it is true, so an
      edit-induced caret-reveal scroll can never snap the preview to the editor's
      *top* line (the root cause of the preview jumping to the block above the
      edit on insert/delete). Mirrors the preview's existing `isUserInitiated`.
- [x] 3b.5 Make the edit-follow time-windowed, not consume-once: while within the
      edit window EVERY live swap follows the latest caret line and the capture +
      `keepPinned` re-affirm is disabled, so no stray swap in an edit burst (e.g. a
      multi-key delete) can pin a drifted position.
- [x] 3b.6 Unit-cover the caret line mapping (`MarkdownEditorCaretLineTests`).
- [x] 3b.7 Verify: typing/adding AND deleting content keeps the preview showing the
      editing region (never jumping to the block above); editing mid-viewport
      leaves the preview still; the editor pane never moves as a result.

## 4. Validation

- [x] 4.1 `swift build` succeeds; run the app and exercise Side by Side end-to-end.
- [x] 4.2 Re-confirm all three reported scenarios are fixed together (smooth
      follow, Enter-near-`---` does not jump the editor, typing keeps up) and that
      single-pane Edit/Preview and mode-switch scrolling are unchanged.
- [x] 4.3 Run `openspec verify --change fix-split-mode-scroll-perf` (or
      `/opsx:verify`) and reconcile any gaps before archiving.
