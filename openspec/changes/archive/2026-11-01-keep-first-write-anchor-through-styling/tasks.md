## 1. Editor styling

- [x] 1.1 Make `MarkdownStylingController` keep the line one container inset below the viewport's top in place across each styled chunk, instead of the scroll offset.

## 2. Tests

- [x] 2.1 `testFirstSwitchToWriteLandsOnTheAnchoredLineAfterStyling`: a document opened in Read mode switches to Write on the anchored line, checked once the text is styled.
- [x] 2.2 `testPreviewNumberLowInReadModeOpensItsLineAtTheTop`: a number low in the preview opens an editor shown for the first time with that line at the top, once styled.
- [x] 2.3 Confirm both tests fail with the old styler, and the first one also fails with the viewport's top edge as the reference point.

## 3. Verification

- [x] 3.1 Run `openspec validate keep-first-write-anchor-through-styling --strict`.
- [x] 3.2 Run the non-GUI suite in CI's three steps.
- [x] 3.3 Run the whole GUI lane locally (`MD2_RUN_GUI_TESTS=1 swift test --disable-swift-testing`).
