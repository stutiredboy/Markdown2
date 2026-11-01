## 1. Editor

- [x] 1.1 Add `sourceLineRange(forLine:in:)` and `sourceLineRange(containing:in:)`, numbering lines as the gutter does.
- [x] 1.2 Handle gutter clicks in `MarkdownSourceTextView.mouseDown`: select the line, extend it with Shift, and extend it line by line while dragging. Fall back to `super` when numbers are hidden or marked text is pending.
- [x] 1.3 Add the `lineSelection` binding: apply each request once, hold it until a settling anchor finishes, then clear it.

## 2. Preview and routing

- [x] 2.1 Make gutter spans clickable, and add the isolated-world listener and the `revealSourceLine` handler.
- [x] 2.2 Route the line in `ContentView`: select in place in Side by Side; open Write mode on the line from Read mode.

## 3. Tests

- [x] 3.1 Add `MarkdownEditorSourceLineRangeTests`.
- [x] 3.2 Add the editor click tests to `EditorLineNumberGutterGUITests`.
- [x] 3.3 Add the preview click test to `LineNumberGutterGUITests`, and assert page scripts cannot see `revealSourceLine` in `PreviewSecurityGUITests`.
- [x] 3.4 Add the end-to-end test to `ReadingImprovementsGUITests` (Read and Side by Side).
- [x] 3.5 Run the mutation checks listed in `design.md`.

## 4. Verification and docs

- [x] 4.1 Run `openspec validate add-gutter-click-to-jump --strict`.
- [x] 4.2 Run the full non-GUI suite in CI's three steps, and the full GUI lane (`MD2_RUN_GUI_TESTS=1 swift test --disable-swift-testing`) with `Scripts/check_test_skips.py`.
- [x] 4.3 Update `README.md` and `README.zh-CN.md`, and remove the TODO.
