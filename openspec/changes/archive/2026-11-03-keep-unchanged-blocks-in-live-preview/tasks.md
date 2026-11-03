## 1. Live update

- [x] 1.1 Key the top-level nodes of `<main>` and keep unchanged ones in `__md2ApplyContent`, syncing their line attributes.
- [x] 1.2 Send the loaded body with the first update after a load, and key the loaded nodes from it.
- [x] 1.3 Fall back to replacing everything when the page cannot be keyed or the appearance changed.

## 2. Rendering

- [x] 2.1 Let `__md2RenderMath` and `__md2RenderDiagrams` take an array of roots, including roots that match.
- [x] 2.2 Keep each formula's TeX and record whether the document defines macros.
- [x] 2.3 Give each local image file a stable token.

## 3. Math macros

- [x] 3.1 Add `mathMacros` to `RenderedDocument` and pass it to the preview.
- [x] 3.2 Re-render every formula when the macros change or definitions are involved.

## 4. Tests

- [x] 4.1 `IncrementalPreviewGUITests` for node identity, line attributes, images, macros, definitions and fallbacks.
- [x] 4.2 Unit tests for `mathMacros` and image tokens.

## 5. Verification

- [x] 5.1 Run `openspec validate keep-unchanged-blocks-in-live-preview --strict`.
- [x] 5.2 Run the non-GUI suite in CI's three steps.
- [x] 5.3 Run the full GUI lane locally (`MD2_RUN_GUI_TESTS=1 swift test --disable-swift-testing`) and the skip check.
- [x] 5.4 Confirm each new GUI test fails on a mutation: a whole-page replacement, dropped macros, an ignored loaded body, or keys cut from the string.
