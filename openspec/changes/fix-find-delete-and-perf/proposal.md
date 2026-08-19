## Why

In edit mode, revealing a find match selects the *entire* matched word
(`Coordinator.revealCurrentMatch` calls `setSelectedRange(matchRange)`), so
pressing Delete/Backspace removes the whole match — all of "abc" — instead of a
single character. The match is already visually identified by its highlight, so
a full-word selection is unnecessary and surprising. Separately, find-mode
interaction is sluggish: every keystroke in the query field synchronously
re-scans the whole document and re-paints a background attribute on *every*
match, with no debounce — on large documents or common queries this visibly
stutters.

## What Changes

- **Reveal a match without selecting the whole word**: when a find match is
  brought into view (initial search, ⌘G/⇧⌘G navigation, Return in the query
  field), place a collapsed caret at the *end* of the match instead of selecting
  the full match range. The current-match highlight (orange) continues to
  identify the active match. Delete/backspace then removes exactly the character
  before the caret. The reveal does not move first responder: the find query
  field keeps focus until the user clicks back into the editor (the spec states
  this focus assumption).
- **Debounce query-driven searches**: coalesce rapid query-field edits into a
  single re-index with an *idempotent*, generation-keyed debounce, so typing in
  the find bar does not run a full search plus highlight rebuild per keystroke
  (nor starve the search via SwiftUI re-render re-entrancy). Navigation, Replace,
  and Replace All stay immediate — they flush any pending rebuild first so they
  never operate on the previous query's matches.
- **Incremental highlight updates**: stop clearing and re-adding a background
  attribute for every match on every rebuild. Only repaint ranges whose match
  membership actually changed; navigation swaps the current-match color on just
  the two affected ranges.
- **Measure it**: add a GUI-gated responsiveness benchmark (large document,
  single-letter query) that bounds the settled search plus highlight update.
- No change to search semantics (case- and diacritic-insensitive, non-overlapping
  wrap-around), no change to preview-mode find, and no change to replace
  behavior.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `document-find`: the reveal behavior of a match (collapsed caret at the match
  end instead of whole-word selection) and a responsiveness guarantee for
  find-mode query entry and navigation.

## Impact

- `Sources/MD2App/MarkdownEditorView.swift` — `Coordinator.revealCurrentMatch`,
  `applyFindHighlights`, `clearFindHighlights`, `rebuildFindIndex`, `updateFind`,
  `navigateFind`; new idempotent debounce scheduling and flush-on-command.
- `Sources/MD2App/MarkdownTextStyler.swift` — no change expected (find highlights
  are temporary attributes applied through the layout manager, independent of the
  base styling).
- `Sources/MD2Core/TextSearch.swift` — API unchanged; add a regression guard for
  dense-match inputs.
- `Sources/MD2Core` — new pure helpers (reveal caret computation, match-set diff)
  so the logic is unit-testable without an AppKit window.
- Tests: `Tests/MD2CoreTests/` — new/updated unit tests; a GUI-gated
  (`MD2_RUN_GUI_TESTS`) test for the real delete-after-reveal path and a
  responsiveness benchmark.
- `CLAUDE.md` — a manual-run note for the GUI-gated delete/benchmark tests
  (mirroring the PDF/print note), since `swift test` and CI skip them.
- Spec: `document-find` gains the focus-assumption clause on the Backspace
  scenario and the flush-before-navigation guarantee.
