## 1. Preview

- [x] 1.1 Add `isAwaitingCommit`: set it in `beginLoading`, clear it when `currentNavigation` commits, and ignore any `didFinish` while it is set.

## 2. Tests

- [x] 2.1 Add `NavigationGate`, which holds a real navigation at its policy decision.
- [x] 2.2 `testEditDuringALoadIsNotOverwrittenByThatLoad`: the race in full through `updateNSView`.
- [x] 2.3 `testPostLoadWorkWaitsForTheLatestNavigation`: typography, the scroll target and the search wait for the latest page.
- [x] 2.4 `testAReloadNoLoadStartedStillFinishes`: a navigation no load started.
- [x] 2.5 Confirm 2.2 and 2.3 fail without the fix, and 2.4 fails with a plain `navigation === currentNavigation` guard.

## 3. Verification

- [x] 3.1 Run `openspec validate finish-preview-load-on-latest-page --strict`.
- [x] 3.2 Run `swift test`.
- [x] 3.3 Run the whole GUI lane (`MD2_RUN_GUI_TESTS=1 swift test --disable-swift-testing`).
