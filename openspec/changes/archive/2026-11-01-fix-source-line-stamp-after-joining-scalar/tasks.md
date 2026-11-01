## 1. Renderer

- [x] 1.1 Find the end of a block's opening tag in `taggedWithSourceLines` by searching `html.utf8` for `>`.

## 2. Tests

- [x] 2.1 Add `blockStartingWithJoiningScalarKeepsSourceLineOnItsTag` (U+0301, U+200D, U+FE0F, U+093F; paragraph, multi-line paragraph, blockquote paragraph, heading) to `MetadataInvariantTests`; confirm it fails against `main`.
- [x] 2.2 Add `testParagraphStartingWithCombiningMarkIsNumbered` to `LineNumberGutterGUITests`; confirm it fails against `main` (the gutter shows only the second paragraph).

## 3. Verification

- [x] 3.1 Run `openspec validate fix-source-line-stamp-after-joining-scalar --strict`.
- [x] 3.2 Run the full non-GUI suite with `swift test`, in the same three steps as CI.
- [x] 3.3 Run `MD2_RUN_GUI_TESTS=1 swift test --filter EditorLineNumberGutterGUITests --filter LineNumberGutterGUITests`.
- [x] 3.4 Compare `swiftc -O` probes with and without this change: byte-identical on every repository and local Markdown document and every CommonMark/GFM example; every differing generated input differs only in stamp placement (`design.md`).

## 4. Docs

- [x] 4.1 Remove the source-line item from `TODOS.md`, and record the block-marker and link-bracket grapheme issue.
