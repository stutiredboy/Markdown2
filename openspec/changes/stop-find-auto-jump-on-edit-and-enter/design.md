## Context

Edit-mode find lives entirely in `MarkdownEditorView.Coordinator`:

- `updateFind(query:in:)` runs on every SwiftUI update. It bumps a
  `findGeneration` when the query changes (via `lastObservedQuery`) or the
  document edits (via `textDidChange`), and schedules a debounced
  `rebuildFindIndex` (~150 ms), idempotently by generation.
- `rebuildFindIndex(query:in:preferredIndex:)` re-runs `TextSearch.matches`,
  updates `matches`/`currentMatchIndex`, repaints highlights
  (`applyFindHighlights`), then **unconditionally calls `revealCurrentMatch`**,
  which sets the collapsed caret at the match end and scrolls it into view.
- `lastFindQuery` is the last *applied* query (updated only inside
  `rebuildFindIndex`), while `lastObservedQuery` is schedule-time state.
- `updateFind` already distinguishes "new search" from "document edit" for the
  preferred index: it passes `preferredIndex: query != lastFindQuery ? 0 : currentMatchIndex`.

Two consequences the user reported:

1. **Caret theft on document edits.** A text edit bumps the generation; the
   rebuild keeps the current-match index but re-reveals it. When the edit
   removes the current match (deleting `c` from `abc`), the rebuild reveals the
   *next* match, moving the caret to it — the user is yanked away mid-edit.
   This was the archived design's Open Question.
2. **Enter advances.** Both `EditorFindBar` and `PreviewFindBar` wire
   `.onSubmit(onNext)`, so Return in the query field calls Find Next. The
   `document-find` spec currently mandates this ("submitting the query field
   with Return SHALL move to one match").

Constraints: the text view and layout manager may only be touched on the main
actor; the coordinator already guards re-indexing with `hasMarkedText()` (IME
compositions must not be disturbed); non-GUI tests stay headless while
GUI-gated tests use `MD2_RUN_GUI_TESTS`.

## Goals / Non-Goals

**Goals:**
- A document edit under an open find bar never moves the caret or scrolls; the
  highlight set and "i of n" status still update.
- An edit that creates a match at the caret promotes that match to the current
  match (orange highlight + status), still without moving the caret or
  scrolling.
- Return in the query field confirms/runs the current search without advancing;
  navigation stays on ⌘G/⇧⌘G and the bar controls, on both surfaces.
- Keep the debounce/idempotency machinery and search semantics intact.

**Non-Goals:**
- No change to ⌘G/⇧⌘G/control navigation (these still advance and reveal).
- No change to Replace / Replace All (these still reveal the next match).
- No "nearest match to the caret" tracking — matches other than the caret match
  keep their position-based semantics after an edit.
- No change to preview search internals beyond the Return routing.

## Decisions

### 1. Reveal intent tracks the mutation origin, not the last applied query

`updateFind` bumps `findGeneration` for query changes; `textDidChange` bumps it
for document edits. The coordinator records which mutation last bumped the
generation in a `lastFindMutationWasQueryChange: Bool` — set `true` in
`updateFind`'s query-change branch, `false` next to the bump in `textDidChange`.
`scheduleFindRebuild` stores that as `scheduledFindShouldReveal` and carries it
through the flush paths into `rebuildFindIndex(query:in:preferredIndex:shouldReveal:)`,
which calls `revealCurrentMatch` only when `shouldReveal` is true.
`applyFindHighlights`, `reportFindResult`, and
`appliedFindGeneration = findGeneration` stay unconditional, so the highlight
set and status stay correct without moving the caret. Replace paths call
`rebuildFindIndex` directly with `shouldReveal: true`, preserving the
"Replace locates the next match" behavior.

Rationale: comparing against `lastFindQuery` (apply-time state) leaves a
150 ms race — type a new query, click into the editor, edit before the debounce
fires, and the rebuild still sees a different applied query, reveals match 1,
and yanks the caret mid-edit. Mutation origin is O(1) state and closes the
race: an edit after a pending query change expresses "the user is editing now",
which supersedes the pending reveal. (Flagged by the cross-model review.)

- *Alternative considered:* `query != lastFindQuery` computed at schedule time.
  Rejected — the 150 ms query→edit race still reveals mid-edit; `lastFindQuery`
  only changes at apply time.
- *Alternative considered:* reveal only when the editor does not hold first
  responder. Rejected — the caret must not move regardless of focus; during
  query typing the query field owns focus anyway, and the reported bug happens
  with the editor focused.

### 2. Enter = run/confirm the search now, never advance: `FindCommand.Action.search`

Add `case search` to `FindCommand.Action`. Both bars change `.onSubmit(onNext)`
to `.onSubmit(onSubmitQuery)`. In `ContentView`, the editor's `onSubmitQuery`
sets `editorFindNavigation = FindCommand(.search)`; the preview's sets
`previewFindNavigation = FindCommand(.search)`. The `updateNSView` routings
become explicit switches (they currently infer forward from
`action != .previous`, which `.search` would misread):

- Editor `.search` → `coordinator.flushPendingFindRebuild(in:)` — runs any
  pending debounced rebuild immediately (so "Enter = search now" is
  deterministic, with no 150 ms wait right after typing), revealing only when
  the flush carries reveal intent (Decision 1). It never calls `navigateFind`.
  A settled search means a no-op.
- Preview `.search` → **no-op.** The preview search is already live on query
  change (`updateNSView` re-runs immediately, no debounce). Re-running
  `window.__md2Find` would `clearFind()` and `setCurrent(0)` with a
  `scrollIntoView` — jumping back to match 1, the same auto-jump class this
  change removes, just backward.
- `.next`/`.previous` → the existing navigation paths, unchanged.
- `.show`/`.showReplace` → no-ops here (defensive; they never reach routing).

Rationale: flushing honors the user's mental model ("Enter runs the search") and
reuses the flush path navigation already relies on, so a `search` never races a
stale match list. The preview needs no flush because its search is never
debounced.

- *Alternative considered:* `.onSubmit {}` — Enter does nothing because search
  is already live. Rejected for the editor: less faithful to "Enter triggers
  the search" and lets results lag the debounce window after a fresh query
  edit. Accepted for the preview: re-running the JS search resets the current
  match to 1 and scrolls, which the user explicitly does not want.
- *Alternative considered:* keep Enter calling `navigateFind` but make
  navigation idempotent. Rejected — conflates search with navigation; the user
  explicitly wants no advancing.

### 3. An edit that creates a match at the caret promotes it to the current match

On non-reveal rebuilds (document edits): after computing `matches` and the
position-based preferred index, if any match `M` satisfies
`M.location ≤ caret ≤ M.location + M.length` — preferring a match that ends at
the caret over one that merely contains it — set `currentMatchIndex` to `M`'s
index. There is no reveal: the caret and the scroll stay where the user's edit
left them; the orange highlight and the "i of n" status move to the match the
user just created.

Rationale: the current-match highlight should anchor to what the user is
writing. The rule is position-based on the new match list (no old-list
diffing), and non-overlapping matches make the preferred match unique; the
end-first tie-break matches the type-ahead case (caret just past the last
character typed) and is a no-op when the caret sits at a pre-existing match
boundary. Reveal-triggered rebuilds (query change, Replace, navigation) keep
their existing semantics.

### 4. External text replacement re-indexes without revealing

`updateNSView` replaces `textView.string` for bound-text/reload changes (e.g.
the file changed on disk). Programmatic replacement does not post
`NSText.didChangeNotification`, so `findGeneration` stayed put and `updateFind`
treated the stale index as applied — find highlights painted at old
coordinates after a reload. The replacement path now calls a coordinator hook
that bumps `findGeneration`; the following rebuild repaints with
`shouldReveal: false` (the reload path already clamps the selection). Removes
the dead `lastIndexedText` field (written, never read).

Rationale: the spec's new clause — "the match highlights and the match count
SHALL update to the new document text" — must hold for external replacement
too, or the clause needs a "by the user" qualifier. The hook is a few lines
and fixes a pre-existing stale-highlight bug. (Flagged by the cross-model
review.)

### 5. Spec: Return confirms, edits preserve caret/scroll, caret matches promote

`document-find` changes: the edit-mode requirement gains a clause that a
document edit under an open find bar does not move the caret or scroll (and
that the same holds for external content replacement), plus a clause and
scenario for caret-match promotion; the navigation requirement's Return clause
becomes "Return runs/confirms the current search and SHALL NOT advance to the
next match". Navigation scenarios are reworded to trigger via the
controls/⌘G only, and a scenario locks "Return does not advance".

## Risks / Trade-offs

- [The orange current-match highlight can sit on a match away from the caret
  after an edit removes the current match]
  → Partially mitigated by Decision 3 (a match at the caret promotes); still
  possible for edits away from the caret. The highlight set and status still
  update; ⌘G navigation stays consistent from that index; caret preservation is
  the requested behavior, not a regression.
- [Adding `.search` to the enum ripples through exhaustive switches]
  → Mitigation: mechanical; `.search` is unreachable from the menu, so the
  ContentView handler cases are no-ops, and the two `updateNSView` routings are
  the only real consumers.
- [Enter-flush re-entrancy / acting on a stale match list]
  → Mitigation: `flushPendingFindRebuild` is already idempotent and
  generation-keyed; a `.search` with nothing pending is a no-op.
- [Promotion ambiguity (match ending at the caret vs. containing it)]
  → Mitigation: non-overlapping matches make the candidate unique; the
  end-first tie-break is explicit and tested.
- [Scroll suppression is only fully verifiable in a real view]
  → Mitigation: headless tests lock the caret; skipping `revealCurrentMatch`
  removes the programmatic scroll by construction; the GUI-gated test drives
  the real delete path and asserts the clip-view origin after the rebuild
  settles (the edit viewport-restore timers run out to ~2.2 s, so the
  assertion waits past them).

## Open Questions

- Resolved during review: whether a document edit that *creates* a match at
  the caret promotes it to the current match — in scope (Decision 3), per
  review decision. No open questions remain.

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 1 | INFORMATIONAL | 5 findings; 2 tensions accepted (reveal-intent race → Decision 1; external reload → Decision 4) |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR | 4 issues, 0 critical gaps; all folded into the plan (preview Return no-op, GUI Return guards, replace-reveal + promotion + race + external-reload regression tests) |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

**CROSS-MODEL:** Claude review and Codex outside voice agreed on the preview
Return reset and the missing automated guards; disagreed (then converged, user
accepted the outside voice) on reveal-intent tracking and external-reload
re-indexing.

**VERDICT:** ENG CLEARED — ready to implement.
NO UNRESOLVED DECISIONS
