## Why

Two find-mode behaviors are "too automated" and interrupt the user:

1. **Editing under an open find bar steals the caret.** Every document edit
   triggers a find re-index, and `rebuildFindIndex` unconditionally re-reveals
   the current match. When the user searches `abc` and backspaces the `c` out of
   the *first* match, that match disappears from the index, and the rebuild
   auto-jumps the caret to the *next* `abc` — yanking the cursor out from under
   the user mid-edit. The archived `2026-08-19-fix-find-delete-and-perf` design
   flagged exactly this as a follow-up Open Question ("a text edit under an open
   find bar re-reveals the current match, which can steal the caret").
2. **Enter advances to the next match.** The query field's `.onSubmit` calls
   "next match", so pressing Enter while the find bar is open cycles through
   matches. The user's mental model is that Enter *runs the search* (which is
   already live as they type) — not that each Enter hops to the 2nd, 3rd, n-th
   match. Repeated Enters should do nothing more than confirm the current
   search.

## What Changes

- **Document-edit rebuilds no longer move the caret or scroll.** When a find
  re-index is driven by a change to the document text (as opposed to a query
  change or an explicit ⌘G/control navigation), the highlight set and the
  "i of n" status still update, but the caret and the scroll position are
  preserved. Deleting `c` from the first `abc` no longer jumps the caret to the
  next match. Reveal intent is tracked by mutation origin, so an edit made
  while a new query's search is still debouncing also cancels the pending
  reveal (no 150 ms race window).
- **An edit that creates a match at the caret promotes it to the current
  match.** If the user's edit produces a match that ends at or contains the
  caret, that match becomes the orange current match and the status updates —
  still without moving the caret or the scroll position.
- **External content replacement re-indexes too.** A reload after the file
  changed on disk repaints find highlights at the new coordinates (fixes a
  stale-highlight bug) without moving the caret.
- **Enter in the query field no longer advances to the next match.** Return now
  confirms/runs the search for the current query — in the editor it flushes any
  pending debounced rebuild so results settle immediately — without advancing
  to the next match. On the preview, Return is a no-op: the preview search is
  already live on query change, and re-running it would jump back to match 1.
  Navigation is available only via ⌘G/⇧⌘G and the bar's up/down controls.
  Applies to both the editor and preview find bars.
- No change to ⌘G/⇧⌘G/control navigation semantics, replace/replace-all
  behavior, search semantics, or dismissal.

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities

- `document-find`: the reveal behavior of a match when the *document* changes
  under an open find bar (caret/scroll preserved; caret-created matches
  promoted; external replacement re-indexed) and the meaning of Return in the
  query field (runs the search, never advances to the next match).

## Impact

- `Sources/MD2App/MarkdownEditorView.swift` — `Coordinator`: track reveal
  intent by mutation origin (`lastFindMutationWasQueryChange`) and plumb a
  `shouldReveal` flag through `updateFind` → `scheduleFindRebuild` → the flush
  paths → `rebuildFindIndex` so document-edit rebuilds skip `revealCurrentMatch`;
  caret-match promotion in `rebuildFindIndex`; a generation bump for external
  text replacement; route the new `.search` find-command in `updateNSView`.
- `Sources/MD2App/FindCommand.swift` — new `FindCommand.Action.search`.
- `Sources/MD2App/EditorFindBar.swift` / `Sources/MD2App/PreviewFindBar.swift` —
  `.onSubmit(onNext)` → `.onSubmit(onSubmitQuery)`.
- `Sources/MD2App/ContentView.swift` — wire `onSubmitQuery` on both bars;
  exhaustive `.search` cases in the find-action handlers.
- `Sources/MD2App/MarkdownPreviewView.swift` — route `.search` in `updateNSView`
  as a no-op (the live preview search already runs on query change).
- Tests: `Tests/MD2CoreTests/` — headless no-jump-on-edit, debounce-race,
  caret-match promotion (positive + negative), replace-reveal preservation, and
  external-reload regression tests; GUI-gated (`MD2_RUN_GUI_TESTS`)
  no-jump-after-delete (with scroll assertion), editor Return-no-advance, and
  preview Return-no-advance tests.
- Spec: `document-find` — document edits and external replacement preserve the
  caret/scroll; caret-created matches promote; Return confirms the search
  without advancing.
