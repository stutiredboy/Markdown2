## Context

Side by Side (`split`) layers continuous, bidirectional scroll sync and live
preview re-render on top of primitives originally built for a once-per-mode-switch
transition. Three of those reuses are now the source of the reported problems.

Current data flow (per the archived `add-split-mode` design and the code):

- **Editor → preview sync.** `MarkdownEditorView` posts `boundsDidChange` →
  `onAnchorLineChange(line)` → `ContentView.syncEditorToPreview(line)`, which
  (after a 50ms debounce) sets `document.previewJumpAnchor`. The preview's
  `updateNSView` turns that into `setPendingScroll(.viewport(anchor))` →
  `__md2ScrollToViewportAnchor(payload)` → `keepPinned(...)`.
- **Preview → editor sync.** The page posts `anchorChange` (80ms throttle) →
  `onAnchorChange` → `syncPreviewToEditor(anchor)` → sets
  `document.editorJumpAnchor`, applied by `applyAnchorUntilSettled`.
- **Live re-render.** `DocumentStore.text.didSet` synchronously calls
  `renderer.render(text)` on every keystroke; the preview's `updateNSView` then
  runs `applyLiveContent` (debounced 90ms) which swaps `<main>.innerHTML` and
  re-affirms the captured anchor via `__md2ScrollToViewportAnchor`.
- **Oscillation guard.** `splitSyncSource` (+ `splitSyncToken`, 250ms cooldown)
  marks who is driving so the follower's settle-time report is ignored.

Three root causes:

1. **Jumpy follow-scroll.** `keepPinned` is a mode-switch helper: it sets
   `suppressUntil = now + 2600ms` and runs a `requestAnimationFrame` re-settle
   loop for up to 2.5s, re-resolving the block target each frame and calling
   `window.scrollTo` to a block top. Invoked on every editor scroll tick during a
   drag, these loops stack and the target is quantized to block boundaries — the
   preview snaps between blocks and "refreshes" rather than tracking the drag.
2. **Enter → editor jumps to bottom.** An edit re-renders → `applyLiveContent`
   swaps content and, on settle, `keepPinned.done()` calls `topAnchor()` which
   posts `anchorChange`. Typing never scrolls the editor, so `splitSyncSource`
   is `nil` (not `.editor`); the guard `splitSyncSource != .editor` in
   `syncPreviewToEditor` therefore passes and the preview drives
   `document.editorJumpAnchor`. At the `---`/`<hr>` + heading boundary the
   re-resolved anchor mis-maps (the inserted blank line shifts source lines and
   the `<hr>` has no stable block span), so the editor lands at the fraction/
   bottom fallback.
3. **Typing lag.** Two O(document) operations run synchronously on the main
   thread per keystroke: `renderer.render(text)` (in `text.didSet`) and
   `MarkdownTextStyler.apply` (in `textDidChange`). In split this is compounded by
   the live JS swap + KaTeX/Mermaid re-run and the sync churn. The render is
   unconditional and undebounced, so each character waits on a full re-render.

## Goals / Non-Goals

**Goals:**
- Follow-scroll in split tracks the driver smoothly, without per-tick block-snap
  or page-refresh flashing.
- An edit never moves the editor pane; the preview re-render cannot drive the
  editor.
- Typing stays responsive on a multi-hundred-line document; the heavy
  preview-feeding render is coalesced off the keystroke path.

**Non-Goals:**
- Changing single-pane Edit/Preview behavior or the once-per-mode-switch
  anchoring (`mode-switch-scroll-anchoring` stays as-is).
- Reworking the renderer or styler internals (no incremental/partial reparse in
  this change — only when the work runs, not how it renders).
- Pixel-perfect line-to-line lockstep; "smooth and approximately aligned" is the
  bar, matching the existing anchoring model's tolerance.

## Decisions

### D1: Separate "continuous follow" from "mode-switch pin"
Add a lightweight follow path distinct from `__md2ScrollToViewportAnchor` /
`keepPinned`. Continuous follow SHALL NOT arm the 2.6s suppression or the
multi-second rAF re-settle loop. The follower scrolls directly to a computed Y
once per coalesced tick (`window.scrollTo` for the preview; a direct clip-view
offset for the editor), with no re-settle loop.
- **Smoothness via proportional position, not block-snap.** Carry the driver's
  intra-block progress (and the proportional `scrollFraction` fallback) through to
  the follower so the target advances continuously within a block instead of
  pinning to the block top. The preview already computes `sourceLineTargetY(line)`
  with an intra-block `offset`; expose a "scroll to this Y without keepPinned"
  entry, and feed it the progress so consecutive ticks yield nearby Ys.
- *Alternative considered:* CSS `scroll-behavior: smooth` on each jump. Rejected —
  it animates each discrete jump, smearing the existing block-snap rather than
  removing it, and fights the rAF loop.
- *Alternative considered:* a brand-new pixel offset sync table (driver scroll
  fraction → follower scroll fraction). Viable and simplest for raw smoothness,
  but loses block alignment on uneven content; keep the source-line/progress
  anchor as the primary and use fraction only as the existing fallback.

### D2: An edit marks the editor as the sync driver
Before/while the live re-render runs, treat the edit as an editor-driven sync
event so the post-swap preview report is ignored by `syncPreviewToEditor`. Concrete
options (pick during implementation, prefer the first):
- **Mark `splitSyncSource = .editor` on text change** (re-arming the existing
  cooldown) so the re-render's settle `anchorChange` is suppressed by the existing
  guard — the smallest, most consistent change.
- *Or* have `applyLiveContent` not emit a settle `anchorChange` at all (the live
  swap path does not need to report the user's anchor; only genuine user scrolls
  should). This removes the feedback at the source.
- Either way, `syncPreviewToEditor` MUST NOT push `document.editorJumpAnchor` as a
  consequence of a re-render. The live swap already re-affirms the *preview's* own
  position; the editor must be left untouched.
- *Alternative considered:* fix the anchor mis-resolution at the `<hr>` boundary
  instead. Rejected as insufficient — even a correct anchor should not move the
  editor on an edit; the feedback path itself is the bug.

### D3: Debounce the preview-feeding render off the keystroke
Keep the editor's own text path immediate (the `NSTextView` already shows typed
characters; `text` binding + `MarkdownTextStyler` keep the source styled). Coalesce
the expensive `renderer.render` that exists only to feed the preview/stats so a
burst of typing renders once when it settles.
- **Where to debounce:** introduce a coalesced render in `DocumentStore` (e.g. a
  short timer in `text.didSet`, ~80–150ms, that recomputes `rendered` once the
  user pauses) rather than rendering on every character. `rendered` stays
  `@Published`; only its update cadence changes. The preview's own `applyLiveContent`
  debounce (90ms) then rides on already-coalesced input.
- **Keep immediate-render entry points** for load and save/stats correctness
  (`setDocumentText` still renders synchronously on open; an explicit flush before
  save/stats if needed) so non-typing paths are unaffected.
- *Trade-off:* stats/outline update on the debounced cadence too. Acceptable —
  they are not latency-critical and already update post-render.
- *Alternative considered:* move `renderer.render` to a background queue. Larger
  change (renderer/`RenderedDocument` main-actor assumptions, ordering); debounce
  delivers most of the win with far less risk. Background rendering remains a
  possible follow-up if debounce alone is insufficient.
- *Note on styler:* `MarkdownTextStyler.apply` is whole-document per
  `textDidChange`. It is reused by single-pane Edit too and is out of scope to
  rewrite here; if it remains a measurable bottleneck after D3, a follow-up can
  scope restyle to the edited paragraph range. This change targets the
  split-specific compounding (render + live JS + sync), which is what makes split
  feel worse than Edit.

### D4: Keep the oscillation guard and programmatic-scroll suppression intact
The follower's continuous follow still runs through a programmatic-scroll path
that suppresses anchor reporting (`isProgrammaticScroll` in the editor;
`suppressUntil`/`__md2FindActive`-style gating in the preview), so D1's lighter
path must still set whatever short suppression prevents the follower's own scroll
from reporting back. The difference from today is duration: a brief suppression
around the single direct scroll, not a 2.6s window.

## Risks / Trade-offs

- **Lighter follow loses async-reflow re-pinning** (math/diagram growing above the
  anchor after a follow) → Only the *mode-switch* path needs multi-second
  re-pinning; a live follow is continuously re-driven by the user's next tick, so
  a one-shot scroll is acceptable. Keep `keepPinned` for mode switches only.
- **Debounced render makes the preview trail the editor briefly** → Intended; the
  spec requires only convergence once typing settles, and the editor itself stays
  immediate. Tune the debounce so the lag is imperceptible at a normal pause.
- **Marking the editor as driver on edit could suppress a genuine preview scroll
  that races a keystroke** → The cooldown is short (~250ms) and re-armed per edit;
  a deliberate preview scroll after the user stops typing still drives the editor.
- **Smooth follow could drift from exact block alignment mid-drag** → The anchor
  model already tolerates approximate alignment; the endpoint (when the drag
  stops) still resolves to the block/source-line target.

## Migration Plan

Purely behavioral, backward compatible, no persisted data or format change.
Rollback = revert. Each fix is independently shippable and testable:
1. D3 (debounced render) — measurable typing-latency win, lowest risk.
2. D2 (edit does not drive editor) — fixes the Enter→bottom jump.
3. D1/D4 (smooth follow) — the most involved; gate behind the existing split
   sync entry points so single-pane paths are untouched.

## Open Questions

- Debounce window for D3: fixed (~120ms) vs. adaptive to document size? Start
  fixed; revisit if large documents still lag.
- For D1, is source-line + intra-block progress enough for perceived smoothness,
  or is a fraction-based follow needed during fast drags (with the block anchor
  applied only on settle)? Prototype both; prefer progress-based, fall back to
  fraction for fast flings.
- Should D2 suppress the settle `anchorChange` at the source (option 2) rather
  than rely on the driver guard, to also harden against future feedback paths?
