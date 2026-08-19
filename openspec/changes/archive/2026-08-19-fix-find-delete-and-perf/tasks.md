## 1. Fix delete-after-reveal behavior

- [x] 1.1 Add a pure helper in `MD2Core` (e.g. `FindReveal.caretRange(for:)`) that
      computes the reveal selection for a match: a collapsed caret at the end of
      the match range. Unit-test it in `Tests/MD2CoreTests/` (end-of-match,
      empty-match edge, zero-length query, match at end of string).
- [x] 1.2 In `MarkdownEditorView.Coordinator.revealCurrentMatch`, replace
      `textView.setSelectedRange(matchRange)` with the collapsed caret from the
      helper; keep the current-match highlight and scroll-into-view unchanged.
- [x] 1.3 Add a headless `@MainActor` test (pattern from
      `MarkdownEditorIMERegressionTests`) that runs `updateFind(query:in:)` on a
      real `NSTextView` and asserts the selected range is collapsed at the end of
      the first match (not the whole match).
- [x] 1.4 Add a GUI-gated (`MD2_RUN_GUI_TESTS`) test that reveals a match, makes
      the editor first responder (so the query field no longer owns focus), then
      simulates Backspace (`deleteBackward(nil)`) and asserts exactly one
      character is removed rather than the whole match. Run the GUI suite
      locally (`MD2_RUN_GUI_TESTS=1 swift test --filter <new test>`).
- [x] 1.5 Add a manual-run note to `CLAUDE.md`'s Testing section for the
      GUI-gated delete test (mirror the PDF/print load-bearing-note pattern),
      since `swift test` and CI skip it.

## 2. Debounce query-driven re-indexing (idempotent, flush-on-command)

- [x] 2.1 Add a monotonic `findGeneration` to the `Coordinator`, bumped in
      `textDidChange` and on query binding change. `updateFind` compares
      generations (not whole-document string equality) and schedules only when
      the generation differs from the pending one.
- [x] 2.2 Add a `@MainActor` idempotent debounce (a `DispatchWorkItem` armed with
      `asyncAfter`, ~120–150 ms) around the `rebuildFindIndex` path. The work
      item captures `[weak self]`; `lastFindQuery`/`lastIndexedText` update at
      fire time, not schedule time.
- [x] 2.3 Flush the pending rebuild in `navigateFind`, `replaceCurrent`, and
      `replaceAll`: cancel any pending work item and run `rebuildFindIndex`
      synchronously for the current query/text before using `matches`, so
      navigation/replace never act on a stale match list.
- [x] 2.4 Re-check the `hasMarkedText()` guard at fire time and on the
      synchronous flush path; cancel any scheduled work on the coordinator's
      lifecycle transition (not only `deinit`).
- [x] 2.5 Verify `updateFind` no longer runs a full search per query keystroke
      (manual check and existing non-GUI suite).

## 3. Incremental highlight repaint

- [x] 3.1 Add a pure match-set diff helper in `MD2Core` (added / removed /
      unchanged ranges, plus the current-index color swap) and unit-test it,
      covering empty→nonempty, nonempty→empty, disjoint, overlapping/unchanged,
      and the old-current == new-current (single match) case.
- [x] 3.2 Track the painted match ranges and current-match color in the
      `Coordinator`; on navigation swap exactly the previous and new current
      ranges' colors instead of re-painting all matches.
- [x] 3.3 In `rebuildFindIndex`, diff the new matches against the painted set:
      when the set is unchanged, repaint nothing except a current-match color fix
      if `currentMatchIndex` changed (e.g. a case-only query change); otherwise
      remove temporary attributes only for leaving ranges and add only for new
      ranges; keep clearing the old painted set in one pass on text-edit rebuilds
      (coordinate shift).
- [x] 3.4 Update `clearFindHighlights` to only remove attributes it actually
      painted, keeping `highlightedRanges` consistent.

## 4. Regression, benchmark, and verification

- [x] 4.1 Run `swift test` (non-GUI) — existing `TextSearchTests` and the new
      helpers/selection/diff tests pass.
- [x] 4.2 Run the GUI suite
      (`MD2_RUN_GUI_TESTS=1 swift test --filter <new tests> --filter MarkdownEditorIMERegressionTests`)
      and confirm the delete-after-reveal and IME regressions pass.
- [x] 4.3 Add a GUI-gated responsiveness benchmark: a ~1 MB document with a
      single-letter query; time the settled search + highlight update and assert
      it completes within a generous wall-clock bound. Use a conservative
      threshold (this is a regression tripwire, not a flaky timer).
- [x] 4.4 Manual smoke: in a large document, search a common single letter and
      confirm find-box typing stays smooth; reveal a match, click into the
      editor, and confirm Backspace deletes exactly one character.
