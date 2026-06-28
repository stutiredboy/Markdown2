## Why

Side by Side mode shipped, but daily use surfaced three regressions that make it
unpleasant to write in: the preview **jumps in discrete steps** instead of
scrolling smoothly when the editor is dragged; pressing Enter near a thematic
break (`---`) **yanks the editor to the bottom** of the document; and typing in
the left pane is **visibly laggy**, falling behind the user's keystrokes on a
moderately sized document. All three stem from the live-sync and live-render
machinery doing too much, too synchronously, on every editor event.

## What Changes

- **Smooth follow-scrolling (issue 1).** When the editor drives the preview (and
  vice versa), stop routing each scroll tick through the heavy mode-switch
  pinning helper (`__md2ScrollToViewportAnchor` → `keepPinned`), which suppresses
  reporting for 2.6s and runs a multi-second re-settle loop per tick and snaps to
  block tops. Replace continuous follow-scroll with a lightweight, direct
  position update that tracks the driver proportionally (using intra-block
  progress / fraction) so the follower moves smoothly rather than snapping
  between block boundaries.
- **Edits must not move the editor pane (issue 2).** A text edit originates in
  the editor; the live preview re-render that follows SHALL NOT drive the editor
  pane's scroll position. Today the post-re-render preview anchor report reaches
  `syncPreviewToEditor` (the editor is not marked as the sync driver while
  typing, so the oscillation guard does not catch it) and pushes the editor to a
  mis-resolved position — the bottom — at the `---`/`<hr>` boundary. Mark the
  editor as the active driver across an edit so the re-render's settle report
  cannot bounce the editor.
- **Responsive typing (issue 3).** Decouple the per-keystroke cost from the
  keystroke. The full-document Markdown re-render (`DocumentStore.text.didSet →
  renderer.render`) and the full-document editor restyle
  (`MarkdownTextStyler.apply` on every `textDidChange`) both run synchronously on
  the main thread on every character. Coalesce/debounce the preview-feeding
  re-render so a burst of typing renders once when it settles, keeping the
  editor's own text/caret path immediate. (Stats/outline that ride the same
  render may update on the debounced cadence.)

## Capabilities

### New Capabilities
<!-- None: this change refines the behavior of an existing capability. -->

### Modified Capabilities
- `split-view-editing`: tighten three existing requirements with quality
  guarantees — synchronized scrolling must follow **smoothly** (no
  discrete-step/refresh jumping during a continuous drag); a **live re-render
  triggered by an edit must not change the editor pane's scroll position**; and
  **typing must stay responsive** (input is not blocked waiting on a
  full-document re-render of the other pane).

## Impact

- **Code**:
  - `ContentView` — split scroll-sync drivers (`syncEditorToPreview`,
    `syncPreviewToEditor`, `markSyncSource`, `editorSyncWork`): switch continuous
    follow from anchor-jump to a smooth position update; treat an edit as an
    editor-driven event so the re-render cannot drive the editor.
  - `MarkdownPreviewView` — add/route a lightweight "follow to position" JS hook
    distinct from the mode-switch `__md2ScrollToViewportAnchor`/`keepPinned`
    path; ensure the live-content swap's settle report does not feed back as a
    user scroll during an edit.
  - `MarkdownEditorView` — provide a continuous follow-scroll entry point that
    does not snap to a line's block top, and ensure programmatic follow scrolls
    stay suppressed from anchor reporting.
  - `DocumentStore` — debounce/coalesce the render that feeds the live preview so
    a single keystroke does not force a synchronous whole-document render before
    the next keystroke is accepted.
- **No data/format changes**: purely a UX/performance refinement of Side by Side.
  Single-pane Edit/Preview and mode-switch anchoring are unchanged. Saved
  documents and mode preferences are unaffected.
