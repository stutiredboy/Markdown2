## 1. Lock the bug with failing tests

- [x] 1.1 In `Tests/MD2CoreTests/MarkdownRendererTests.swift`, add a failing test: a blank-line-separated ordered list (`1. first` / blank / `2. second` / blank / `3. third`) renders as one `<ol>` with three `<li>` in order, not three separate lists.
- [x] 1.2 Add a failing test: an ordered item with 3-space marker-aligned bullets (`1. first` then `   - detail a` / `   - detail b` then `2. second`) nests the bullets in a `<ul>` under `first` and renders `second` as the second `<li>` of one `<ol>`.
- [x] 1.3 Add a failing test mirroring the `## 6. 管理启示` shape: several numbered items, each separated by a blank line and carrying 3-space nested bullets, render as a single `<ol>` with continuous numbering and nested `<ul>` children.

## 2. Marker-aware nesting step (Decision B)

- [x] 2.1 Replace the absolute `indent / 4` logic in `nestingLevels(for:)` (MarkdownRenderer.swift:446) with a stack of enclosing-level indentations: open a deeper level only when an item's indent is ≥ 3 columns greater than the enclosing level's indent; close levels when the indent drops below a level's indent.
- [x] 2.2 Confirm `buildList` consumes the new per-item `levels` array unchanged (siblings / nested children / kind-change break still driven by `levels`).
- [x] 2.3 Make test 1.2 pass; verify the existing nesting tests still pass (`nestsIndentedUnorderedListItems`, `nestsMultipleLevelsOfLists`, `tabIndentedListItemNestsOneLevel`, `twoSpaceIndentedListItemStaysAtCurrentFourSpaceLevel`, `dedentClosesNestedListAndContinuesParent`, `nestsOrderedListUnderUnorderedItem`, `nestedTaskListItemsKeepCheckboxes`).

## 3. Loose-list continuity (Decision A)

- [x] 3.1 Update the collect loop in `listBlock` (MarkdownRenderer.swift:432) so a blank line is absorbed when the next non-blank line is itself a list item; stop when the next non-blank line is not a list item (or input ends).
- [x] 3.2 Record each collected item's raw `lines` index, and compute `listBlock`'s returned `nextIndex` from `built.next` via that recorded index (first unconsumed item's line, or the loop's stop index when all items were consumed) so the top-level walk resumes on the correct line.
- [x] 3.3 Keep `<li>` rendering tight — items collected across a blank line emit `<li>content</li>` with no `<p>` wrapping. Make tests 1.1 and 1.3 pass.

## 4. Regression and verification

- [x] 4.1 Run `swift test` (MD2Core suite) and confirm the full suite is green, including source-line-metadata and mode-switch-anchoring tests for blocks following a loose list.
- [x] 4.2 Run `openspec validate fix-ordered-list-numbering` and confirm it passes.
- [x] 4.3 Build/run the app, open `案例4-A园艺工具事业部供应链综合计划-参考答案.md`, scroll to `## 6. 管理启示`, and confirm the preview shows ordered markers `1.`–`6.` with nested bullets under each (no marker resets to `1.`).
