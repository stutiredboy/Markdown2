## 1. Suppress reveal on document-edit-driven rebuilds (mutation-origin intent)

- [x] 1.1 In `MarkdownEditorView.Coordinator`, add `lastFindMutationWasQueryChange: Bool` (default `true`): set it `true` in `updateFind`'s query-change branch (next to the `findGeneration += 1`), `false` in `textDidChange` next to its generation bump (never inside the marked-text early return). Compute `shouldReveal` from it in `updateFind` and carry it through the scheduled-rebuild state: add `scheduledFindShouldReveal: Bool?`, set it in `scheduleFindRebuild`, clear it alongside `scheduledFindQuery` in both flush paths, and read it (`?? true`) in `flushScheduledFindRebuild` and `flushPendingFindRebuild`.
- [x] 1.2 Thread the flag through `performFindRebuild` into `rebuildFindIndex(query:in:preferredIndex:shouldReveal:)`; call `revealCurrentMatch` only when `shouldReveal` is true, keeping `applyFindHighlights`, `reportFindResult`, and `appliedFindGeneration = findGeneration` unconditional. Extract the query-changed predicate into one local so `preferredIndex` and `shouldReveal` cannot drift.
- [x] 1.3 Update the direct callers — `replaceCurrent` and `replaceAll` — to pass `shouldReveal: true` so Replace / Replace All still locate the next match.
- [x] 1.4 Promotion (Decision 3): in `rebuildFindIndex`, when `shouldReveal` is false and a match `M` satisfies `M.location <= caret <= M.location + M.length` (prefer a match ending at the caret over one merely containing it), set `currentMatchIndex` to `M`'s index before `applyFindHighlights`. Caret = `textView.selectedRange().location`. No reveal, no scroll.
- [x] 1.5 External replacement (Decision 4): in `updateNSView`'s text-replacement path (`textView.string = text` for reload/bound-text changes), call a new coordinator hook (e.g. `noteExternalTextChange()`) that bumps `findGeneration` so the next `updateFind` re-indexes with `shouldReveal: false`. Delete the dead `lastIndexedText` field.
- [x] 1.6 Headless regression tests (pattern from `FindEditRebuildRegressionTests`; caret set via `textView.setSelectedRange`):
  - no-jump-on-edit: search "abc" in "abc abc abc", simulate deleting the trailing "c" of the first match (`textView.string = "ab abc abc"`, caret at 2), fire `textDidChange`, then `updateFind(query: "abc")` + `flushPendingFindRebuild`; assert the caret stays at 2 (not 6) and the new match at 3..<6 is highlighted.
  - race: search "abc" (applied), change the query to "ab" (schedules `shouldReveal: true`), then fire `textDidChange` for an edit and `updateFind(query: "ab")` + flush before any debounce fires; assert the caret does not move (the edit superseded the pending reveal).
  - promotion-positive: with "abc" applied at 0..<3, insert " abc" at the caret so a new match 4..<7 ends at the caret (7); flush; assert `currentMatchIndex` is the new match and the caret is still at 7 (no reveal).
  - promotion-negative: edit the document at a spot that creates no caret match; assert the current-match index keeps position-based semantics and the caret does not move.
  - replace-reveal: `replaceCurrent` (and `replaceAll`) still reveal the next/first match — caret at the revealed match end after the replace rebuild.
  - external-reload: apply "abc" in "abc abc", replace `textView.string` with "abc xyz abc" via the reload path + `noteExternalTextChange`, run `updateFind` + flush; assert highlights repaint at the new coordinates and the caret is not yanked.
- [x] 1.7 GUI-gated tests in `FindFindDeleteGUITests`:
  - no-jump-after-delete (key window, editor first responder, `deleteBackward`, then run the rebuild the way `updateNSView` would): assert the caret does not jump to the next match, and — after waiting past the edit viewport-restore cascade (~2.2 s) — assert the clip-view origin is unchanged by the re-index.
  - editor Return-no-advance: multi-match query settled, focus the query field, press Return twice; assert the current match index never advances and results are immediate (no pending debounce left behind).
  - preview Return-no-advance: preview find bar with a multi-match query, navigate to match 2, press Return; assert the preview stays on match 2 (scroll and status unchanged — the `.search` routing is a no-op).

## 2. Enter no longer advances to the next match

- [x] 2.1 Add `case search` to `FindCommand.Action` in `Sources/MD2App/FindCommand.swift`.
- [x] 2.2 In `EditorFindBar` and `PreviewFindBar`, add an `onSubmitQuery: () -> Void` closure and change the query field from `.onSubmit(onNext)` to `.onSubmit(onSubmitQuery)`.
- [x] 2.3 In `ContentView`, wire `onSubmitQuery` on both bars (`editorFindNavigation = FindCommand(.search)` / `previewFindNavigation = FindCommand(.search)`) and add exhaustive `.search` no-op cases to `handleEditorFindAction` and `handlePreviewFindAction` (the menu cannot produce `.search`).
- [x] 2.4 In `MarkdownEditorView.updateNSView`, replace the `navigateFind(forward: findNavigation.action != .previous)` line with an explicit switch: `.next`/`.previous` navigate as today; `.search` calls `coordinator.flushPendingFindRebuild(in: textView)` (never `navigateFind`); `.show`/`.showReplace` are no-ops here.
- [x] 2.5 In `MarkdownPreviewView.updateNSView`, switch on the action: `.search` is a no-op (the live query-change path already re-runs the search; re-running `__md2Find` would reset the current match to 1 and scroll — leave a comment saying so); `.next`/`.previous` navigate; `.show`/`.showReplace` are no-ops.
- [x] 2.6 Manual smoke: search a multi-match query, press Return twice in the query field — results appear immediately and the caret never advances to a later match; navigate to match 2 in the preview and press Return — the preview stays put; ⌘G/⇧⌘G and the chevron buttons still navigate.

## 3. Spec delta

- [x] 3.1 Update `specs/document-find/spec.md`: the edit-mode requirement keeps the no-caret-move/no-scroll clause (now also covering external content replacement) and gains the caret-match promotion clause + scenario; the navigation requirement's Return clause reads "Return runs/confirms the current search and SHALL NOT advance to the next match", navigation scenarios trigger via controls/⌘G only, and the "Return confirms the search without advancing" scenario stays (it covers both surfaces).

## 4. Verification

- [x] 4.1 Run `swift test` (non-GUI) — existing find tests (`TextSearchTests`, `FindDeleteRegressionTests`, `FindEditRebuildRegressionTests`, `FindRevealTests`, `FindHighlightDiffTests`) plus the new 1.6 tests pass.
- [x] 4.2 Run the GUI suite `MD2_RUN_GUI_TESTS=1 swift test --filter FindFindDeleteGUITests` locally — the new 1.7 tests and the existing delete/benchmark tests pass (required before landing; `swift test` and CI skip these).
- [x] 4.3 Manual end-to-end: search `abc` in a document containing `abc abc`, click into the editor at the first match, backspace the `c` — the caret stays put and does not jump to the second `abc`; type ` abc` at the caret — the new match becomes the orange current match without the caret moving; press Return in the query field twice — no advance; in the preview navigate to match 2 and press Return — stays on match 2.
