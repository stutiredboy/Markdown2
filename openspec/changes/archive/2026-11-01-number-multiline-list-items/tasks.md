## 1. Renderer

- [x] 1.1 Stamp every regular list item in `buildList` with its start line, and its end line when it spans several.

## 2. Preview gutter

- [x] 2.1 Number the multi-line items of top-level lists, skip items inside quotes and alerts, number each line once, and sort numbers by position.

## 3. Tests

- [x] 3.1 `MetadataInvariantTests`: every corpus list item carries a start line; exact spans for nested and continued items.
- [x] 3.2 `LineNumberGutterGUITests`: multi-line items numbered at their tops, quoted and alerted items skipped, no duplicate; an item's number sends its line on click.
- [x] 3.3 `ReadingImprovementsGUITests`: a Read → Write switch lands on the list item at the top of the preview.
- [x] 3.4 Read nesting assertions through `withoutSourceLineMetadata`, pin the exact attributes in `droppingAMarkerKeepsTheJoinerAfterIt`, and make the indented-dash assertion check that no `<li` exists.
- [x] 3.5 Confirm the new tests fail with bare `<li>` and without the quote/alert skip.

## 4. Verification

- [x] 4.1 Run `openspec validate number-multiline-list-items --strict`.
- [x] 4.2 Run the non-GUI suite in CI's three steps.
- [x] 4.3 Run the gutter and reading GUI suites locally.
- [x] 4.4 Compare `swiftc -O` probes with and without this change, and time list-heavy input (results in `design.md`).

## 5. Docs

- [x] 5.1 Mention list items in both READMEs' line-number feature.
- [x] 5.2 Remove the list-item item from `TODOS.md`.
