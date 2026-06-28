## Context

The app currently presents a document in exactly one of two surfaces at a time:
`MarkdownEditorView` (an `NSTextView` in an `NSScrollView`) for Edit, and
`MarkdownPreviewView` (a `WKWebView`) for Preview. `ContentView` holds a single
`@State mode: EditorMode` (`.write` / `.read`) and renders one surface via a
`switch`. Mode switches capture a `ViewportAnchor` from the outgoing surface and
hand it to the incoming one through `DocumentStore.editorJumpAnchor` /
`previewJumpAnchor`, so the user lands where they were.

Two pieces of existing machinery are directly reusable for Side by Side:

- **Anchoring model** — `ViewportAnchor` + the block/source-line metadata in the
  rendered HTML, with heading and proportional fallbacks. The editor reports its
  top visible line continuously via `onAnchorLineChange` (debounced through
  `boundsDidChange`), and the preview reports `onAnchorChange`; both expose a
  live `currentAnchor` reader. Both surfaces already guard against feedback with
  an `isProgrammaticScroll` flag and a settle loop (`applyAnchorUntilSettled`,
  `performProgrammaticScroll`).
- **Render pipeline** — `DocumentStore.text` re-renders into `rendered.html` on
  every change; the preview observes that HTML.

The friction point: `MarkdownPreviewView.updateNSView` currently does a **full
`load(html…)`** whenever `html` changes. That tears down and reparses the whole
page (re-executing the inlined KaTeX/Mermaid engines, which can block JS for
seconds). Acceptable once per mode switch; unacceptable on every keystroke in a
live split.

## Goals / Non-Goals

**Goals:**
- Add a `split` ("Side by Side") presentation mode: editor left, live preview
  right, both interactive at once.
- Live preview updates on edit **without** full-page reload flashing and
  **without** losing the preview's scroll position.
- Bidirectional, jitter-free scroll alignment between the panes, reusing the
  existing anchor model.
- Side by Side selectable from the toolbar and both Settings pickers, fully
  localized (EN + zh-Hans).

**Non-Goals:**
- Changing the on-disk format or the render output itself.
- A configurable/persisted split ratio across launches (a session-local
  draggable divider is enough for v1).
- Three-pane or multi-window split, or per-pane independent documents.
- Reworking the single-pane mode-switch anchoring (it stays as-is; Side by Side
  layers on top of the same primitives).

## Decisions

### D1: `split` as a third `EditorMode` case (not an orthogonal toggle)
Add `case split` to `EditorMode`. The proposal, the existing
`document-presentation-mode` spec, the toolbar picker, and both Settings pickers
all already pivot on a single mode value, and the user asked for a third *setting
item alongside* Edit/Preview. A third enum case threads through all of them with
no new state axis.
- *Internal raw value* `split`; *display name* "Side by Side" / 「双栏」. This
  mirrors the existing `write`→"Edit" / `read`→"Preview" split between identifier
  and label, so persistence (`AppSettings` already stores `rawValue` strings) and
  i18n stay cleanly separated.
- *Alternative considered*: a separate `showsPreviewAlongside` boolean orthogonal
  to mode. Rejected — it doubles the state space (Edit+split? Preview+split?) for
  no benefit and complicates the persisted preferences the spec defines.

### D2: Split layout reuses both existing surfaces unchanged
`ContentView.editorSurface` gains a `.split` branch that places
`MarkdownEditorView` and `MarkdownPreviewView` in a horizontal split with a
draggable divider (SwiftUI `HSplitView`, or an `HStack` + `Divider` with a
width-fraction `@State` + `DragGesture` if `HSplitView` proves too rigid). Both
views are already `NSViewRepresentable` and parameterized by bindings, so no
changes to their internals are required to host two of them at once.
- The window `minWidth` rises in split mode (two usable panes need more room than
  780pt); enforce a per-pane minimum so neither collapses.
- The outline sidebar and status bar stay outside the split, as today.

### D3: Live preview via incremental content swap, not full reload (the core change)
In split mode the preview must update without the `load(html…)` teardown. Replace
the keystroke path with an **in-place content update**: keep the page shell
loaded and, on text change, push only the rendered body into the existing DOM
(e.g. a `window.md2ApplyContent(html)` JS hook that sets the content
container's `innerHTML` and re-runs KaTeX/Mermaid over the new subtree), instead
of calling `load`. Because the document/scroll node is never torn down, the
preview's scroll position is naturally preserved across updates.
- **Debounce** the content push (the renderer runs on every keystroke; the DOM
  swap should coalesce to ~animation-frame / short idle) to keep typing smooth.
- After each swap, re-affirm the alignment anchor (D4) so newly-tall async
  content — math/diagrams — doesn't drift the viewport.
- *Phase fallback*: if the in-place swap is too invasive for v1, a debounced
  full `load` that captures `currentAnchor` before and re-applies it after the
  reload meets the spec's "preserve scroll position" requirement, at the cost of
  more flashing. Prefer the in-place swap; keep this as the safety net.
- *Why not keep full reload always*: re-executing the inlined engines per
  keystroke violates the "no whole-document flashing" scenario and burns CPU.

### D4: Bidirectional scroll sync with a single live "driver"
Treat whichever pane the user is actively scrolling/editing as the **driver** and
the other as the **follower**. The driver's existing live anchor callback
(`onAnchorLineChange` for the editor, `onAnchorChange` for the preview) feeds the
follower's jump anchor (`previewJumpAnchor` / `editorJumpAnchor`), which the
follower already knows how to apply.
- **Loop-breaking**: the follower's programmatic scroll runs through the existing
  `performProgrammaticScroll` / `applyAnchorUntilSettled` paths, which already set
  `isProgrammaticScroll` and suppress anchor reporting while settling — so the
  follower can't bounce the driver back. Add a short "who drove last" guard
  (timestamp/owner token in `ContentView`) so a follower's settle-time report
  isn't mistaken for a new user scroll.
- **Continuous, not once-per-switch**: this is the only behavioral change to the
  data flow — the same anchors that fire once at switch time now fire throughout
  the session while in split mode. Debounce the editor's `boundsDidChange`
  reporting if needed to keep the follower from thrashing.
- *Alternative considered*: a brand-new line↔pixel-offset sync table. Rejected —
  the block/source-line `ViewportAnchor` already maps both directions and handles
  long code blocks, sparse headings, and async-tall content via
  `intraBlockProgress` + fallbacks.

### D5: Find / outline / task routing in split
- **Find** targets the focused pane. `ContentView.handleFindCommand` currently
  switches on `mode`; in split it switches on a `@State focusedPane` (editor vs.
  preview) updated from each surface's focus, defaulting to the editor.
- **Outline** jump sets both `jumpLine`/`editorJumpAnchor` and
  `jumpHeadingID`/`previewJumpAnchor` so both panes move (the bindings already
  exist; today only one surface consumes them).
- **Task toggle** already captures the preview anchor before the re-render and
  re-applies it; in split it must additionally not disturb the editor pane (the
  edit comes from `DocumentStore.toggleTask`, which the editor reflects in place).

### D6: Settings, toolbar, and i18n
- Toolbar `Picker` gains a third segment (`Image(systemName: …).tag(.split)`),
  e.g. `square.split.2x1` / `rectangle.split.2x1`. Width grows from 92pt.
- Both Settings `Picker`s gain a Side by Side segment; segmented control with
  three text labels stays legible.
- New `L10nKey` cases (e.g. `sideBySide`, and a help string such as
  `writeReadOrSplit` superseding `writeOrRead`) added to both the `english` and
  `zhHans` tables — `sideBySide` = "Side by Side" / 「双栏」. `AppSettings`
  persistence needs no change since it stores `EditorMode.rawValue`.

## Risks / Trade-offs

- **Per-keystroke preview cost / flashing** → Incremental content swap (D3) keeps
  the page shell and re-runs engines only over changed content; debounce
  coalesces bursts. Fallback full-reload path is gated behind the same anchor
  preserve/restore used at switch time.
- **Scroll-sync oscillation (A drives B drives A…)** → Single-driver model plus
  the existing `isProgrammaticScroll` suppression and a "last driver" guard; the
  follower reports its settled position only once, and that report is ignored as
  a driver event.
- **Alignment drift on async-tall content (KaTeX/Mermaid)** → Re-affirm the
  follower anchor after the content swap settles (same re-apply-on-`didFinish`
  pattern the preview already uses), accepting that alignment is approximate
  mid-render and converges once layout stabilizes.
- **Two live heavy surfaces (NSTextView + WKWebView) at once** → Only one preview
  WKWebView per window (the split pane *is* the preview); the cost is comparable
  to Preview mode plus the editor, both of which already exist. Watch memory on
  many open windows.
- **Narrow windows** → Raise split-mode `minWidth` and clamp the divider so
  neither pane becomes unusable; users on small screens can still pick Edit or
  Preview.

## Migration Plan

Purely additive and backward compatible. The default new-document mode stays
Edit; existing saved Edit/Preview preferences resolve unchanged. No persisted
data migration. Rollback = revert the change; any preference that happens to hold
`split` falls back to the enum's default (`.write`) via the existing
`EditorMode(rawValue:) ?? .write` guard, so an old build tolerates a `split`
value gracefully.

## Open Questions

- Should the split ratio (and which pane is "primary") persist across launches,
  or is session-local sufficient for v1? (Design assumes session-local.)
- Should the editor pane also scroll-drive when the user is *typing* (caret
  position) and not just scrolling — i.e. follow the caret into the preview?
  (Default: sync on scroll; caret-follow is a possible enhancement.)
- Icon choice for the toolbar segment — `square.split.2x1` vs.
  `rectangle.split.2x1` vs. `sidebar.squares.right`.
