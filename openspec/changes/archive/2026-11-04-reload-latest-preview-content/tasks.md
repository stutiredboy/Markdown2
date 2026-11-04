## 1. Preview

- [x] 1.1 In `decidePolicyFor`, ahead of the link router, cancel a main-frame `.reload` and call `reloadLatestContent(in:)`.
- [x] 1.2 Add `reloadLatestContent(in:)`: capture the reader's place, then run a load of `lastHTML` with `beginLoading`, `loadedBody` and the open search.
- [x] 1.3 Drop the comment in `didFinish` that gave the Reload as its reason.

## 2. Tests

- [x] 2.1 Add `HeldPreview.reload()`, a find query and the anchors the page reports.
- [x] 2.2 `testReloadAfterALiveEditShowsTheNewestTextAndItsBoxesWork`: the newest text, its label and a working checkbox.
- [x] 2.3 `testReloadWithNoEditKeepsTheBoxesWorking`: the label with no edit, in Read mode.
- [x] 2.4 `testReloadKeepsTheReadersPlace`: the place, and no report of the top of the page.
- [x] 2.5 `testEditAfterAReloadKeepsTheBlocksItDidNotChange`: the first live update on the new page.
- [x] 2.6 `testReloadRunsTheSearchAgain`: the marks on the new page.
- [x] 2.7 `testReloadDuringALoadStillLandsTheNewestText`: a Reload with a load held at its policy decision.
- [x] 2.8 Rename `testAReloadNoLoadStartedStillFinishes` to `testAReloadFinishesLikeAnyLoad`.
- [x] 2.9 Confirm each test fails without the part of the fix it guards.
- [x] 2.10 Check the real menu item with a throwaway test: real wheel scrolling, and a press of the web view's own Reload.

## 3. Verification

- [x] 3.1 Run `openspec validate reload-latest-preview-content --strict`.
- [x] 3.2 Run `swift test`.
- [x] 3.3 Run the whole GUI lane (`MD2_RUN_GUI_TESTS=1 swift test --disable-swift-testing`).
