## Context

Edit-mode find is implemented entirely in `MarkdownEditorView.Coordinator`:

- `updateFind(query:in:)` runs on every SwiftUI update and, when the document
  text or the query changed, calls `rebuildFindIndex`.
- `rebuildFindIndex` clears all highlights, runs `TextSearch.matches` (a full
  document scan), stores `matches`/`currentMatchIndex`, re-applies a
  `.backgroundColor` temporary attribute for **every** match, then reveals the
  current match and reports "i of n".
- `revealCurrentMatch` calls `textView.setSelectedRange(matchRange)` — selecting
  the whole matched word.

Two consequences:

1. **Delete bug.** Because the revealed match is fully selected, Backspace/Delete
   removes the entire matched word (all of "abc") as one unit, even though the
   match is already visually identified by its highlight. This is the behavior
   the user reported as unreasonable.
2. **Find-mode lag.** Every keystroke in the query field synchronously re-runs
   the full search and re-paints a temporary attribute on every match, all on
   the main thread inside SwiftUI's update pass, with no debounce. Each
   `addTemporaryAttribute`/`removeTemporaryAttribute` invalidates layout for its
   range, so a query with many matches (a common single letter in a long
   document) triggers thousands of layout invalidations per keystroke.

Constraints: the text view and layout manager may only be touched on the main
actor; the coordinator already guards re-indexing with `hasMarkedText()` (IME
compositions must not be disturbed); non-GUI tests must stay headless while
GUI-gated tests use `MD2_RUN_GUI_TESTS`.

## Goals / Non-Goals

**Goals:**
- Backspace/Delete after revealing a match removes one character, never the whole
  match.
- Typing in the find query field does not stutter on large documents or queries
  with many matches.
- Keep search semantics, navigation, Replace, and Replace All behavior intact.

**Non-Goals:**
- No change to search semantics (case-/diacritic-insensitive, non-overlapping,
  wrap-around).
- No change to the find bar UI.
- No change to preview-mode find (WebKit-based, separate machinery).
- No off-main-thread search in this change (see Decisions).

## Decisions

### 1. Reveal a match with a collapsed caret at the match end

`revealCurrentMatch` will set the selection to
`NSRange(location: matchEnd, length: 0)` — a collapsed caret at the end of the
match — instead of the full match range. The orange current-match highlight
(already painted by `applyFindHighlights`) keeps the active match visually
identified, so nothing is lost. Replace still targets `matches[currentMatchIndex]`
directly rather than the selection, so Replace and Replace All are unaffected.

`revealCurrentMatch` does not move first responder: after a reveal the find
query field keeps keyboard focus, so the collapsed-caret behavior only takes
effect once the user clicks back into the editor. The spec states this focus
assumption, and the GUI test makes the editor first responder before deleting.

The caret computation is extracted into a pure, unit-testable helper in `MD2Core`
(e.g. `FindReveal.caretRange(for:)`) so the headless test suite can lock the
behavior without a window.

- *Alternative considered:* keep the whole-word selection. Rejected — it is the
  reported bug, and the spec describes a match as "highlighted", not "selected".
- *Alternative considered:* caret at the *start* of the match. Rejected — the user
  describes the caret sitting *after* the match, and typing then appends
  naturally.

### 2. Debounce query-driven re-indexing (idempotent, flush-on-command)

Wrap the expensive `rebuildFindIndex` path in a short coalescing window
(~120–150 ms) for changes driven by the query field or document text. The
debounce is **idempotent**: the `Coordinator` tracks a monotonically increasing
`findGeneration`, bumped in `textDidChange` and when the query binding changes.
`updateFind` compares generations — never whole-document string equality, which
is an O(n) trap on every SwiftUI update — and schedules only when the generation
differs from the one already pending. `lastFindQuery`/`lastIndexedText` update at
*fire* time, not schedule time, so a pending rebuild stays detectable. The work
item captures `[weak self]` (a strong capture forms a retain cycle that makes
"cancel on deinit" dead code) and is cancelled on the coordinator's lifecycle
transition.

**Immediate commands flush the pending rebuild.** `navigateFind`, Replace, and
Replace All first cancel any pending debounced work item and run
`rebuildFindIndex` synchronously for the current query/text, so they never
operate on the previous query's `matches`. This keeps them "immediate *and*
correct" rather than "immediate against a stale index". The `hasMarkedText()`
guard is re-checked at fire time and on the synchronous flush path.

- *Alternative considered:* run `TextSearch.matches` on a background queue over a
  snapshot string, then hop back to the main actor to apply highlights. Rejected
  for now — it needs snapshot consistency, stale-result cancellation, and careful
  apply ordering; debounce plus diff-based repaint (Decision 3) addresses the
  reported symptom with far less complexity. Listed as a follow-up if profiling
  still shows the single settled search is heavy.

### 3. Incremental (diff-based) highlight repaint

Track the currently painted match ranges and colors. On a rebuild:

- Compute the new match list.
- If it equals the painted set, repaint nothing; only fix the current-match color
  if `currentMatchIndex` changed.
- Otherwise remove temporary attributes only for ranges leaving the set and add
  them only for ranges entering it, then correct the current-match color.
- Navigation (index-only change) swaps exactly the two affected ranges.

This confines layout invalidation to the ranges that actually changed instead of
the whole match set. For text-edit rebuilds, the old painted ranges live in the
previous coordinate space, so they are still cleared in one pass (as today) —
the win is not re-adding untouched matches.

### 4. No behavior change to *when* a match is revealed

`revealCurrentMatch` still runs after every rebuild, exactly as today; only the
shape of the selection it sets changes. Whether editing the document under an
open find bar should stop re-revealing/moving the caret is a separate UX question
kept out of scope (see Open Questions).

### 5. Measure responsiveness with a benchmark

A GUI-gated timed benchmark (a ~1 MB document, a single-letter query) measures
the settled search plus highlight update and asserts it completes within a
generous wall-clock bound. This gives the fix a real success criterion and a
profiling tripwire for the off-main-thread follow-up, instead of the manual
smoke check alone.

## Risks / Trade-offs

- [Debounce adds a short delay before the first match highlight appears]
  → Mitigation: a 120–150 ms window is below perception; navigation and replace
  stay immediate (they flush the pending rebuild first).
- [Debounce starvation via re-entrancy]
  → Mitigation: idempotent, generation-keyed scheduling (Decision 2) — a
  reportFindResult → status change → SwiftUI re-render → updateFind cycle does
  not re-arm an unchanged pending search.
- [Retain cycle keeps the coordinator alive]
  → Mitigation: the debounced work item captures `[weak self]`; a strong capture
  would prevent `deinit`, so "cancel on deinit" never runs.
- [Collapsed caret changes type-to-replace muscle memory]
  → Mitigation: the Replace field and actions still replace the current match;
  the change is a deliberate response to the reported bug.
- [Diff-repaint state drifts after text edits]
  → Mitigation: text-change rebuilds clear the old painted set in one pass;
  query-change rebuilds diff against the painted set; a helper unit test locks
  the add/remove/unchanged cases.
- [IME/marked-text regression]
  → Mitigation: keep the existing `hasMarkedText()` guards on every path,
  including the debounced fire.
- [Selection/delete behavior is only fully verifiable in a real text view]
  → Mitigation: extract the caret computation and the match-set diff into pure
  `MD2Core` helpers for headless tests, and add a GUI-gated
  (`MD2_RUN_GUI_TESTS`) test that drives the real `NSTextView` through the
  coordinator for the delete scenario.

## Open Questions

- Should revealing be skipped (or made caret-preserving) when only the document
  text changed and the current match still exists? Today every edit under an
  open find bar re-reveals the current match, which can steal the caret. Out of
  scope for the reported bug; candidate follow-up once the debounce lands.
